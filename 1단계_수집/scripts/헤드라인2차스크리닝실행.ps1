# 1단계 "헤드라인 2차 스크리닝" 단계를 독립 실행하는 스크립트 - 섹션별 병렬 실행.
# 1차(헤드라인스크리닝실행.ps1)와 같은 구조: screen_headlines_2.py(기계적 작업)+claude -p(판정만).
# 입력은 헤드라인스크리닝.md(1차 통과분), 수집URL.md/헤드라인스크리닝.md는 안 건드림.
# 출력은 2차헤드라인스크리닝.md(통과)·경제이슈참고.md(경제이슈참고) 두 개뿐 - 기각은 안 남김(2026-08-02).
# API 키 불필요 — Claude Code 구독 범위 안에서 동작.
#
# 사용법:
#   .\헤드라인2차스크리닝실행.ps1 -Date 20260803
#   .\헤드라인2차스크리닝실행.ps1 -Date 20260803 -Sections 경제정책,산업

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

$allSections = @("경제정책", "산업", "국제경제", "외교국방", "테크", "재난안전", "주식",
                  "벤처스타트업", "의료보건", "AI", "IT기업")
$targets = if ($Sections.Count -gt 0) { $Sections } else { $allSections }

function Build-Prompt($tag, $date) {
    return @"
지금 바로 실행해. 질문하거나 확인받지 말고 끝까지 판정한 뒤, 판정 결과 목록만 답변으로 출력해라
(파일에 쓰지 마라 - 이 답변 텍스트 자체가 그대로 결과 파일로 저장된다. 다른 설명·인사말·요약은 답변에
넣지 말고 판정 목록만 출력해).

daily/$date/_screen2_input_$tag.md 를 읽어라. 번호가 매겨진 헤드라인 목록이다(모두 같은 섹션 안 항목,
1단계_수집/헤드라인 1차 스크리닝을 이미 통과한 것들이다). 각 번호(헤드라인)마다 아래 기준으로
통과/경제이슈참고/기각 중 하나를 판정해라. 기준 전체는 1단계_수집/2차스크리닝기준.md 에 있으니 애매하면
그 문서 원문을 다시 읽어서 확인해라.

핵심 질문: 이 헤드라인이 특정 섹터·종목군으로 돈이 몰릴 근거가 되는가?

1. 테마 키워드 매핑: "경제와 관련 있다"만으로는 부족하고 구체적 섹터·소재 키워드로 연결돼야 한다.
   (예: 원전, AI반도체, 방산처럼 구체적인가 vs "시장", "경제"처럼 막연한가. 예시는 형태를 보여줄 뿐이고
   테마목록.md 전체 또는 거기 없는 신규 섹터도 대상이 될 수 있다.)
2. 테마목록 대조, 자동기각 금지: 테마목록.md에 없어도 1번을 통과하면 "신규 테마 후보"로 표시하고 통과.
   목록에도 없고 애초에 섹터 매핑도 안 되면(예: 난민) 기각.
3. 상태변화 vs 지속상태: 계속 진행 중인 상황의 단순 근황 보도는 기각. 상태가 바뀌는 사건만 통과.
   확정된 조치라도 이미 알려진 진행 중 사업의 단순 근황이면 신선하지 않으니 기각.
4. PR성·자기홍보 배제: 기업 자체 홍보·기술현장 르포성 기사는 국내 증시 연관 근거가 약하면
   기각 또는 경제이슈참고.
5. 확정 사실 vs 의혹·추정: "~의혹", "~정황"은 약한 신호. 실제로 집행된 조치만 강한 신호.
6. 방향성 재확인: 테마 키워드가 있어도 호재/악재/무관인지 재검토해라. 키워드만 보고 기계적으로
   통과시키지 마라.
7. 클러스터 교차확인: 개별로는 약해도 같은 섹션 안에서 여러 건이 같은 테마를 가리키면 서로 신뢰도를
   보강한다(선정 기준 자체는 아니고 보조 장치).
8. 뒷받침 증빙은 유연하게: 정확한 금액이 없어도 "투자 확대 + 경쟁력 강화" 같은 논리적 방향성 자체가
   증빙 역할을 할 수 있다.

판정 결과: 통과(테마 후보 자격 있음) / 경제이슈참고(테마 후보는 아니지만 포스팅 배경정보로 가치 있음) /
기각(위 기준 다 미달).

답변은 번호 하나당 한 줄씩, 아래 형식 그대로 - 헤드라인 텍스트를 다시 옮겨적지 말고 번호와 판정만,
마크다운 강조(별표 ** 등)나 불릿기호 없이 순수 텍스트로 한 줄씩만:
1: 통과(사유)
2: 경제이슈참고(사유)
3: 기각(사유)

사유는 선택이 아니라 필수다 - 판정어만 쓰고 사유를 생략하면 안 된다. 형식은 예외 없이 항상
"판정어(사유)"다(사유는 5~15자 내외로 짧게, 대시(-)나 공백으로 구분하는 다른 형식 쓰지 말고 반드시
괄호). 판정 단어는 반드시 "통과", "경제이슈참고", "기각" 중 하나로 시작해야 한다(앞에 별표나 다른 기호
붙이지 마라). 입력에 있는 번호 전부에 대해 빠짐없이 한 줄씩 결과를 남겨라 - 하나도 빠뜨리지 마라. 이
목록 외의 다른 문장(인사말, 요약, 집계)은 답변에 절대 포함하지 마라.

이건 대화 없이 한 번에 끝까지 나가는 헤드리스 실행이다. 애매한 판정도 멈추지 말고 사유에 짧게 남기고
계속 진행해.
"@
}

