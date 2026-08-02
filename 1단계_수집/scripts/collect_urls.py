"""1단계 URL 수집 — Playwright 헤드리스 브라우저 자동화.

1단계_수집/원칙.md 의 브라우저 JS 스니펫(새로운뉴스 버튼 클릭 반복 + URL 추출)을
Python/Playwright로 포팅. daily/ 폴더명은 "수집 시점"이 아니라 "다음 개장일"(포스팅
작성일) 기준이어야 다음날 아침 이어서 볼 때 한곳에 모인다. 개장일 판정은 주말(토/일)만
자동 인식하고, 공휴일은 판정하지 않는다(sozoopa 원본 정책과 동일 — 주말 판정은 항상
확실하지만 공휴일은 사용자 확인이 필요해서다). 공휴일에 조기수집을 해둔 경우엔 사용자가
직접 개장일 폴더로 취합을 지시한 뒤 2단계를 실행하는 방식으로 처리한다(2026-08-02 결정).

시간창 시작점은 "다음 개장일 기준 직전 거래일(주말 제외) 18:00"이다 — 월요일이 목표면
토요일이 아니라 금요일 18:00부터로 계산해서 주말 동안의 뉴스를 놓치지 않는다.

URL과 함께 헤드라인 텍스트도 같이 긁는다(이미 열어보는 목록 페이지의 DOM에서 그냥 같이 뽑는 거라
추가 비용 없음) — 나중에 헤드라인만으로 하는 1차 스크리닝에 쓰기 위함(2026-08-02). 수집URL.md에는
"- [ ] 헤드라인 | URL" 형식으로 기록된다.

사용법:
    python collect_urls.py                      # 날짜 생략 시 지금 기준 다음 개장일 자동 계산
    python collect_urls.py --date 20260803
    python collect_urls.py --date 20260803 --sections 경제정책 산업
    python collect_urls.py --date 20260803 --dry-run
    python collect_urls.py --date 20260803 --deep   # 이미 있는 수집URL.md의 경계를 무시하고
                                                     # boundary까지 다시 훑기(누락 구간 백필용)
"""
import argparse
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.stdout.reconfigure(encoding="utf-8")

KST = timezone(timedelta(hours=9))

# daily/YYYYMMDD/수집URL.md 에 이 순서대로 기록한다.
# 우선순위(2026-08-02 사용자 지정) 순서 - 사용량 제약으로 일부만 처리할 때 앞에서부터 처리:
# 1순위: 경제정책·산업·국제경제 / 2순위: 외교국방·테크·재난안전·주식 / 3순위: 벤처스타트업·의료보건·AI·IT기업
SECTIONS = {
    "경제정책": "https://news.daum.net/policy",
    "산업": "https://news.daum.net/industry",
    "국제경제": "https://news.daum.net/worldeconomy",
    "외교국방": "https://news.daum.net/dipdefen",
    "테크": "https://news.daum.net/technology",
    "재난안전": "https://news.daum.net/safety",
    "주식": "https://news.daum.net/stock",
    "벤처스타트업": "https://news.daum.net/startup",
    "의료보건": "https://news.daum.net/medical",
    "AI": "https://news.daum.net/ai-tech",
    "IT기업": "https://news.daum.net/it-tech",
}

TIERS = {
    1: ["경제정책", "산업", "국제경제"],
    2: ["외교국방", "테크", "재난안전", "주식"],
    3: ["벤처스타트업", "의료보건", "AI", "IT기업"],
}

URL_TS_RE = re.compile(r"/v/(\d{14})")
URL_RE = re.compile(r"https://v\.daum\.net/v/\d+")
SECTION_HEADER_RE = re.compile(r"^##\s+(\S+)")

# scripts/ -> 1단계_수집/ -> 프로젝트 루트
REPO_ROOT = Path(__file__).resolve().parents[2]


def next_market_date(trigger: datetime) -> datetime:
    """트리거 시각 기준 다음 개장일(주말만 skip, 공휴일 판정 없음)."""
    if trigger.time() < datetime.min.time().replace(hour=7, minute=30):
        candidate = trigger.date()
    else:
        candidate = trigger.date() + timedelta(days=1)
    while candidate.weekday() >= 5:  # 5=토, 6=일
        candidate += timedelta(days=1)
    return datetime(candidate.year, candidate.month, candidate.day, tzinfo=KST)


def previous_trading_close(target_date: datetime) -> datetime:
    """목표 개장일 기준 직전 거래일(주말 제외) 18:00."""
    d = target_date.date() - timedelta(days=1)
    while d.weekday() >= 5:
        d -= timedelta(days=1)
    return datetime(d.year, d.month, d.day, 18, 0, 0, tzinfo=KST)


def parse_ts(url: str):
    m = URL_TS_RE.search(url)
    if not m:
        return None
    s = m.group(1)
    return datetime(
        int(s[0:4]), int(s[4:6]), int(s[6:8]),
        int(s[8:10]), int(s[10:12]), int(s[12:14]),
        tzinfo=KST,
    )


