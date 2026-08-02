# 2단계(테마 판단)를 독립 실행하는 스크립트. 대화형 세션 없이 claude.exe -p(헤드리스)로 수행.
# 2026-08-03 전면 개정 — 입력이 수집로그.md(본문)에서 2차헤드라인스크리닝.md(헤드라인)로 바뀌었고,
# 결과물도 판단로그.md + 포스팅작성뉴스및종목.md 두 개로 나뉜다(2단계_판단/원칙.md 참고).
# 사용법: .\2단계_판단\scripts\판단실행.ps1 [-Date 20260803]  (Date 생략 시 오늘 날짜)

param(
    [string]$Date = (Get-Date -Format "yyyyMMdd")
)

$ErrorActionPreference = "Stop"

$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCmd) {
    $claudeExe = $claudeCmd.Source
} else {
    $found = Get-ChildItem "$env:APPDATA\Claude\claude-code" -Filter "claude.exe" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $found) {
        Write-Error "claude.exe를 찾을 수 없습니다. Claude 데스크톱 앱이 설치돼 있는지 확인하세요."
        exit 1
    }
    $claudeExe = $found.FullName
}

# scripts/ -> 2단계_판단/ -> 프로젝트 루트
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$dayDir = Join-Path $repoRoot "daily\$Date"
$themesPath = Join-Path $repoRoot "1단계_수집\2차헤드라인스크리닝.md"
$refPath = Join-Path $repoRoot "1단계_수집\경제이슈참고.md"
$judgeLog = Join-Path $dayDir "판단로그.md"
$postMaterial = Join-Path $dayDir "포스팅작성뉴스및종목.md"

if (-not (Test-Path $themesPath)) {
    Write-Error "2차헤드라인스크리닝.md가 없습니다: $themesPath (먼저 1단계 헤드라인 스크리닝을 끝내야 합니다)"
    exit 1
}
if (-not (Test-Path $refPath)) {
    Write-Warning "경제이슈참고.md가 없습니다: $refPath (없어도 진행은 되지만 경제이슈참고 선택은 건너뜀)"
}

$prompt = @"
2단계_판단/원칙.md의 판단 절차를 그대로 따라서 오늘의 테마·개별주이슈·경제이슈참고를 확정해줘.

입력:
- 1단계_수집/2차헤드라인스크리닝.md — 테마 후보 헤드라인 전체(섹션 구분 없이 하나의 풀로 다뤄).
- 1단계_수집/경제이슈참고.md — 배경정보용 헤드라인.

절차(2단계_판단/원칙.md에 상세 기준 있음, 애매하면 원문 다시 읽어):
1. **먼저 헤드라인마다 핵심 키워드를 1~2개만 뽑아라**(예: "반도체투자", "폭염"). 전체를 매번 다시
   읽으며 클러스터링하면 느리고 무거우니, 키워드부터 뽑고 그 키워드를 기준으로 묶는 순서로 해라.
   - 헤드라인 하나에 소재가 여러 개 섞여 있으면(예: "조선·AI·방산 미래 먹거리") 키워드도 여러 개로
     쪼개서 뽑아라 — 하나로 뭉뚱그리지 마라. 섹션 구분은 무시하고 전체를 하나의 풀로 다뤄라.
2. 같은 키워드끼리 묶어 클러스터를 만들어라. 종목 언급으로 클러스터를 만들지 마라 — 클러스터링이
   끝난 뒤에야 종목 수가 결과로 나온다. 2단계_판단/테마목록.md에서 먼저 이름 매칭, 없으면 "신규 테마
   후보"로.
3. 클러스터마다 3축(금액 규모, 클러스터링 강도, 신규성)으로 강도 평가. **클러스터가 크다고 그대로
   순위가 높은 게 아니다** — AI나 반도체처럼 특정 섹션·시장 전체가 몰두하는 소재는 클러스터가 원래
   기계적으로 커지니, 큰 클러스터일수록 "진짜 여러 갈래 신호인지 아니면 그 소재 기사가 원래 많은
   것뿐인지"를 한 번 더 따져라. 지속성은 참고만.
4. 테마 최대 5개 선정 — 강한 후보가 5개 미만이면 그만큼만, 억지로 채우지 마.
5. 관련 종목 1~2개뿐이고 섹터 확장 여지 없는 클러스터는 개별주 이슈 후보로(최대 7개, 안 억지로).
   **악재성 뉴스(논란·소송·실적부진 등)는 개별주 이슈에 넣지 마라. 선정된 테마의 관련종목과 겹치는
   회사도 빼라**(중복이므로).
6. 경제이슈참고.md에서 배경정보로 넣을 만한 것 최대 3건만 가볍게 골라라 — 이건 클러스터링 없이 그냥
   눈에 띄는 것 고르면 된다, 깊게 분석하지 마라(우선순위 낮은 항목이라 에너지 쓸 필요 없음).
7. 선정된 테마마다 웹검색으로 관련주 찾아 종목 매핑(뉴스 언급 종목 + 웹검색 대표 종목 합쳐 3~5개).
8. **테마당 대표 뉴스 1건만** WebFetch로 본문 확보해라(클러스터에 여러 건 묶여도 가장 포괄적인 1건만).
   나머지 서브 뉴스는 본문 열지 말고 헤드라인·링크만 남겨라 — 결과 파일이 무거워지지 않게 해라.
   개별주이슈·경제이슈참고는 애초에 본문 확보 안 함.

결과는 두 파일에 나눠 써:

**daily/$Date/판단로그.md** — 선정된 테마마다 선정 근거(3축 중 뭐가 왜 강했는지)와 핵심 사실·수치.
기각한 후보도 검증에 도움될 만큼(전부는 아니어도 몇 가지는) 왜 기각했는지 남겨.

**daily/$Date/포스팅작성뉴스및종목.md** — 3단계가 그대로 쓸 원재료, 최대한 가볍게, 이 순서로:
1. 경제이슈참고 링크 + 헤드라인(최대 3건)
2. 선정 테마별 — 대표 뉴스 1건의 WebFetch 본문 요약 + 링크, 서브 뉴스는 헤드라인+링크만, 관련 종목(3~5개)
3. 개별주 이슈 — 링크 + 헤드라인 + 종목명(최대 7건)

이 판단이 대화 없이 한 번에 나가는 헤드리스 실행이라는 점을 감안해서, 애매한 판단은 판단로그에 상세히
남겨 나중에 사용자가 검토할 수 있게 해줘.
"@

Push-Location $repoRoot
try {
    & $claudeExe -p $prompt `
        --tools "Read,Write,Glob,Grep,WebSearch,WebFetch" `
        --permission-mode bypassPermissions `
        --output-format text
}
finally {
    Pop-Location
}

if ((Test-Path $judgeLog) -and (Test-Path $postMaterial)) {
    Write-Host "`n완료: $judgeLog, $postMaterial"
} else {
    Write-Warning "판단로그.md 또는 포스팅작성뉴스및종목.md가 생성되지 않았습니다. 위 출력을 확인하세요."
}
