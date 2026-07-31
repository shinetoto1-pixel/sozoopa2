# 2단계(옥석가리기 테마판단)를 독립 실행하는 스크립트.
# 대화형 Claude Code 세션 없이, claude.exe -p(헤드리스)로 같은 판단을 수행시킨다.
# sozoopa 프로젝트의 판단실행.ps1을 이 프로젝트(3단계 분리 구조) 경로에 맞게 포팅한 버전.
# 사용법: .\2단계_판단\scripts\판단실행.ps1 [-Date 20260731]  (Date 생략 시 오늘 날짜)

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
$collectLog = Join-Path $dayDir "수집로그.md"
$judgeLog = Join-Path $dayDir "판단로그.html"

if (-not (Test-Path $collectLog)) {
    Write-Error "수집로그.md가 없습니다: $collectLog (먼저 1단계_수집 절차로 1단계를 끝내야 합니다)"
    exit 1
}

$prompt = @"
2단계_판단/원칙.md의 판단(옥석가리기) 절차를 그대로 따라서
daily/$Date/수집로그.md 전체를 판단해줘.

- 2단계_판단/테마목록.md에서 기존 테마명을 먼저 찾아 매칭하고, 목록에 없는 신규 후보는 "신규 테마 후보"로만
  표시해 (테마목록.md에 임의로 추가하지 마).
- 테마가 확정되면 웹검색으로 관련주를 찾아 종목을 매핑해.
- 결과는 daily/$Date/판단로그.html 파일로 저장해 (이전 날짜 판단로그.html이 daily/ 아래 있으면 그 스타일을 참고).
- 기준 미달이면 억지로 테마를 만들지 말고, 왜 기각했는지도 판단로그에 남겨.
- 판단로그는 3단계(포스팅)의 유일한 입력이야 — 3단계는 수집로그.md를 다시 안 봐. 그러니 테마별로 채택
  근거뿐 아니라 근거가 된 기사의 핵심 사실·수치와 원문 URL까지 판단로그에 적어서, 3단계가 그대로 옮겨
  쓸 수 있게 해줘.
- 이 판단이 대화 없이 한 번에 나가는 헤드리스 실행이라는 점을 감안해서,
  애매한 판단은 근거를 판단로그에 상세히 남겨 나중에 사용자가 검토할 수 있게 해줘.
"@

Push-Location $repoRoot
try {
    & $claudeExe -p $prompt `
        --tools "Read,Write,Glob,Grep,WebSearch" `
        --permission-mode bypassPermissions `
        --output-format text
}
finally {
    Pop-Location
}

if (Test-Path $judgeLog) {
    Write-Host "`n완료: $judgeLog"
} else {
    Write-Warning "판단로그.html이 생성되지 않았습니다. 위 출력을 확인하세요."
}
