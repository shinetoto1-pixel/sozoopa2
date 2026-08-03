"""헤드라인 2차 스크리닝의 앞뒤(추출/병합)를 담당하는 스크립트. 1차의 screen_headlines.py와
같은 구조(모델은 판정만, 파이썬이 파일 추출·병합) — 2026-08-02.

입력은 헤드라인스크리닝.md(1차 통과분)이고, 수집URL.md·헤드라인스크리닝.md는 건드리지 않는다.
출력은 새 파일 두 개뿐: 2차헤드라인스크리닝.md(통과=테마후보), 경제이슈참고.md(경제이슈참고 —
단, REF_SECTIONS에 지정된 섹션 것만 기록. 2026-08-04 — 전 섹션 기록이 비효율적이라 좁힘).
기각(그리고 REF_SECTIONS 밖에서 나온 경제이슈참고 판정)은 어디에도 안 남긴다.

사용법:
    python screen_headlines_2.py prepare --date 20260803 [--sections 벤처스타트업]
    (claude -p가 _screen2_result_<tag>.md 에 "번호: 판정(사유)" 형식으로 씀 — 판정은 통과/경제이슈참고/기각)
    python screen_headlines_2.py merge --date 20260803 --tag <tag>
"""
import argparse
import json
import re
import sys

from collect_urls import SECTIONS, load_existing, render, REPO_ROOT

sys.stdout.reconfigure(encoding="utf-8")

RESULT_RE = re.compile(r"^\s*(\d+)\s*[:.]\s*(.+)$")

# 경제이슈참고는 이 두 섹션에서 나온 것만 기록한다(2026-08-04) - 다른 섹션에서도 경제이슈참고
# 판정이 나오면 전부 기록하던 게 비효율적이라, 배경정보 성격상 가장 맞는 두 섹션으로 좁힘.
# 대상 밖 섹션의 경제이슈참고 판정은 기각과 동일하게 버린다.
REF_SECTIONS = {"경제정책", "국제경제"}


def prepare(args):
    day_dir = REPO_ROOT / "daily" / args.date
    screened_path = day_dir / "헤드라인스크리닝.md"
    if not screened_path.exists():
        raise SystemExit(f"헤드라인스크리닝.md가 없습니다: {screened_path} (먼저 1차 스크리닝을 끝내야 합니다)")

    existing = load_existing(screened_path)
    sections_to_run = args.sections or list(SECTIONS)

    parts = []
    idx_map = {}
    idx = 1
    for name in sections_to_run:
        lines = existing.get(name, [])
        if not lines:
            continue
        parts.append(f"## {name}")
        for line in lines:
            headline = line.split("|", 1)[0].split("]", 1)[1].strip()
            url = line.split("|")[1].strip() if line.count("|") >= 1 else ""
            parts.append(f"{idx}. {headline}")
            idx_map[str(idx)] = {"section": name, "headline": headline, "url": url}
            idx += 1

    if not idx_map:
        print(f"[{args.tag}] 2차 스크리닝할 대상이 없습니다(1차 통과분에 이 섹션 항목 없음).")
        raise SystemExit(1)

    (day_dir / f"_screen2_input_{args.tag}.md").write_text("\n".join(parts) + "\n", encoding="utf-8")
    (day_dir / f"_screen2_map_{args.tag}.json").write_text(
        json.dumps(idx_map, ensure_ascii=False, indent=0), encoding="utf-8"
    )
    print(f"[{args.tag}] 2차 대상 {len(idx_map)}건 -> daily/{args.date}/_screen2_input_{args.tag}.md")


