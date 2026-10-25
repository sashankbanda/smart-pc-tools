<#
.SYNOPSIS
    Real app screens for the film: runs the three tools on autopilot with demo data (through
    extras\video-tools\make-promo.ps1 -CaptureOnly), at twice the size, and copies the screens
    the film uses into public\screens, with each app's icon cut out of its own window.

.PARAMETER SkipCapture
    Reuse the screens from the last capture and only copy them again.
#>
param(
    [string] $WorkDir = (Join-Path $env:TEMP 'smart-pc-tools-film'),
    [switch] $SkipCapture
)
$ErrorActionPreference = 'Stop'
$Film = Split-Path -Parent $PSScriptRoot
$Out = Join-Path $Film 'public\screens'
$Scale = 2

if (-not $SkipCapture) {
    & powershell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $Film '..\video-tools\make-promo.ps1') -CaptureOnly -ScreenshotScale $Scale -WorkDir $WorkDir
    if ($LASTEXITCODE) { throw 'The capture failed - see the messages above.' }
}

$Shots = Join-Path $WorkDir 'shots'
$Used = 'transfer-source', 'transfer-copying', 'transfer-checking', 'transfer-result',
        'cleanup-task', 'cleanup-findings', 'cleanup-done',
        'memory-home', 'memory-apps', 'memory-closed'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
foreach ($name in $Used) {
    $src = Join-Path $Shots "$name.png"
    if (-not (Test-Path -LiteralPath $src)) { throw "Missing screen $name.png - run without -SkipCapture." }
    Copy-Item -LiteralPath $src -Destination (Join-Path $Out "$name.png") -Force
}

# Each app's icon sits at the same place in its window: 40x40 at (24, 26).
Add-Type -AssemblyName PresentationCore, WindowsBase
foreach ($pair in @(@('transfer-source', 'icon-transfer'), @('cleanup-task', 'icon-cleanup'), @('memory-home', 'icon-memory'))) {
    $img = New-Object System.Windows.Media.Imaging.BitmapImage
    $img.BeginInit(); $img.CacheOption = 'OnLoad'; $img.UriSource = New-Object Uri (Join-Path $Out "$($pair[0]).png"); $img.EndInit()
    $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap($img, (New-Object System.Windows.Int32Rect (24 * $Scale), (26 * $Scale), (40 * $Scale), (40 * $Scale)))
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($crop))
    $fs = [IO.File]::Create((Join-Path $Out "$($pair[1]).png")); $enc.Save($fs); $fs.Close()
}
Write-Host ("Screens ready: {0} screens and 3 icons in {1}" -f $Used.Count, $Out)
