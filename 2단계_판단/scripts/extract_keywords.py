"""2단계 판단의 클러스터링 전 단계 — 헤드라인마다 키워드 1~2개를 뽑는 스크립트.
1차/2차 스크리닝과 같은 구조(모델은 키워드 판단만, 파이썬이 배치 준비·병합·클러스터링) — 2026-08-03.
99건(2026-08-03 실측 기준)을 한 번에 클러스터링까지 시키다 5분 타임아웃으로 실패한 문제를 해결하기
위해, 키워드 추출만 작은 배치로 나눠 병렬 헤드리스 호출로 처리하고, 클러스터링은 그 키워드를 기준으로
파이썬이 기계적으로 묶는다(cluster). 3축 평가·테마 선정·종목매핑·본문확보는 여전히 판단실행.ps1이
이 스크립트의 결과물(클러스터후보.md)을 입력으로 받아 수행한다.

입력은 daily/YYYYMMDD/2차헤드라인스크리닝.md(테마 후보 풀), 이 파일은 건드리지 않는다.
출력은 daily/YYYYMMDD/헤드라인키워드.md(번호별 키워드) + 클러스터후보.md(키워드로 묶은 그룹).

사용법:
    python extract_keywords.py prepare --date 20260803 --tag batch1 --start 1 --end 20
    (claude -p가 _kw_result_<tag>.md 에 "번호: 키워드1, 키워드2" 형식으로 씀)
    python extract_keywords.py merge --date 20260803 --tags batch1 batch2 batch3
    python extract_keywords.py cluster --date 20260803
"""
import argparse
import re
import sys
from pathlib import Path

# scripts/ -> 2단계_판단/ -> 프로젝트 루트
REPO_ROOT = Path(__file__).resolve().parents[2]
# SECTIONS/load_existing은 1단계_수집 쪽 collect_urls.py에 있는 걸 그대로 재사용(중복 정의 방지)
sys.path.insert(0, str(REPO_ROOT / "1단계_수집" / "scripts"))
from collect_urls import SECTIONS, load_existing  # noqa: E402

sys.stdout.reconfigure(encoding="utf-8")

RESULT_RE = re.compile(r"^\s*(\d+)\s*[:.]\s*(.+)$")


def load_pool(date):
    """2차헤드라인스크리닝.md를 섹션 순서 그대로 펼쳐서 전역 번호를 붙인 리스트로 반환."""
    path = REPO_ROOT / "daily" / date / "2차헤드라인스크리닝.md"
    if not path.exists():
        raise SystemExit(f"2차헤드라인스크리닝.md가 없습니다: {path}")
    existing = load_existing(path)
    pool = []
    idx = 1
    for name in SECTIONS:
        for line in existing.get(name, []):
            headline = line.split("|", 1)[0].split("]", 1)[1].strip()
            url = line.split("|")[1].strip() if line.count("|") >= 1 else ""
            pool.append({"idx": idx, "section": name, "headline": headline, "url": url})
            idx += 1
    return pool


def prepare(args):
    pool = load_pool(args.date)
    batch = [item for item in pool if args.start <= item["idx"] <= args.end]
    if not batch:
        print(f"[{args.tag}] 범위 {args.start}~{args.end}에 해당하는 항목이 없습니다.")
        raise SystemExit(1)
    day_dir = REPO_ROOT / "daily" / args.date
    lines = [f'{item["idx"]}. {item["headline"]}' for item in batch]
    (day_dir / f"_kw_input_{args.tag}.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"[{args.tag}] 키워드 추출 대상 {len(batch)}건({args.start}~{args.end}) "
          f"-> daily/{args.date}/_kw_input_{args.tag}.md")


def merge(args):
    pool = load_pool(args.date)
    pool_by_idx = {item["idx"]: item for item in pool}
    day_dir = REPO_ROOT / "daily" / args.date

    keywords = {}
    for tag in args.tags:
        result_path = day_dir / f"_kw_result_{tag}.md"
        if not result_path.exists():
            print(f"[{tag}] 결과 파일이 없습니다: {result_path} — 병합 중단")
            return
        # utf-8-sig: PowerShell Out-File -Encoding utf8이 붙이는 BOM 제거(2차 스크리닝과 동일 이슈)
        text = result_path.read_text(encoding="utf-8-sig")
        for line in text.splitlines():
            m = RESULT_RE.match(line)
            if m:
                keywords[m.group(1)] = m.group(2).strip()

    missing = [idx for idx in pool_by_idx if str(idx) not in keywords]
    if missing:
        print(f"키워드 없는 항목 {len(missing)}건(번호: {', '.join(map(str, missing))}) "
              f"— 임시파일 보존, 병합 중단")
        return

    lines = []
    for idx in sorted(pool_by_idx):
        item = pool_by_idx[idx]
        lines.append(f'{idx}. {item["headline"]} | 키워드: {keywords[str(idx)]} | {item["url"]}')
    (day_dir / "헤드라인키워드.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"헤드라인키워드.md 작성 완료({len(pool_by_idx)}건) -> daily/{args.date}/헤드라인키워드.md")

    for tag in args.tags:
        (day_dir / f"_kw_input_{tag}.md").unlink(missing_ok=True)
        (day_dir / f"_kw_result_{tag}.md").unlink(missing_ok=True)


def cluster(args):
    """헤드라인키워드.md를 읽어 키워드별로 묶은 클러스터 후보 파일을 만든다(LLM 없이 기계적으로)."""
    day_dir = REPO_ROOT / "daily" / args.date
    kw_path = day_dir / "헤드라인키워드.md"
    if not kw_path.exists():
        raise SystemExit(f"헤드라인키워드.md가 없습니다: {kw_path} (먼저 merge를 끝내야 합니다)")

    clusters = {}
    for line in kw_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        idx_headline, kw_field, url = line.split("|")
        idx, headline = idx_headline.split(".", 1)
        idx, headline = idx.strip(), headline.strip()
        kw_field = kw_field.split(":", 1)[1].strip()
        url = url.strip()
        for kw in [k.strip() for k in kw_field.split(",") if k.strip()]:
            clusters.setdefault(kw, []).append((idx, headline, url))

    ordered = sorted(clusters.items(), key=lambda kv: len(kv[1]), reverse=True)
    parts = []
    for kw, items in ordered:
        parts.append(f"## {kw} ({len(items)}건)")
        for idx, headline, url in items:
            parts.append(f"- [{idx}] {headline} | {url}")
    out_path = day_dir / "클러스터후보.md"
    out_path.write_text("\n\n".join(parts) + "\n", encoding="utf-8")
    print(f"클러스터후보.md 작성 완료(키워드 {len(clusters)}개) -> daily/{args.date}/클러스터후보.md")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("prepare")
    p1.add_argument("--date", required=True)
    p1.add_argument("--tag", required=True)
    p1.add_argument("--start", type=int, required=True)
    p1.add_argument("--end", type=int, required=True)
    p1.set_defaults(func=prepare)

    p2 = sub.add_parser("merge")
    p2.add_argument("--date", required=True)
    p2.add_argument("--tags", nargs="+", required=True)
    p2.set_defaults(func=merge)

    p3 = sub.add_parser("cluster")
    p3.add_argument("--date", required=True)
    p3.set_defaults(func=cluster)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