def merge(args):
    day_dir = REPO_ROOT / "daily" / args.date
    map_path = day_dir / f"_screen2_map_{args.tag}.json"
    result_path = day_dir / f"_screen2_result_{args.tag}.md"
    if not result_path.exists():
        # 모델이 가끔 "result" 대신 "output"으로 써서 폴백 처리(2026-08-02 실측)
        alt_path = day_dir / f"_screen2_output_{args.tag}.md"
        if alt_path.exists():
            result_path = alt_path

    idx_map = json.loads(map_path.read_text(encoding="utf-8"))
    # utf-8-sig: PowerShell Out-File -Encoding utf8이 파일 맨 앞에 BOM을 붙이는데, 이걸 안 걷어내면
    # 첫 줄 정규식 매칭이 깨진다(2026-08-02 실측 — 9건 중 1번만 미매칭되는 버그로 발견됨)
    result_text = result_path.read_text(encoding="utf-8-sig")

    verdicts = {}
    for line in result_text.splitlines():
        m = RESULT_RE.match(line)
        if m:
            verdicts[m.group(1)] = m.group(2).strip()

    # 먼저 전부 분류만 해보고(파일에는 아직 안 씀), missing/unknown이 하나라도 있으면 아예 쓰지 않는다
    # (부분적으로만 쓰고 반환하면, 재실행 시 이미 쓴 항목을 또 추가해서 중복이 생긴다 - 2026-08-02 실측)
    classified = {}  # idx -> ("pass"|"ref"|"reject", line or None)
    missing = []
    unknown = []

    for idx, info in idx_map.items():
        verdict = verdicts.get(idx)
        section, headline, url = info["section"], info["headline"], info["url"]
        if verdict is None:
            missing.append(idx)
            continue
        # 모델이 마크다운 강조(**통과** 등)를 섞어 쓰는 경우가 있어 판정어 앞의 기호를 제거하고 분류
        # (2026-08-02 실측 — 이걸 안 해서 전부 기각으로 잘못 집계된 적 있음)
        clean = verdict.lstrip("*` -").strip()
        # 모델이 지시를 어기고 "번호: 헤드라인 → 판정" 형식으로 쓰는 경우가 있어, 앞에서 안 찾아지면
        # 문자열 안에서 판정어를 뒤에서부터 찾는다(2026-08-02 실측 - 의료보건 14건 전부 이 형식이었음)
        kind = None
        for kw, tag in (("통과", "pass"), ("경제이슈", "ref"), ("기각", "reject")):
            if clean.startswith(kw):
                kind, matched_at = tag, clean
                break
        else:
            for kw, tag in (("경제이슈", "ref"), ("통과", "pass"), ("기각", "reject")):
                pos = clean.rfind(kw)
                if pos != -1:
                    kind, matched_at = tag, clean[pos:]
                    break

        if kind is None:
            unknown.append((idx, verdict))
            continue
        line = f"- [ ] {headline} | {url} | {matched_at}"
        classified[idx] = (kind, section, line)

    if unknown:
        print(f"[{args.tag}] 분류 안 되는 판정 {len(unknown)}건 — 임시파일 보존, 병합 중단:")
        for idx, v in unknown:
            print(f"    {idx}: {v}")
        return
    if missing:
        print(f"[{args.tag}] 결과 없어서 미병합: {len(missing)}건 (번호: {', '.join(missing)}) — 임시파일 보존")
        return

    pass_path = day_dir / "2차헤드라인스크리닝.md"
    ref_path = day_dir / "경제이슈참고.md"
    pass_existing = load_existing(pass_path) if pass_path.exists() else {}
    ref_existing = load_existing(ref_path) if ref_path.exists() else {}

    pass_count = ref_count = ref_discarded_count = reject_count = 0
    for idx, (kind, section, line) in classified.items():
        if kind == "pass":
            pass_existing.setdefault(section, []).append(line)
            pass_count += 1
        elif kind == "ref":
            if section in REF_SECTIONS:
                ref_existing.setdefault(section, []).append(line)
                ref_count += 1
            else:
                ref_discarded_count += 1
        else:
            reject_count += 1

    pass_path.write_text(render(pass_existing), encoding="utf-8")
    ref_path.write_text(render(ref_existing), encoding="utf-8")
    print(f"[{args.tag}] 2차 결과 - 통과 {pass_count} / 경제이슈참고 {ref_count}"
          f"(대상 섹션 외 {ref_discarded_count}건은 기록 안 함) / 기각 {reject_count}")

    for p in (day_dir / f"_screen2_input_{args.tag}.md", map_path, result_path):
        p.unlink(missing_ok=True)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("prepare")
    p1.add_argument("--date", required=True)
    p1.add_argument("--sections", nargs="*", choices=list(SECTIONS), default=None)
    p1.add_argument("--tag", required=True)
    p1.set_defaults(func=prepare)

    p2 = sub.add_parser("merge")
    p2.add_argument("--date", required=True)
    p2.add_argument("--tag", required=True)
    p2.set_defaults(func=merge)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
