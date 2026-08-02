"""본문확보실행.ps1이 대상을 정하려고 쓰는 사전 스코핑 스크립트.

헤드라인스크리닝.md("통과"만 모아둔 파일, screen_headlines.py가 관리)에서 아직 [ ](미확보)인 것만
대상으로 삼는다. 그중 "이번 실행에 정확히 몇 건을 처리할지"를 헤드리스 모델에게 맡기지 않고 여기서
미리 확정한다(모델이 큰 파일 안에서 개수를 세다 오차를 낼 위험을 없애기 위함, 2026-08-02 결정).
결과를 daily/<date>/_scope_본문확보.md 에 쓰고, 섹션별 요약을 콘솔에 출력한다.

우선순위(collect_urls.py의 TIERS)별 기본 건수 제한 + 섹션별 개별 지정을 함께 쓸 수 있다.
섹션별 지정이 있으면 그 섹션에 한해 티어 기본값보다 우선한다.

사용법:
    python scope_urls.py --date 20260803 --tier1 60 --tier2 15 --tier3 15
    python scope_urls.py --date 20260803 --section 경제정책:50 산업:70 주식:15
    python scope_urls.py --date 20260803 --tier1 60 --tier2 15 --section 주식:5
"""
import argparse
import sys
from pathlib import Path

from collect_urls import SECTIONS, TIERS, load_existing, REPO_ROOT
from screen_headlines import export_passed

sys.stdout.reconfigure(encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", required=True)
    ap.add_argument("--tier1", type=int, default=None)
    ap.add_argument("--tier2", type=int, default=None)
    ap.add_argument("--tier3", type=int, default=None)
    ap.add_argument("--section", nargs="*", default=[],
                     help="섹션명:건수 형식, 티어 기본값보다 우선")
    ap.add_argument("--only-sections", nargs="*", choices=list(SECTIONS), default=None,
                     help="이 섹션들만 대상으로(건수 제한 없이 통과분 전부). 생략하면 전체 섹션")
    args = ap.parse_args()

    tier_limit = {1: args.tier1, 2: args.tier2, 3: args.tier3}
    section_to_tier = {name: t for t, names in TIERS.items() for name in names}

    section_limit = {}
    for item in args.section:
        name, count = item.split(":")
        if name not in SECTIONS:
            raise SystemExit(f"알 수 없는 섹션: {name}")
        section_limit[name] = int(count)

    day_dir = REPO_ROOT / "daily" / args.date
    url_path = day_dir / "수집URL.md"
    if not url_path.exists():
        raise SystemExit(f"수집URL.md가 없습니다: {url_path}")

    export_passed(args.date)  # 헤드라인스크리닝.md를 최신 상태로 갱신(체크박스 반영)
    screened_path = day_dir / "헤드라인스크리닝.md"
    existing = load_existing(screened_path)
    scope_parts = []
    total_selected = 0

    sections_to_run = args.only_sections or list(SECTIONS)
    for name in sections_to_run:
        lines = existing.get(name, [])
        unchecked = [l for l in lines if l.strip().startswith("- [ ]")]
        if not unchecked:
            continue

        if name in section_limit:
            limit = section_limit[name]
        else:
            tier = section_to_tier.get(name)
            limit = tier_limit.get(tier)

        selected = unchecked if limit is None else unchecked[:limit]
        if not selected:
            continue

        total_selected += len(selected)
        scope_parts.append(f"## {name} ({len(selected)}건)\n" + "\n".join(selected))
        print(f"[{name}] 선택 {len(selected)}건 / 남은 {len(unchecked)}건")

    if not scope_parts:
        print("선택된 URL이 없습니다(전부 처리됐거나 건수 제한에 걸림).")
        raise SystemExit(1)

    scope_path = day_dir / "_scope_본문확보.md"
    scope_path.write_text("\n\n".join(scope_parts) + "\n", encoding="utf-8")
    print(f"\n총 선택: {total_selected}건")
    print(f"스코프 파일: {scope_path}")


if __name__ == "__main__":
    main()
