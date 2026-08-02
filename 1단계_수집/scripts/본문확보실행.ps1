# 1단계(URL 수집) 중 "본문 확보 -> 기록" 부분을 독립 실행하는 스크립트.
# 대화형 Claude Code 세션 없이, claude.exe -p(헤드리스)로 WebFetch를 돌려 수집로그.md를 만든다.
# 대상은 항상 scope_urls.py를 거쳐서 정한다 - 헤드라인스크리닝.md("통과"만 모아둔 파일)에서
# 아직 미확보([ ])인 것만 골라 daily/<date>/_scope_본문확보.md 로 확정한 뒤 그것만 처리한다
# (2026-08-02 - 헤드라인 스크리닝 도입에 맞춰, 스크리닝 안 거친 경로를 없애고 전부 통일).
# API 키 불필요 — Claude Code 구독 범위 안에서 동작.
#
# 사용법:
#   .\본문확보실행.ps1 [-Date 20260803]                       (헤드라인스크리닝 통과분 전체)
#   .\본문확보실행.ps1 -Date 20260803 -Sections 경제정책,산업   (지정 섹션의 통과분만)
#   .\본문확보실행.ps1 -Date 20260803 -Tier1 60 -Tier2 15 -Tier3 15   (티어별 섹션당 건수 제한)
#   .\본문확보실행.ps1 -Date 20260803 -SectionLimits 경제정책:50,산업:70,주식:15  (섹션별 개별 건수)
# -Tier*/-SectionLimits는 사용량 통제용 — 티어 기본값 + 섹션별 override를 같이 쓸 수 있다
# (섹션별 지정이 티어 기본값보다 우선). -Sections와 같이 쓰면 그 섹션들 안에서만 제한 적용.

param(
    [string]$Date = (Get-Date -Format "yyyyMMdd"),
    [string[]]$Sections = @(),
    [Nullable[int]]$Tier1 = $null,
    [Nullable[int]]$Tier2 = $null,
    [Nullable[int]]$Tier3 = $null,
    [string[]]$SectionLimits = @()
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

# scripts/ -> 1단계_수집/ -> 프로젝트 루트
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$dayDir = Join-Path $repoRoot "daily\$Date"
$urlList = Join-Path $dayDir "수집URL.md"
$collectLog = Join-Path $dayDir "수집로그.md"

if (-not (Test-Path $urlList)) {
    Write-Error "수집URL.md가 없습니다: $urlList (먼저 collect_urls.py로 URL을 모아야 합니다)"
    exit 1
}

$scopeArgs = @("scope_urls.py", "--date", $Date)
if ($Sections.Count -gt 0) { $scopeArgs += @("--only-sections") + $Sections }
if ($Tier1 -ne $null) { $scopeArgs += @("--tier1", $Tier1) }
if ($Tier2 -ne $null) { $scopeArgs += @("--tier2", $Tier2) }
if ($Tier3 -ne $null) { $scopeArgs += @("--tier3", $Tier3) }
if ($SectionLimits.Count -gt 0) { $scopeArgs += @("--section") + $SectionLimits }

Push-Location $PSScriptRoot
try {
    & python @scopeArgs
    $scopeExit = $LASTEXITCODE
}
finally {
    Pop-Location
}
if ($scopeExit -ne 0) {
    Write-Error "스코프 계산 실패 또는 선택된 URL 없음 (위 출력 확인 - 헤드라인 스크리닝을 먼저 돌렸는지도 확인)"
    exit 1
}

$prompt = @"
지금 바로 실행해. 질문하거나 확인받지 말고, 아래 작업을 끝까지 수행한 뒤 결과 파일 경로만 보고해.

daily/$Date/_scope_본문확보.md 에 이번 실행 대상 URL이 전부 정해져 있다(헤드라인 스크리닝을 통과한
것 중 이번에 처리할 만큼만 미리 골라둔 것). 그 파일을 읽고, 거기 있는 URL 전부의 본문을 WebFetch로
확보해서 daily/$Date/수집로그.md 를 작성하는 작업이야. 절차는 1단계_수집/원칙.md 의 본문 확보·기록
부분과 동일하다. 그 외 daily/$Date/수집URL.md 에 남은 다른 URL(스코프에 없는 것)은 이번엔 건드리지 마.

작업 순서:
1. daily/$Date/_scope_본문확보.md 를 읽어서 섹션별 URL 목록을 확인한다(전부 이번 처리 대상).
2. URL당 WebFetch 1콜로 기사 본문을 가져온다. 한 번에 30~40건씩 묶어서 병렬로 호출한다.
   WebFetch에 줄 프롬프트: 이 기사의 핵심 사실을 불릿포인트로 정리해줘. 내용이 단순하면 1~2개로
   끝내도 되고, 복잡해도 최대 5개까지만 써. 불릿 개수를 억지로 채우지 마. 구체적 수치·고유명사는
   최대한 포함. 서로 다른 부문 내용이 섞여 있으면 둘 다 포함. 수사적 표현·도입부 상투문구는 생략.
3. WebFetch가 실패하면(에러·타임아웃·접속불가 등) 재시도하지 말고, 그 URL은 실패로 기록하고 넘어간다.
4. daily/$Date/수집로그.md 에 각 기사마다 아래 형식으로 적는다(헤더 뒤에 WebFetch가 돌려준 불릿을
   그대로 옮긴다 - 다시 요약하거나 압축하지 않는다):
   [섹션] 헤드라인 | URL | 시각
   - 불릿1
   - 불릿2
   헤드라인은 기사 제목, 시각은 URL 안의 타임스탬프(YYYYMMDDHHMMSS)를 KST로 변환한 값이다.
5. 본문을 실제로 확보한 URL은 daily/$Date/수집URL.md 에서 그 줄의 체크박스를 [x]로 바꾼다(스코프
   파일이 아니라 항상 진짜 수집URL.md에 반영). 체크박스 상태 외의 줄 순서나 다른 항목은 건드리지 않는다.
6. 이건 대화 없이 한 번에 끝까지 나가는 헤드리스 실행이다. 애매하거나 실패한 부분이 있어도 멈추거나
   되묻지 말고, 수집로그.md에 그 사실을 남겨서 나중에 사용자가 검토할 수 있게 하고 계속 진행해.
"@

Push-Location $repoRoot
try {
    & $claudeExe -p $prompt `
        --tools "Read,Write,Edit,WebFetch" `
        --permission-mode bypassPermissions `
        --output-format text
}
finally {
    Pop-Location
}

Remove-Item (Join-Path $dayDir "_scope_본문확보.md") -ErrorAction SilentlyContinue

if (Test-Path $collectLog) {
    Write-Host "`n완료: $collectLog"
} else {
    Write-Warning "수집로그.md가 생성되지 않았습니다. 위 출력을 확인하세요."
}