def collect_section(page, section_url: str, boundary: datetime, known_urls: set,
                     stop_at_known: bool = True):
    page.goto(section_url, wait_until="domcontentloaded")
    box = page.locator(".box_news_headline2")
    box.wait_for(timeout=15000)

    def get_items():
        return box.locator("a[href*='v.daum.net']").evaluate_all(
            "els => els.map(e => ({href: e.href, "
            "text: (e.querySelector('.tit_txt')?.textContent || '').trim()}))"
        )

    def click_more():
        btn = box.get_by_text(re.compile(r"새로운\s*뉴스"))
        if btn.count() == 0:
            return False
        btn.first.click()
        return True

    all_links = []
    headline_map = {}
    prev_links = None
    first_oldest = None

    for i in range(15):
        items = get_items()
        links = [it["href"] for it in items]
        for it in items:
            if it["text"]:
                headline_map.setdefault(it["href"], it["text"])
        if prev_links is not None and links == prev_links:
            break
        if stop_at_known and known_urls and any(u in known_urls for u in links):
            all_links.extend(links)
            break
        oldest = links[-1] if links else None
        ts = parse_ts(oldest) if oldest else None
        if i == 0:
            first_oldest = ts
        elif ts and first_oldest and ts > first_oldest:
            break  # wrap-around: 더 과거로 못 감
        all_links.extend(links)
        prev_links = links
        if ts and ts <= boundary:
            break
        if not click_more():
            break
        page.wait_for_timeout(700)

    seen = set()
    deduped = []
    for u in all_links:
        if u not in seen:
            seen.add(u)
            deduped.append((u, headline_map.get(u, "")))
    return deduped


def load_existing(path: Path) -> dict:
    """수집URL.md를 섹션별 원본 라인(체크박스 상태 포함)으로 파싱."""
    if not path.exists():
        return {}
    sections = {}
    current = None
    lines = []
    for line in path.read_text(encoding="utf-8").splitlines():
        m = SECTION_HEADER_RE.match(line)
        if m:
            if current is not None:
                sections[current] = lines
            current = m.group(1)
            lines = []
        elif current is not None and line.strip():
            lines.append(line)
    if current is not None:
        sections[current] = lines
    return sections


def sort_lines_by_ts(lines: list) -> list:
    """체크리스트 라인들을 URL에 담긴 발행시각 기준 최신순으로 정렬.

    new_lines(신규분)를 existing_lines(기존분) 앞에 단순 이어붙이기만 하면, --deep으로
    과거 구간을 백필했을 때 신규분에 기존분보다 더 오래된 항목까지 섞여 있어 순서가
    깨진다(2026-08-02 발견) — 병합 시 항상 재정렬한다.
    """
    def key(line):
        m = URL_RE.search(line)
        return parse_ts(m.group(0)) if m else None

    return sorted(lines, key=lambda l: key(l) or datetime.min.replace(tzinfo=KST), reverse=True)


def render(sections_content: dict) -> str:
    parts = []
    for name in SECTIONS:
        lines = sections_content.get(name, [])
        parts.append(f"## {name} ({len(lines)}건)\n" + "\n".join(lines))
    return "\n\n".join(parts) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", default=None,
                     help="daily/ 폴더명 (YYYYMMDD, 다음 개장일). 생략하면 지금 시각 기준 자동 계산")
    ap.add_argument("--sections", nargs="*", choices=list(SECTIONS), default=None,
                     help="생략하면 전체 섹션")
    ap.add_argument("--dry-run", action="store_true", help="파일에 안 쓰고 콘솔 출력만")
    ap.add_argument("--deep", action="store_true",
                     help="기존 수집URL.md의 known-url에서 조기 중단하지 않고 boundary까지 다시 훑기(백필용)")
    args = ap.parse_args()

    if args.date:
        target_date = datetime.strptime(args.date, "%Y%m%d").replace(tzinfo=KST)
    else:
        target_date = next_market_date(datetime.now(tz=KST))
        print(f"(--date 생략됨 — 다음 개장일 자동 계산: {target_date.strftime('%Y%m%d')}. "
              f"주말만 자동 판정하며 공휴일은 반영 안 함 — 공휴일이면 --date로 직접 지정할 것)")

    date_str = target_date.strftime("%Y%m%d")
    boundary = previous_trading_close(target_date)
    sections_to_run = args.sections or list(SECTIONS)

    day_dir = REPO_ROOT / "daily" / date_str
    out_path = day_dir / "수집URL.md"
    existing = load_existing(out_path)

    print(f"목표 폴더(다음 개장일): daily/{date_str}")
    print(f"boundary(직전 거래일 18:00): {boundary.isoformat()}")
    print(f"대상 섹션: {', '.join(sections_to_run)}\n")

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page()
        for name in sections_to_run:
            existing_lines = existing.get(name, [])
            known_urls = {m.group(0) for line in existing_lines for m in URL_RE.finditer(line)}
            items = collect_section(page, SECTIONS[name], boundary, known_urls,
                                     stop_at_known=not args.deep)
            new_items = [(u, h) for u, h in items if u not in known_urls]
            new_links = [u for u, h in new_items]
            new_lines = [f"- [ ] {h} | {u}" if h else f"- [ ] {u}" for u, h in new_items]
            existing[name] = sort_lines_by_ts(new_lines + existing_lines)
            print(f"[{name}] 신규 {len(new_links)}건 (누적 {len(existing[name])}건)")
        browser.close()

    output = render(existing)

    if args.dry_run:
        print("\n(dry-run — 파일 기록 없음)")
        print(output)
    else:
        day_dir.mkdir(parents=True, exist_ok=True)
        out_path.write_text(output, encoding="utf-8")
        print(f"\n기록 완료: {out_path}")


if __name__ == "__main__":
    main()
