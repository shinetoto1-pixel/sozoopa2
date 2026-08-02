"""헤드라인 1차 스크리닝의 앞뒤(추출/병합)를 담당하는 스크립트.

실제 판정(추론)은 헤드리스 claude -p가 하고, 이 스크립트는 그 앞뒤 기계적 작업만 한다 — 모델이
수집URL.md 전체(수백 줄)를 읽고 줄마다 Edit을 반복하면 느리고 비싸서, 대상만 작게 추려 넘기고
결과도 짧게 받아 병합하는 방식으로 바꿈(2026-08-02, 벤처스타트업 21건 테스트가 3분 넘게 걸린 것을
계기로 도입).

사용법:
    python screen_headlines.py prepare --date 20260803 [--sections 벤처스타트업]
        -> _screen_input.md(모델에게 보여줄 번호 매긴 헤드라인 목록), _screen_map.json(번호->URL) 생성

    (claude -p가 _screen_input.md 를 보고 _screen_result.md 에 "번호: 판정(사유)" 형식으로 씀)

    python screen_headlines.py merge --date 20260803
        -> _screen_result.md + _screen_map.json 을 수집URL.md에 병합(각 줄 끝에 " | 판정" 추가)
"""
import argparse
import json
import re
import sys
from pathlib import Path

from collect_urls import SECTIONS, load_existing, render, REPO_ROOT

sys.stdout.reconfigure(encoding="utf-8")

RESULT_RE = re.compile(r"^\s*(\d+)\s*[:.]\s*(.+)$")


def export_passed(date: str) -> int:
    """수집URL.md에서 '통과' 판정만 뽑아 헤드라인스크리닝.md로 갱신. 통과 건수를 반환.

    체크박스([ ]/[x])를 그대로 옮기므로 본문확보가 어떤 걸 이미 처리했는지도 반영된다
    (부분적으로 여러 번 나눠 돌려도 매번 최신 상태로 다시 뽑음)."""
    day_dir = REPO_ROOT / "daily" / date
    url_path = day_dir / "수집URL.md"
    existing = load_existing(url_path)

    parts = []
    total = 0
    for name in SECTIONS:
        lines = existing.get(name, [])
        passed = [l for l in lines if l.count("|") >= 2 and l.split("|")[2].strip().startswith("통과")]
        if not passed:
            continue
        parts.append(f"## {name} ({len(passed)}건)\n" + "\n".join(passed))
        total += len(passed)

    (day_dir / "헤드라인스크리닝.md").write_text("\n\n".join(parts) + "\n", encoding="utf-8")
    return total


def prepare(args):
    day_dir = REPO_ROOT / "daily" / args.date
    url_path = day_dir / "수집URL.md"
    if not url_path.exists():
        raise SystemExit(f"수집URL.md가 없습니다: {url_path}")

    existing = load_existing(url_path)
    sections_to_run = args.sections or list(SECTIONS)

    parts = []
    idx_map = {}
    idx = 1
    for name in sections_to_run:
        lines = existing.get(name, [])
        unscreened = [l for l in lines if l.strip().startswith("- [") and l.count("|") == 1]
        if not unscreened:
            continue
        parts.append(f"## {name}")
        for line in unscreened:
            headline = line.split("|", 1)[0].split("]", 1)[1].strip()
            parts.append(f"{idx}. {headline}")
            idx_map[str(idx)] = {"section": name, "line": line}
            idx += 1

    if not idx_map:
        print(f"[{args.tag}] 스크리닝할 대상이 없습니다(전부 처리됐거나 대상 섹션에 신규 항목 없음).")
        raise SystemExit(1)

    (day_dir / f"_screen_input_{args.tag}.md").write_text("\n".join(parts) + "\n", encoding="utf-8")
    (day_dir / f"_screen_map_{args.tag}.json").write_text(
        json.dumps(idx_map, ensure_ascii=False, indent=0), encoding="utf-8"
    )
    print(f"[{args.tag}] 대상 {len(idx_map)}건 -> daily/{args.date}/_screen_input_{args.tag}.md")


def merge(args):
    day_dir = REPO_ROOT / "daily" / args.date
    url_path = day_dir / "수집URL.md"
    map_path = day_dir / f"_screen_map_{args.tag}.json"
    result_path = day_dir / f"_screen_result_{args.tag}.md"

    idx_map = json.loads(map_path.read_text(encoding="utf-8"))
    result_text = result_path.read_text(encoding="utf-8")

    verdicts = {}
    for line in result_text.splitlines():
        m = RESULT_RE.match(line)
        if m:
            verdicts[m.group(1)] = m.group(2).strip()

    def idx_to_url(i):
        line = idx_map.get(i, {}).get("line", "")
        parts = line.split("|")
        return parts[1].strip() if len(parts) > 1 else None

    dup_re = re.compile(r"대표\s*:\s*(\d+)")
    for idx, verdict in list(verdicts.items()):
        m = dup_re.search(verdict)
        if m:
            rep_url = idx_to_url(m.group(1))
            if rep_url:
                verdicts[idx] = dup_re.sub(f"대표: {rep_url}", verdict)

    existing = load_existing(url_path)
    updated_count = 0
    missing = []
    for idx, info in idx_map.items():
        section, old_line = info["section"], info["line"]
        verdict = verdicts.get(idx)
        if verdict is None:
            missing.append(idx)
            continue
        lines = existing.get(section, [])
        pos = lines.index(old_line) if old_line in lines else None
        if pos is None:
            continue
        lines[pos] = f"{old_line} | {verdict}"
        updated_count += 1

    url_path.write_text(render(existing), encoding="utf-8")
    print(f"[{args.tag}] 병합 완료: {updated_count}건")
    if missing:
        print(f"[{args.tag}] 결과 없어서 미병합: {len(missing)}건 (번호: {', '.join(missing)})")

    for p in (day_dir / f"_screen_input_{args.tag}.md", map_path, result_path):
        p.unlink(missing_ok=True)

    total = export_passed(args.date)
    print(f"헤드라인스크리닝.md 갱신: 통과 누적 {total}건")


def export(args):
    total = export_passed(args.date)
    print(f"헤드라인스크리닝.md 갱신: 통과 {total}건")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("prepare")
    p1.add_argument("--date", required=True)
    p1.add_argument("--sections", nargs="*", choices=list(SECTIONS), default=None)
    p1.add_argument("--tag", required=True, help="병렬 실행 시 임시파일 충돌 방지용 고유 태그")
    p1.set_defaults(func=prepare)

    p2 = sub.add_parser("merge")
    p2.add_argument("--date", required=True)
    p2.add_argument("--tag", required=True)
    p2.set_defaults(func=merge)

    p3 = sub.add_parser("export")
    p3.add_argument("--date", required=True)
    p3.set_defaults(func=export)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
