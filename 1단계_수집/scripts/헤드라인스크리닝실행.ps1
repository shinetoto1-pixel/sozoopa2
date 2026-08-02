# 1단계 "헤드라인 스크리닝" 단계를 독립 실행하는 스크립트 - 섹션별 병렬 실행.
# screen_headlines.py(prepare/merge, 기계적 작업)와 claude -p(헤드리스, 판정만) 조합.
# 섹션끼리는 서로 비교할 필요가 없어(중복판정도 섹션 내부에서만 함) 완전히 독립적으로 병렬화 가능
# (2026-08-02 - 순차로 하면 597건 전체에 20분 넘게 걸려서 섹션별 동시 실행으로 전환).
# API 키 불필요 — Claude Code 구독 범위 안에서 동작.
#
# 사용법:
#   .\헤드라인스크리닝실행.ps1 -Date 20260803                (전체 섹션, 대상 있는 것만 병렬 실행)
#   .\헤드라인스크리닝실행.ps1 -Date 20260803 -Sections 벤처스타트업,주식

param(
    [string]$Date = (Get-Date -Format "yyyyMMdd"),
    [string[]]$Sections = @()
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
$scriptDir = $PSScriptRoot

# collect_urls.py의 SECTIONS와 동일한 순서(우선순위)
$allSections = @("경제정책", "산업", "국제경제", "외교국방", "테크", "재난안전", "주식",
                  "벤처스타트업", "의료보건", "AI", "IT기업")
$targets = if ($Sections.Count -gt 0) { $Sections } else { $allSections }

function Build-Prompt($tag, $date) {
    return @"
지금 바로 실행해. 질문하거나 확인받지 말고, 아래 작업을 끝까지 수행한 뒤 통과/기각/중복 건수만 보고해.

daily/$date/_screen_input_$tag.md 를 읽어라. 번호가 매겨진 헤드라인 목록이다(모두 같은 섹션 안 항목이라
서로 비교해서 중복도 판정해야 함). 각 번호(헤드라인)마다 아래 기준으로 통과/기각/중복 중 하나를 판정해라.

판정 기준(느슨한 필터 - 애매하면 통과):
- 메인 전략(셋 중 하나라도 걸리면 통과 후보): 명백한 촉발요인(발표·체결·승인·경신·발령·확대 등 구체적
  동사), 해외동조화(해외 시장·기업 이슈로 국내 연결 소지), 신선도(기존에 못 보던 새 키워드·소재)
- 보조 축 - 재료중심분류: 정책/실적/공급망/규제/사고사건/신규기록/M&A 중 하나에 해당하는가(안 걸리면
  통과 근거 약함)
- 뒷받침 증빙: 금액 언급(수천억~조 단위, 달러 환산도 상당 규모) + 투자·제재 키워드가 있으면 판단 보강
- 노이즈컷(명백한 것만 즉시 기각): 부고·인사동정, 단순 목표가 조정, 순수 시황 해설·칼럼
- 중복: 같은 사건을 다룬 헤드라인이 여러 개면 대표 1개만 통과, 나머지는 중복 처리. 대표는 더
  구체적(수치·고유명사 많음)인 쪽.

결과는 daily/$date/_screen_result_$tag.md 에 번호 하나당 한 줄씩, 아래 형식으로 정확히 써라(헤드라인
텍스트를 다시 옮겨적지 마 - 번호와 판정만):
1: 통과(사유)
2: 기각(노이즈컷-부고)
3: 중복(대표:5)

중복인 경우 "대표:" 뒤에는 같은 목록 안 대표 항목의 번호를 쓴다.
입력에 있는 번호 전부에 대해 빠짐없이 한 줄씩 결과를 남겨라 - 하나도 빠뜨리지 마라.

이건 대화 없이 한 번에 끝까지 나가는 헤드리스 실행이다. 애매한 판정도 멈추지 말고 사유에 짧게 남기고
계속 진행해.
"@
}

# 1) 준비(순차, 빠름) - 대상 없는 섹션은 건너뜀
$active = @()
foreach ($sec in $targets) {
    Push-Location $scriptDir
    $out = & python screen_headlines.py prepare --date $Date --sections $sec --tag $sec 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    Pop-Location
    Write-Host $out
    if ($ok) { $active += $sec }
}

if ($active.Count -eq 0) {
    Write-Host "`n모든 섹션에서 스크리닝할 대상이 없습니다."
    exit 0
}

# 2) 판정(병렬) - 섹션마다 독립 헤드리스 프로세스 동시 실행
Write-Host "`n$($active.Count)개 섹션 병렬 판정 시작: $($active -join ', ')"
$startTime = Get-Date

$jobInfos = @()
foreach ($sec in $active) {
    $prompt = Build-Prompt -tag $sec -date $Date
    $job = Start-Job -ScriptBlock {
        param($exe, $p, $root)
        Set-Location $root
        & $exe -p $p --tools "Read,Write" --permission-mode bypassPermissions --output-format text
    } -ArgumentList $claudeExe, $prompt, $repoRoot
    $jobInfos += [pscustomobject]@{ Section = $sec; Job = $job; Count = 0 }
}

Wait-Job -Job ($jobInfos.Job) | Out-Null
$elapsed = (Get-Date) - $startTime
Write-Host "병렬 판정 완료(전체): $($elapsed.TotalSeconds.ToString('0.0'))초 (섹션 $($active.Count)개 동시 실행)"

foreach ($info in $jobInfos) {
    $j = $info.Job
    $dur = ($j.PSEndTime - $j.PSBeginTime).TotalSeconds
    Write-Host "  [$($info.Section)] 개별 소요: $($dur.ToString('0.0'))초"
    Receive-Job -Job $j | Write-Host
    Remove-Job -Job $j
}

# 3) 병합(순차 - 같은 파일에 쓰므로 동시에 하면 안 됨, 대신 LLM 없어서 빠름)
foreach ($sec in $active) {
    Push-Location $scriptDir
    & python screen_headlines.py merge --date $Date --tag $sec
    Pop-Location
}
