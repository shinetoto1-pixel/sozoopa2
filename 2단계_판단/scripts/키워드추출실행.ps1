# 2단계 판단의 "키워드 추출" 단계를 독립 실행하는 스크립트 - 배치별 병렬 실행.
# extract_keywords.py(기계적 준비/병합/클러스터링)+claude -p(키워드 판단만)로 구성.
# 99건(2026-08-03 실측 기준)을 한 번에 클러스터링까지 시키던 판단실행.ps1이 5분 타임아웃으로
# 실패한 문제를 해결하기 위해 신설 - 여기서는 키워드 추출과 그 키워드로 묶는 클러스터링까지만
# 하고, 3축평가~본문확보(최종 판단)는 여전히 판단실행.ps1이 이 스크립트가 만든 클러스터후보.md를
# 입력으로 받아 수행한다.
# 입력은 daily/YYYYMMDD/2차헤드라인스크리닝.md, 이 파일은 안 건드림.
# 출력은 헤드라인키워드.md(번호별 키워드) + 클러스터후보.md(키워드로 묶은 그룹) 두 개.
# API 키 불필요 - Claude Code 구독 범위 안에서 동작.
#
# 사용법:
#   .\키워드추출실행.ps1 -Date 20260803
#   .\키워드추출실행.ps1 -Date 20260803 -BatchSize 25

param(
    [string]$Date = (Get-Date -Format "yyyyMMdd"),
    [int]$BatchSize = 20
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
$scriptDir = $PSScriptRoot
$poolPath = Join-Path $repoRoot "daily\$Date\2차헤드라인스크리닝.md"

if (-not (Test-Path $poolPath)) {
    Write-Error "2차헤드라인스크리닝.md가 없습니다: $poolPath (먼저 1단계 헤드라인 2차 스크리닝을 끝내야 합니다)"
    exit 1
}

$totalCount = (Select-String -Path $poolPath -Pattern "^- \[").Count
if ($totalCount -eq 0) {
    Write-Host "2차 통과분이 없습니다."
    exit 0
}

$batchCount = [Math]::Ceiling($totalCount / $BatchSize)

function Build-Prompt($tag, $date, $start, $end) {
    return @"
지금 바로 실행해. 질문하거나 확인받지 말고 끝까지 판단한 뒤, 판단 결과 목록만 답변으로 출력해라
(파일에 쓰지 마라 - 이 답변 텍스트 자체가 그대로 결과 파일로 저장된다. 다른 설명, 인사말, 요약은
답변에 넣지 말고 목록만 출력해).

daily/$date/_kw_input_$tag.md 를 읽어라. 번호가 매겨진 헤드라인 목록이다(번호는 $start 부터 $end 까지).
각 헤드라인마다 핵심 키워드를 1~2개만 뽑아라(예: 반도체투자, 폭염). 클러스터링에 쓸 것이므로
너무 일반적인 단어(경제, 산업)는 피하고 구체적 섹터나 소재로 뽑아라.

헤드라인 하나에 소재가 여러 개 섞여 있으면(예: 조선.AI.방산 미래 먹거리) 키워드도 여러 개로
쪼개서 뽑아라 - 하나로 뭉뚱그리지 마라.

답변은 번호 하나당 한 줄씩, 아래 형식 그대로 - 헤드라인 텍스트를 다시 옮겨적지 말고 번호와
키워드만, 마크다운 강조나 불릿기호 없이 순수 텍스트로 한 줄씩만:
${start}: 키워드1, 키워드2

입력에 있는 번호 전부에 대해 빠짐없이 한 줄씩 결과를 남겨라 - 하나도 빠뜨리지 마라. 이 목록 외의
다른 문장은 답변에 절대 포함하지 마라.

이건 대화 없이 한 번에 끝까지 나가는 헤드리스 실행이다.
"@
}

# 1) 준비(순차, 빠름) - 배치 경계 계산
$batches = @()
for ($i = 0; $i -lt $batchCount; $i++) {
    $start = $i * $BatchSize + 1
    $end = [Math]::Min(($i + 1) * $BatchSize, $totalCount)
    $tag = "batch$($i + 1)"
    Push-Location $scriptDir
    & python extract_keywords.py prepare --date $Date --tag $tag --start $start --end $end
    Pop-Location
    $batches += [pscustomobject]@{ Tag = $tag; Start = $start; End = $end }
}

# 2) 키워드 추출(병렬) - 배치마다 독립 헤드리스 프로세스 동시 실행
Write-Host "`n$($batches.Count)개 배치 키워드 추출 병렬 시작(전체 $totalCount 건)"
$startTime = Get-Date

$jobInfos = @()
foreach ($b in $batches) {
    $prompt = Build-Prompt -tag $b.Tag -date $Date -start $b.Start -end $b.End
    $resultFile = Join-Path $repoRoot "daily\$Date\_kw_result_$($b.Tag).md"
    $job = Start-Job -ScriptBlock {
        param($exe, $p, $root, $outFile)
        Set-Location $root
        # claude.exe 출력을 UTF-8로 정확히 캡처하려면 콘솔 인코딩을 먼저 맞춰야 한다
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
        $answer = & $exe -p $p --tools "Read" --permission-mode bypassPermissions --output-format text
        # 모델이 파일 쓰기를 건너뛰는 경우가 있어 신뢰성을 위해 PowerShell이 답변을 직접 저장
        $answer | Out-File -FilePath $outFile -Encoding utf8
    } -ArgumentList $claudeExe, $prompt, $repoRoot, $resultFile
    $jobInfos += [pscustomobject]@{ Tag = $b.Tag; Job = $job }
}

Wait-Job -Job ($jobInfos.Job) | Out-Null
$elapsed = (Get-Date) - $startTime
Write-Host "키워드 추출 완료(전체): $($elapsed.TotalSeconds.ToString('0.0'))초 (배치 $($batches.Count)개 동시 실행)"

foreach ($info in $jobInfos) {
    $j = $info.Job
    $dur = ($j.PSEndTime - $j.PSBeginTime).TotalSeconds
    Write-Host "  [$($info.Tag)] 개별 소요: $($dur.ToString('0.0'))초"
    Receive-Job -Job $j | Write-Host
    Remove-Job -Job $j
}

# 3) 병합 + 클러스터링(순차 - LLM 없어서 빠름)
$tags = $batches.Tag
Push-Location $scriptDir
& python extract_keywords.py merge --date $Date --tags $tags
& python extract_keywords.py cluster --date $Date
Pop-Location
