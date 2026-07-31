<#
사용 예:
  .\make_main_image.ps1 -Year 2026 -Month 7 -Day 25

메인 이미지(뉴스와이슈\메인화면 배경.pptx)의 날짜 부분만 바꿔서
뉴스와이슈\메인이미지_YYYYMMDD.png 로 저장합니다.
홀수월은 slide1, 짝수월은 slide2 템플릿을 사용합니다.
#>
param(
    [Parameter(Mandatory=$true)][int]$Year,
    [Parameter(Mandatory=$true)][int]$Month,
    [Parameter(Mandatory=$true)][int]$Day,
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$TemplateName
)

Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = $Root
$template = Join-Path $root $TemplateName
$dateStr = "{0}{1:D2}{2:D2}" -f $Year, $Month, $Day
$tempPptx = Join-Path $root "_temp_main.pptx"
$outPng = Join-Path $root "main_image_$dateStr.png"

if ($Month % 2 -eq 1) {
    $slideNum = 1
    $oldPrefix = "2024. 05. "
    $oldDay = "03"
} else {
    $slideNum = 2
    $oldPrefix = "2024. 04. "
    $oldDay = "30"
}
$newPrefix = "{0}. {1:D2}. " -f $Year, $Month
$newDay = "{0:D2}" -f $Day

if (Test-Path $tempPptx) { Remove-Item $tempPptx -Force }
Copy-Item $template $tempPptx

$zip = [System.IO.Compression.ZipFile]::Open($tempPptx, 'Update')
$entryName = "ppt/slides/slide$slideNum.xml"
$entry = $zip.GetEntry($entryName)
$stream = $entry.Open()
$reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
$content = $reader.ReadToEnd()
$reader.Close()
$stream.Close()

$content = $content.Replace("<a:t>$oldPrefix</a:t>", "<a:t>$newPrefix</a:t>")
$content = $content.Replace("<a:t>$oldDay</a:t>", "<a:t>$newDay</a:t>")

$entry.Delete()
$newEntry = $zip.CreateEntry($entryName)
$writeStream = $newEntry.Open()
$bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
$writeStream.Write($bytes, 0, $bytes.Length)
$writeStream.Close()
$zip.Dispose()

$rawPng = Join-Path $root "_temp_main_raw.png"

$ppt = New-Object -ComObject PowerPoint.Application
$ppt.Visible = [Microsoft.Office.Core.MsoTriState]::msoTrue
$pres = $ppt.Presentations.Open($tempPptx, [Microsoft.Office.Core.MsoTriState]::msoFalse, [Microsoft.Office.Core.MsoTriState]::msoFalse, [Microsoft.Office.Core.MsoTriState]::msoFalse)
$slide = $pres.Slides.Item($slideNum)
$slide.Export($rawPng, "PNG")
$pres.Close()
$ppt.Quit()
[System.Runtime.Interopservices.Marshal]::ReleaseComObject($ppt) | Out-Null

Remove-Item $tempPptx -Force

# 슬라이드(16:9) 캔버스 안에서 정사각형 디자인 부분만 잘라내기
Add-Type -AssemblyName System.Drawing

$slideCx = 12192000; $slideCy = 6858000
$offX = 2841071; $offY = 174071
$extCx = 6509857; $extCy = 6509857
$strokeHalf = 257175 / 2

$src = [System.Drawing.Image]::FromFile($rawPng)
$scaleX = $src.Width / $slideCx
$scaleY = $src.Height / $slideCy

$left = [int][math]::Round(($offX - $strokeHalf) * $scaleX)
$top = [int][math]::Round(($offY - $strokeHalf) * $scaleY)
$right = [int][math]::Round(($offX + $extCx + $strokeHalf) * $scaleX)
$bottom = [int][math]::Round(($offY + $extCy + $strokeHalf) * $scaleY)
$cropW = $right - $left
$cropH = $bottom - $top

$bmp = New-Object System.Drawing.Bitmap $cropW, $cropH
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $cropW, $cropH), (New-Object System.Drawing.Rectangle $left, $top, $cropW, $cropH), [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()
$src.Dispose()

$bmp.Save($outPng, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Remove-Item $rawPng -Force

Write-Output "saved: $outPng"