# 1) 준비(순차, 빠름) - 대상 없는 섹션은 건너뜀
$active = @()
foreach ($sec in $targets) {
    Push-Location $scriptDir
    $out = & python screen_headlines_2.py prepare --date $Date --sections $sec --tag $sec 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    Pop-Location
    Write-Host $out
    if ($ok) { $active += $sec }
}

if ($active.Count -eq 0) {
    Write-Host "`n모든 섹션에서 2차 스크리닝할 대상이 없습니다."
    exit 0
}

# 2) 판정(병렬) - 섹션마다 독립 헤드리스 프로세스 동시 실행
Write-Host "`n$($active.Count)개 섹션 2차 병렬 판정 시작: $($active -join ', ')"
$startTime = Get-Date

$jobInfos = @()
foreach ($sec in $active) {
    $prompt = Build-Prompt -tag $sec -date $Date
    $resultFile = Join-Path $repoRoot "daily\$Date\_screen2_result_$sec.md"
    $job = Start-Job -ScriptBlock {
        param($exe, $p, $root, $outFile)
        Set-Location $root
        # claude.exe 출력을 UTF-8로 정확히 캡처하려면 콘솔 인코딩을 먼저 맞춰야 한다
        # (안 하면 시스템 기본 코드페이지로 잘못 읽어서 한글이 깨짐, 2026-08-02 실측)
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
        $answer = & $exe -p $p --tools "Read" --permission-mode bypassPermissions --output-format text
        # 모델이 결과를 파일로 쓰는지 여부와 무관하게, 답변 텍스트 자체를 그대로 결과 파일로 저장
        # (모델이 파일 쓰기를 건너뛰는 경우가 있어 신뢰성을 위해 PowerShell이 직접 저장, 2026-08-02)
        $answer | Out-File -FilePath $outFile -Encoding utf8
    } -ArgumentList $claudeExe, $prompt, $repoRoot, $resultFile
    $jobInfos += [pscustomobject]@{ Section = $sec; Job = $job }
}

Wait-Job -Job ($jobInfos.Job) | Out-Null
$elapsed = (Get-Date) - $startTime
Write-Host "2차 병렬 판정 완료(전체): $($elapsed.TotalSeconds.ToString('0.0'))초 (섹션 $($active.Count)개 동시 실행)"

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
    & python screen_headlines_2.py merge --date $Date --tag $sec
    Pop-Location
}
