# 2단계(테마 판단)를 독립 실행하는 스크립트. 대화형 세션 없이 claude.exe -p(헤드리스)로 수행.
# 2026-08-03 전면 개정 — 입력이 수집로그.md(본문)에서 2차헤드라인스크리닝.md(헤드라인)로 바뀌었고,
# 결과물도 판단로그.md + 포스팅작성뉴스및종목.md 두 개로 나뉜다(2단계_판단/원칙.md 참고).
# 2026-08-03 추가 개정 — 키워드추출·클러스터링을 이 프롬프트 안에서 시키다 99건에서도 5분
# 타임아웃으로 실패해서(단일 헤드리스 호출에 다 몰아넣은 게 원인), 그 두 단계를 키워드추출실행.ps1
# (파이썬이 기계적으로 준비·병합·클러스터링, LLM은 키워드만 배치 병렬로 판단)로 분리했다. 이 스크립트는
# 이제 이미 클러스터링된 daily/$Date/클러스터후보.md를 입력으로 받아 3축평가부터 시작한다.
# 사용법:
#   .\2단계_판단\scripts\키워드추출실행.ps1 -Date 20260803   (먼저 실행 — 클러스터후보.md 생성)
#   .\2단계_판단\scripts\판단실행.ps1 -Date 20260803          (그 다음 이 스크립트)

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
$clustersPath = Join-Path $dayDir "클러스터후보.md"
$refPath = Join-Path $dayDir "경제이슈참고.md"
$judgeLog = Join-Path $dayDir "판단로그.md"
$postMaterial = Join-Path $dayDir "포스팅작성뉴스및종목.md"

if (-not (Test-Path $clustersPath)) {
    Write-Error "클러스터후보.md가 없습니다: $clustersPath (먼저 .\키워드추출실행.ps1 -Date $Date 를 실행하세요)"
    exit 1
}
if (-not (Test-Path $refPath)) {
    Write-Warning "경제이슈참고.md가 없습니다: $refPath (없어도 진행은 되지만 경제이슈참고 선택은 건너뜀)"
}

$prompt = @"
2단계_판단/원칙.md의 판단 절차를 그대로 따라서 오늘의 테마·개별주이슈·경제이슈참고를 확정해줘.

입력:
- daily/$Date/클러스터후보.md — 키워드별로 이미 묶인 헤드라인 클러스터(파이썬이 기계적으로 묶은
  결과물이라 문자열만 다른 유사 키워드가 따로 나뉘어 있을 수 있다 — 의미가 같으면 하나로 합쳐서 봐라).
- daily/$Date/경제이슈참고.md — 배경정보용 헤드라인.

절차(2단계_판단/원칙.md에 상세 기준 있음, 애매하면 원문 다시 읽어. 키워드추출·1차클러스터링은 이미
끝났으니 아래 3축평가부터 시작해라):
1. 클러스터후보.md의 각 그룹을 훑으면서, 문자열은 다르지만 의미가 같은 키워드끼리(예: "폭염"·
   "온열질환"·"폭염대응") 합쳐서 하나의 클러스터로 봐라. 종목 언급으로 클러스터를 다시 나누지
   마라. 2단계_판단/테마목록.md에서 먼저 이름 매칭, 없으면 "신규 테마 후보"로.
2. 클러스터마다 3축(금액 규모, 클러스터링 강도, 신규성)으로 강도 평가. **클러스터가 크다고 그대로
   순위가 높은 게 아니다** — AI나 반도체처럼 특정 섹션·시장 전체가 몰두하는 소재는 클러스터가 원래
   기계적으로 커지니, 큰 클러스터일수록 "진짜 여러 갈래 신호인지 아니면 그 소재 기사가 원래 많은
   것뿐인지"를 한 번 더 따져라. 지속성은 참고만.
3. 테마 최대 5개 선정 — 강한 후보가 5개 미만이면 그만큼만, 억지로 채우지 마.
4. 관련 종목 1~2개뿐이고 섹터 확장 여지 없는 클러스터는 개별주 이슈 후보로(최대 7개, 안 억지로).
   **악재성 뉴스(논란·소송·실적부진 등)는 개별주 이슈에 넣지 마라. 선정된 테마의 관련종목과 겹치는
   회사도 빼라**(중복이므로).
5. 경제이슈참고.md에서 배경정보로 넣을 만한 것 최대 3건만 가볍게 골라라 — 이건 클러스터링 없이 그냥
   눈에 띄는 것 고르면 된다, 깊게 분석하지 마라(우선순위 낮은 항목이라 에너지 쓸 필요 없음).
6. 선정된 테마마다 웹검색으로 관련주 찾아 종목 매핑(뉴스 언급 종목 + 웹검색 대표 종목 합쳐 3~5개).
7. **테마당 대표 뉴스 1건만** WebFetch로 본문 확보해라(클러스터에 여러 건 묶여도 가장 포괄적인 1건만).
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
