# 1단계 수집~2단계 판단실행까지 5단계를 한 번에 순서대로 실행하는 일괄 스크립트.
# 2026-08-20 신설 — 이 구간(URL수집→1차/2차스크리닝→클러스터링→판단실행)은 사용자 개입이 거의
# 없다는 판단 하에 매 단계 확인 없이 하나로 묶었다(project_headless_batching_plan 관련 논의).
# 중간에 어느 단계든 기대한 산출물이 안 만들어지면 그 자리에서 즉시 멈춘다 — 다음 단계로 넘어가지 않는다.
# 날짜(YYYYMMDD)는 news.daum.net 실시각 교차확인 후 직접 정해서 넘겨야 한다(이 스크립트가 자동 산정 안 함).
#
# 사용법: .\2단계_판단\scripts\일괄실행.ps1 -Date 20260821
#
# 이 스크립트가 끝나도 판단로그.md 검토·재구성 → 3단계 초안 작성은 그대로 별도 확인을 받는다
# (파이프라인 진행 순서는 CLAUDE.md 참고).

param(
    [Parameter(Mandatory=$true)][string]$Date
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$dayDir = Join-Path $repoRoot "daily\$Date"

function Confirm-StepOutput {
    param([string]$Label, [string[]]$ExpectedFiles)
    $missing = $ExpectedFiles | Where-Object { -not (Test-Path $_) }
    if ($missing) {
        Write-Error "[$Label] 다음 산출물이 생성되지 않았습니다: $($missing -join ', ') — 여기서 중단합니다."
        exit 1
    }
    Write-Host "[$Label] 완료 확인: $($ExpectedFiles -join ', ')"
}

Push-Location $repoRoot
try {
    Write-Host "=== 1/5 URL수집 ==="
    python "1단계_수집\scripts\collect_urls.py" --date $Date
    Confirm-StepOutput "URL수집" @("$dayDir\수집URL.md")

    Write-Host "`n=== 2/5 헤드라인 1차 스크리닝 ==="
    & "1단계_수집\scripts\헤드라인스크리닝실행.ps1" -Date $Date
    Confirm-StepOutput "1차 스크리닝" @("$dayDir\헤드라인스크리닝.md")

    Write-Host "`n=== 3/5 헤드라인 2차 스크리닝 ==="
    & "1단계_수집\scripts\헤드라인2차스크리닝실행.ps1" -Date $Date
    Confirm-StepOutput "2차 스크리닝" @("$dayDir\2차헤드라인스크리닝.md")

    Write-Host "`n=== 4/5 2단계 클러스터링 ==="
    & "2단계_판단\scripts\키워드추출실행.ps1" -Date $Date
    Confirm-StepOutput "클러스터링" @("$dayDir\클러스터후보.md")

    Write-Host "`n=== 5/5 2단계 판단실행 ==="
    & "2단계_판단\scripts\판단실행.ps1" -Date $Date
    Confirm-StepOutput "판단실행" @("$dayDir\판단로그.md", "$dayDir\포스팅작성뉴스및종목.md")

    Write-Host "`n=== 전체 완료: daily\$Date ==="
}
finally {
    Pop-Location
}
