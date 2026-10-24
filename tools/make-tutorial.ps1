<#
.SYNOPSIS
    Records the "how to use iPhone Transfer" video: docs\iPhone-Transfer-tutorial.mp4

.DESCRIPTION
    1. Builds a demo iPhone - a folder of made-up month folders and photos - and a demo PC
       photo folder that already holds some of them (one month in a differently named
       folder, the way a real iPhone regroups its folders over time).
    2. Runs the real app in tutorial mode: it presses the same buttons a person would and
       saves a screenshot, plus where every control is, at each moment worth explaining.
       No real phone is touched.
    3. Turns those screens into a video: the step explained on the left, the real screen on
       the right, a spotlight on the control to use and a pointer that clicks it.
       Encoded to H.264 MP4 with Windows' own Media Foundation - nothing to install.

    Run it from anywhere:  powershell -STA -ExecutionPolicy Bypass -File tools\make-tutorial.ps1

.PARAMETER WorkDir
    Scratch space for the demo files and screenshots (about 2 GB while it runs).

.PARAMETER Output
    The video file to write. Default: docs\iPhone-Transfer-tutorial.mp4 in the project.

.PARAMETER SkipCapture
    Reuse the screenshots from an earlier run and only rebuild the video.
#>
[CmdletBinding()]
param(
    [string] $WorkDir = (Join-Path $env:TEMP 'iphone-transfer-tutorial'),
    [string] $Output = '',
    [switch] $SkipCapture,
    [int] $Fps = 30,
    [int] $Bitrate = 1200000,
    [string] $PreviewDir = ''
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if (-not $Output) { $Output = Join-Path $Root 'docs\iPhone-Transfer-tutorial.mp4' }
$Shots = Join-Path $WorkDir 'shots'

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
if (-not ('TutorialVideo.Mp4Writer' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'VideoWriter.cs') }

# ---------------------------------------------------------------------------
# 1. demo data
# ---------------------------------------------------------------------------

function New-DemoData {
    param([string] $PhoneDir, [string] $PcDir)
    foreach ($d in $PhoneDir, $PcDir) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }
    New-Item -ItemType Directory -Force -Path $PhoneDir, $PcDir | Out-Null

    $random = New-Object System.Random 2026
    $block = New-Object byte[] (8MB); $random.NextBytes($block)
    $script:FileNo = 4100

    function Write-DemoFile([string] $Path, [int64] $Size, [DateTime] $When) {
        $stream = [System.IO.File]::Create($Path)
        try {
            # A real file header for its type (the app checks it), then the path, which makes
            # every file's content unique.
            $magic = switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
                '.jpg'  { [byte[]] (0xFF, 0xD8, 0xFF, 0xE0) }
                '.png'  { [byte[]] (0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) }
                '.heic' { [byte[]] (0, 0, 0, 0x18) + [System.Text.Encoding]::ASCII.GetBytes('ftypheic') }
                '.mov'  { [byte[]] (0, 0, 0, 0x14) + [System.Text.Encoding]::ASCII.GetBytes('ftypqt  ') }
                '.aae'  { [System.Text.Encoding]::ASCII.GetBytes('<?xml version="1.0" encoding="UTF-8"?>') }
                default { [byte[]] @() }
            }
            $header = [byte[]] $magic + [System.Text.Encoding]::ASCII.GetBytes($Path)
            $stream.Write($header, 0, $header.Length)
            $left = $Size - $header.Length
            $offset = $random.Next(0, 1MB)
            while ($left -gt 0) {
                $n = [int] [math]::Min($left, $block.Length - $offset)
                $stream.Write($block, $offset, $n); $left -= $n; $offset = 0
            }
        }
        finally { $stream.Close() }
        [System.IO.File]::SetLastWriteTimeUtc($Path, $When)
        [System.IO.File]::SetCreationTimeUtc($Path, $When)
    }

    # month folder, number of photos, extra big video (MB)
    $plan = @(
        @{ Name = '202509_a'; Photos = 30; Big = 0 },
        @{ Name = '202511_a'; Photos = 42; Big = 0 },
        @{ Name = '202512_a'; Photos = 70; Big = 0 },
        @{ Name = '202602_a'; Photos = 26; Big = 0 },
        @{ Name = '202604_a'; Photos = 55; Big = 420 },
        @{ Name = '202606_a'; Photos = 18; Big = 0 }
    )
    foreach ($f in $plan) {
        $dir = Join-Path $PhoneDir $f.Name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $year = [int] $f.Name.Substring(0, 4); $month = [int] $f.Name.Substring(4, 2)
        $when = [DateTime]::SpecifyKind((New-Object DateTime $year, $month, 2, 9, 30, 0), 'Utc')
        for ($i = 0; $i -lt $f.Photos; $i++) {
            $script:FileNo++
            $n = $script:FileNo
            $when = $when.AddMinutes($random.Next(90, 900))
            $kind = $random.Next(0, 100)
            if ($kind -lt 55) {
                Write-DemoFile (Join-Path $dir "IMG_$n.HEIC") ($random.Next(1200, 3600) * 1KB) $when
                if ($random.Next(0, 100) -lt 45) { Write-DemoFile (Join-Path $dir "IMG_$n.MOV") ($random.Next(1800, 3400) * 1KB) $when }   # Live Photo
                if ($random.Next(0, 100) -lt 15) {                                                                                        # edited
                    Write-DemoFile (Join-Path $dir "IMG_E$n.HEIC") ($random.Next(1200, 3600) * 1KB) $when
                    Write-DemoFile (Join-Path $dir "IMG_$n.AAE") ($random.Next(900, 2100)) $when
                }
            }
            elseif ($kind -lt 70) { Write-DemoFile (Join-Path $dir "IMG_$n.JPG") ($random.Next(1500, 4200) * 1KB) $when }
            elseif ($kind -lt 82) { Write-DemoFile (Join-Path $dir "IMG_$n.PNG") ($random.Next(300, 1600) * 1KB) $when }      # screenshots
            else { Write-DemoFile (Join-Path $dir "IMG_$n.MOV") ($random.Next(9, 45) * 1MB) $when }                         # videos
        }
        if ($f.Big -gt 0) { $script:FileNo++; Write-DemoFile (Join-Path $dir "IMG_$($script:FileNo).MOV") ([int64] $f.Big * 1MB) $when.AddHours(3) }
    }

    # The PC already holds some of it: September in a differently named folder (the iPhone
    # regrouped it since), and part of November.
    $photos = Join-Path $PcDir 'iPhone Photos'
    New-Item -ItemType Directory -Force -Path (Join-Path $photos '202509_b'), (Join-Path $photos '202511_a') | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $PhoneDir '202509_a') -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $photos '202509_b') }
    Get-ChildItem -LiteralPath (Join-Path $PhoneDir '202511_a') -File | Select-Object -First 25 | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $photos '202511_a') }
}

# ---------------------------------------------------------------------------
# 2. capture
# ---------------------------------------------------------------------------

function Invoke-Capture {
    $phone = Join-Path $WorkDir 'demo-iphone'
    $pc = Join-Path $WorkDir 'demo-pc'
    Write-Host 'Building the demo iPhone and PC folders...'
    New-DemoData -PhoneDir $phone -PcDir $pc
    if (Test-Path -LiteralPath $Shots) { Remove-Item -LiteralPath $Shots -Recurse -Force }

    # A short drive letter makes the paths in the video read like a real PC ("P:\iPhone Photos").
    $letter = @('P', 'Q', 'T', 'V', 'W') | Where-Object { -not (Test-Path "$($_):\") } | Select-Object -First 1
    $mapped = $false
    $destination = Join-Path $pc 'iPhone Photos'
    if ($letter) {
        & subst.exe "$($letter):" $pc | Out-Null
        if ($LASTEXITCODE -eq 0) { $mapped = $true; $destination = "$($letter):\iPhone Photos" }
    }
    try {
        Write-Host 'Recording the app (a window opens and walks through every step by itself)...'
        $app = Join-Path $Root 'app\iPhoneTransfer.ps1'
        $process = Start-Process -FilePath 'powershell.exe' -PassThru -Wait -ArgumentList @(
            '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$app`"",
            '-DemoPhone', "`"$phone`"", '-Destination', "`"$destination`"", '-Tutorial', '-ScreenshotDir', "`"$Shots`"")
        if ($process.ExitCode -ne 0) { throw "The app stopped with exit code $($process.ExitCode)." }
    }
    finally {
        if ($mapped) { & subst.exe "$($letter):" /d | Out-Null }
    }
    $count = @(Get-ChildItem -LiteralPath $Shots -Filter '*.png').Count
    if ($count -lt 13) { throw "Only $count of 13 screens were captured - see the app log in %LOCALAPPDATA%\iPhoneTransfer\logs." }
    Write-Host "Captured $count screens."
}

# ---------------------------------------------------------------------------
# 3. the video
# ---------------------------------------------------------------------------

$W = 1600; $H = 900
$Culture = [System.Globalization.CultureInfo]::InvariantCulture
$UiFont = New-Object System.Windows.Media.FontFamily 'Segoe UI'

function New-Brush([string] $Hex, [double] $Opacity = 1.0) {
    $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Opacity = $Opacity; $b.Freeze(); return $b
}
function New-Text([string] $Text, [double] $Size, $Brush, [string] $Weight = 'Normal', [double] $MaxWidth = 0) {
    $face = New-Object System.Windows.Media.Typeface $UiFont, ([System.Windows.FontStyles]::Normal), ([System.Windows.FontWeight] (New-Object System.Windows.FontWeightConverter).ConvertFromString($Weight)), ([System.Windows.FontStretches]::Normal)
    $ft = New-Object System.Windows.Media.FormattedText $Text, $Culture, ([System.Windows.FlowDirection]::LeftToRight), $face, $Size, $Brush
    if ($MaxWidth -gt 0) { $ft.MaxTextWidth = $MaxWidth }
    return $ft
}
function Get-Ease([double] $t) { $t = [math]::Max(0, [math]::Min(1, $t)); return $t * $t * (3 - 2 * $t) }

$Dark = New-Brush '#0F172A'; $Panel = New-Brush '#111C33'; $White = New-Brush '#FFFFFF'; $Soft = New-Brush '#CBD5E1'
$Muted = New-Brush '#64748B'; $Blue = New-Brush '#60A5FA'; $Accent = New-Brush '#F59E0B'; $Ground = New-Brush '#E2E8F0'
$Dim = New-Brush '#0F172A' 0.5
$PointerGeometry = [System.Windows.Media.Geometry]::Parse('M 0,0 L 0,24 L 6.5,18.5 L 11,28 L 15,26 L 10.5,16.5 L 18,16.5 Z')
$PointerGeometry.Freeze()
$Icon = $null
try {
    # the largest size in the icon file, so it stays sharp when drawn big
    $decoder = New-Object System.Windows.Media.Imaging.IconBitmapDecoder((New-Object System.Uri (Join-Path $Root 'app\iPhoneTransfer.ico')), 'None', 'OnLoad')
    $Icon = $decoder.Frames | Sort-Object { $_.PixelWidth } -Descending | Select-Object -First 1
}
catch { }

$StepNames = @('Connect', 'Choose', 'Copy', 'Check', 'Free up')

function Get-Shot([string] $Name) {
    $png = Join-Path $Shots "$Name.png"
    $image = New-Object System.Windows.Media.Imaging.BitmapImage
    $image.BeginInit(); $image.CacheOption = 'OnLoad'; $image.UriSource = New-Object System.Uri $png; $image.EndInit(); $image.Freeze()
    $bounds = Get-Content -LiteralPath (Join-Path $Shots "$Name.json") -Raw | ConvertFrom-Json
    return @{ Image = $image; Bounds = $bounds }
}

function Get-TargetRect($Shot, [string[]] $Names, [double] $X0, [double] $Y0) {
    $r = [System.Windows.Rect]::Empty
    foreach ($n in $Names) {
        $b = $Shot.Bounds.$n
        if ($null -eq $b -or $null -eq $b.W) { Write-Warning "control '$n' not found in this screen"; continue }
        $r = [System.Windows.Rect]::Union($r, (New-Object System.Windows.Rect ($X0 + $b.X), ($Y0 + $b.Y), $b.W, $b.H))
    }
    if ($r.IsEmpty) { return $r }
    $r = [System.Windows.Rect]::Inflate($r, 7, 7)
    return $r
}

function Draw-Side($dc, $Scene, [double] $Width, [double] $Alpha) {
    $dc.DrawRectangle($Dark, $null, (New-Object System.Windows.Rect 0, 0, $Width, $H))
    if ($Icon) { $dc.DrawImage($Icon, (New-Object System.Windows.Rect 40, 40, 40, 40)) }
    $dc.DrawText((New-Text 'iPhone Transfer' 20 $White 'SemiBold'), (New-Object System.Windows.Point 92, 47))
    $dc.PushOpacity($Alpha)
    $y = 150
    if ($Scene.Step) {
        $dc.DrawText((New-Text ('STEP {0} OF 5' -f $Scene.Step) 15 $Blue 'Bold'), (New-Object System.Windows.Point 40, $y))
        $y += 34
    }
    $title = New-Text $Scene.Title 34 $White 'SemiBold' ($Width - 80)
    $dc.DrawText($title, (New-Object System.Windows.Point 40, $y))
    $y += $title.Height + 26
    foreach ($line in $Scene.Lines) {
        $t = New-Text $line 20 $Soft 'Normal' ($Width - 80)
        $t.LineHeight = 29
        $dc.DrawText($t, (New-Object System.Windows.Point 40, $y))
        $y += $t.Height + 18
    }
    $dc.Pop()
    # where we are in the five steps
    $x = 40
    for ($i = 0; $i -lt 5; $i++) {
        $active = ($Scene.Step -eq ($i + 1))
        $done = ($Scene.Step -gt ($i + 1)) -or $Scene.AllDone
        $fill = $Muted
        if ($done) { $fill = New-Brush '#16A34A' }
        if ($active) { $fill = New-Brush '#2563EB' }
        $dc.DrawEllipse($fill, $null, (New-Object System.Windows.Point ($x + 9), ($H - 66)), 9, 9)
        $label = New-Text $StepNames[$i] 13 $(if ($active) { $White } else { $Muted }) 'SemiBold'
        $dc.DrawText($label, (New-Object System.Windows.Point ($x + 9 - $label.Width / 2), ($H - 48)))
        $x += 68
    }
}

function Draw-Card($dc, $Scene, [double] $Alpha) {
    # full-frame title / text cards
    $dc.DrawRectangle($Dark, $null, (New-Object System.Windows.Rect 0, 0, $W, $H))
    $dc.PushOpacity($Alpha)
    $y = 150
    if ($Scene.Kind -eq 'Title') {
        if ($Icon) { $dc.DrawImage($Icon, (New-Object System.Windows.Rect (($W - 120) / 2), 110, 120, 120)) }
        $t = New-Text $Scene.Title 60 $White 'SemiBold'
        $dc.DrawText($t, (New-Object System.Windows.Point (($W - $t.Width) / 2), 260))
        $s = New-Text $Scene.Subtitle 26 $Soft 'Normal' 1100
        $s.TextAlignment = 'Center'
        $dc.DrawText($s, (New-Object System.Windows.Point (($W - 1100) / 2), 350))
        $x = ($W - 5 * 230) / 2
        for ($i = 0; $i -lt 5; $i++) {
            $cx = $x + $i * 230 + 115
            $dc.DrawEllipse((New-Brush '#2563EB'), $null, (New-Object System.Windows.Point $cx, 560), 30, 30)
            $n = New-Text ([string] ($i + 1)) 28 $White 'Bold'
            $dc.DrawText($n, (New-Object System.Windows.Point ($cx - $n.Width / 2), (560 - $n.Height / 2)))
            $l = New-Text $Scene.Steps[$i] 22 $White 'SemiBold'
            $dc.DrawText($l, (New-Object System.Windows.Point ($cx - $l.Width / 2), 608))
            $d = New-Text $Scene.StepText[$i] 16 $Muted 'Normal' 200
            $d.TextAlignment = 'Center'
            $dc.DrawText($d, (New-Object System.Windows.Point ($cx - 100), 645))
        }
    }
    else {
        $t = New-Text $Scene.Title 48 $White 'SemiBold'
        $dc.DrawText($t, (New-Object System.Windows.Point 200, 150))
        $y = 260
        $i = 0
        foreach ($line in $Scene.Lines) {
            $i++
            $dc.DrawEllipse((New-Brush '#1D4ED8'), $null, (New-Object System.Windows.Point 222, ($y + 18)), 20, 20)
            $n = New-Text ([string] $i) 20 $White 'Bold'
            $dc.DrawText($n, (New-Object System.Windows.Point (222 - $n.Width / 2), ($y + 18 - $n.Height / 2)))
            $l = New-Text $line 26 $Soft 'Normal' 1100
            $l.LineHeight = 36
            $dc.DrawText($l, (New-Object System.Windows.Point 270, $y))
            $y += $l.Height + 34
        }
    }
    $dc.Pop()
}

function Draw-Dialog($dc, [System.Windows.Rect] $Area, $Dialog, $Shot) {
    # A stand-in for the Windows confirmation box (the real one cannot be captured on its own).
    $dc.DrawRectangle($Dim, $null, $Area)
    $w = 560; $h = 250
    $r = New-Object System.Windows.Rect ($Area.X + ($Area.Width - $w) / 2), ($Area.Y + ($Area.Height - $h) / 2), $w, $h
    $dc.DrawRoundedRectangle($White, (New-Object System.Windows.Media.Pen (New-Brush '#94A3B8'), 1), $r, 8, 8)
    $dc.DrawText((New-Text $Dialog.Title 18 $Dark 'SemiBold'), (New-Object System.Windows.Point ($r.X + 24), ($r.Y + 20)))
    $text = $Dialog.Text
    foreach ($m in [regex]::Matches($text, '\{(\w+)\}')) { $value = $Shot.Bounds.($m.Groups[1].Value).Text; if ($value) { $text = $text.Replace($m.Value, $value) } }
    $body = New-Text $text 15 (New-Brush '#334155') 'Normal' ($w - 48)
    $body.LineHeight = 22
    $dc.DrawText($body, (New-Object System.Windows.Point ($r.X + 24), ($r.Y + 62)))
    $yes = New-Object System.Windows.Rect ($r.Right - 220), ($r.Bottom - 56), 92, 36
    $no = New-Object System.Windows.Rect ($r.Right - 116), ($r.Bottom - 56), 92, 36
    $dc.DrawRoundedRectangle((New-Brush '#E2E8F0'), $null, $yes, 4, 4)
    $dc.DrawRoundedRectangle((New-Brush '#E2E8F0'), $null, $no, 4, 4)
    $t = New-Text 'Yes' 15 $Dark 'SemiBold'; $dc.DrawText($t, (New-Object System.Windows.Point ($yes.X + ($yes.Width - $t.Width) / 2), ($yes.Y + 8)))
    $t = New-Text 'No' 15 $Dark 'SemiBold'; $dc.DrawText($t, (New-Object System.Windows.Point ($no.X + ($no.Width - $t.Width) / 2), ($no.Y + 8)))
    $yes = [System.Windows.Rect]::Inflate($yes, 6, 6)
    return $yes
}

function Draw-Pointer($dc, [System.Windows.Point] $At, [double] $Click) {
    if ($Click -gt 0 -and $Click -lt 1) {
        $radius = 8 + 34 * $Click
        $dc.DrawEllipse($null, (New-Object System.Windows.Media.Pen (New-Brush '#F59E0B' (1 - $Click)), 4), $At, $radius, $radius)
    }
    $dc.PushTransform((New-Object System.Windows.Media.TranslateTransform $At.X, $At.Y))
    $dc.PushTransform((New-Object System.Windows.Media.ScaleTransform 1.35, 1.35))
    $dc.DrawGeometry($White, (New-Object System.Windows.Media.Pen $Dark, 1.4), $PointerGeometry)
    $dc.Pop(); $dc.Pop()
}

$Scenes = @(
    @{ Kind = 'Title'; Seconds = 6; Title = 'iPhone Transfer'
       Subtitle = 'Copy your photos and videos to your PC, check that every single file arrived, and only then free up space on your iPhone.'
       Steps = $StepNames; StepText = @('Plug in, unlock, Trust', 'See what is on it', 'Live progress, safe to stop', 'Every file compared', 'Optional, only when safe') },
    @{ Kind = 'Card'; Seconds = 9; Title = 'Before you start'
       Lines = @('Install "Apple Devices" from the Microsoft Store (free). It adds the driver Windows needs to see an iPhone - you do not have to open it.',
                 'Download this project, unzip it, and double-click  "iPhone Transfer.cmd".',
                 'Tip: "Add a desktop shortcut" in the app puts an icon on your desktop for next time.') },

    @{ Shot = '01-connect-looking'; Step = 1; Seconds = 6; Title = 'Plug in your iPhone'
       Lines = @('Connect the iPhone to the PC with its cable.', 'The app finds it by itself - no need to press anything.'); Targets = @(@{ Names = @('ConnectStatusCard') }) },
    @{ Shot = '02-connect-locked'; Step = 1; Seconds = 6; Title = 'Unlock it and tap Trust'
       Lines = @('Unlock the iPhone with your passcode.', 'If the iPhone asks "Trust This Computer?", tap Trust.'); Targets = @(@{ Names = @('ConnectStatusCard') }) },
    @{ Shot = '03-connect-ready'; Step = 1; Seconds = 5; Title = 'Connected'
       Lines = @('Press Continue.'); Targets = @(@{ Names = @('ConnectContinue'); Click = $true }) },

    @{ Shot = '04-scanning'; Step = 2; Seconds = 7; Title = 'The app reads your iPhone'
       Lines = @('Every folder is read - one per month.', 'A big month can take a few minutes; the progress shows it is working.'); Targets = @(@{ Names = @('ScanStatus', 'ScanBar') }, @{ Names = @('FolderGrid') }) },
    @{ Shot = '05-choose-destination'; Step = 2; Seconds = 7; Title = 'Choose where to save'
       Lines = @('Pick your photos folder on the PC - the main folder, not a month inside it.', 'The app remembers it for next time.'); Targets = @(@{ Names = @('ChangeDestButton'); Click = $true }) },
    @{ Shot = '06-recommended'; Step = 2; Seconds = 7; Title = 'See what is on it'
       Lines = @('Each folder shows its dates, photos, videos, size - and how much of it is already on the PC.'); Targets = @(@{ Names = @('FolderGrid') }) },
    @{ Shot = '06-recommended'; Step = 2; Seconds = 8; Title = 'Nothing is copied twice'
       Lines = @('Photos already on the PC - in any of its folders - are skipped.', 'The app shows your free space and recommends whole folders that fit.'); Targets = @(@{ Names = @('SpaceArea', 'SpaceText') }, @{ Names = @('RecommendCard') }) },
    @{ Shot = '06-recommended'; Step = 2; Seconds = 8; Title = 'Pick folders and press Copy'
       Lines = @('Tick or untick folders as you like.', '"Compare only" lists every file and where it is, without copying.'); Targets = @(@{ Names = @('CompareButton') }, @{ Names = @('StartCopyButton'); Click = $true }) },

    @{ Shot = '07-copying'; Step = 3; Seconds = 8; Title = 'Copying'
       Lines = @('Watch the progress, the speed and the time left.', 'The PC will not go to sleep. You can Pause or Stop at any time - nothing copied is lost.'); Targets = @(@{ Names = @('CopyPercent', 'CopyAmounts', 'CopyBar') }, @{ Names = @('PauseButton', 'StopButton') }) },
    @{ Shot = '08-disconnected'; Step = 3; Seconds = 8; Title = 'Cable came out?'
       Lines = @('No problem. Plug the iPhone back in and unlock it.', 'Copying continues by itself from where it stopped. Closed the app? Open it again - it continues too.'); Targets = @(@{ Names = @('WaitingBanner') }) },

    @{ Shot = '09-checking'; Step = 4; Seconds = 7; Title = 'Every file is checked'
       Lines = @('Each file on the iPhone is compared with its copy on the PC: name, size and a digital fingerprint of the content.'); Targets = @(@{ Names = @('CheckProgressCard') }) },
    @{ Shot = '10-checked'; Step = 4; Seconds = 8; Title = 'All safely on the PC'
       Lines = @('Green means every file matched - 100%.', '"Open the report" lists every single file. Problems? "Copy the missing files" fixes them.'); Targets = @(@{ Names = @('VerdictCard') }, @{ Names = @('OpenReportButton') }) },

    @{ Shot = '10-checked'; Step = 5; Seconds = 6; Title = 'Free up the iPhone (optional)'
       Lines = @('Only after the check: press "Free up space on the iPhone".'); Targets = @(@{ Names = @('GoDeleteButton'); Click = $true }) },
    @{ Shot = '11-free-up'; Step = 5; Seconds = 9; Title = 'Only checked folders'
       Lines = @('Only folders where every file matched are offered.', 'Using iCloud Photos? Deleting on the iPhone deletes from iCloud too - check first.'); Targets = @(@{ Names = @('DeleteWarnTitle', 'DeleteWarnText') }, @{ Names = @('DeleteGrid') }) },
    @{ Shot = '12-free-up-ready'; Step = 5; Seconds = 7; Title = 'Tick, confirm, delete'
       Lines = @('Tick the folders to remove from the iPhone, tick "I understand", and press Delete.'); Targets = @(@{ Names = @('DeleteConfirmCheck') }, @{ Names = @('DeleteButton'); Click = $true }) },
    @{ Shot = '12-free-up-ready'; Step = 5; Seconds = 6; Title = 'Confirm once more'
       Lines = @('The app asks one last time, naming the folders and where their copies are.', 'Just before each file is deleted, its copy on the PC is checked again.')
       Dialog = @{ Title = 'Delete from iPhone?'; Text = "{DeleteButton} from your iPhone?`r`n`r`nEvery one of these files was checked and is safely on this PC in {DestText}.`r`nThis cannot be undone from this PC." } },
    @{ Shot = '13-done'; Step = 5; AllDone = $true; Seconds = 7; Title = 'Done'
       Lines = @('Your photos are on the PC, every file checked - and the space on the iPhone is free.'); Targets = @(@{ Names = @('DeleteTitle', 'DeleteSub') }) },

    @{ Kind = 'Card'; Seconds = 11; Title = 'Good to know'
       Lines = @('Stopped, unplugged or closed the app? Open it again - it continues where it left off, and never copies a file twice.',
                 'Nothing is uploaded anywhere, and nothing is deleted unless you ask - only after every file has been checked.',
                 'The activity log is in the app''s sidebar; reports and the list of every copied file are in the hidden ".iphone-transfer" folder inside your photos folder.') }
)


function New-Layer([scriptblock] $Draw) {
    # Draws once into a frozen bitmap, so the still parts of a scene are not redrawn per frame.
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen(); & $Draw $dc; $dc.Close()
    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($W, $H, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($dv); $bitmap.Freeze()
    return $bitmap
}

function Save-Png($Bitmap, [string] $Path) {
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
    $stream = [System.IO.File]::Create($Path); $encoder.Save($stream); $stream.Close()
}

function Render-Video {
    $outDir = Split-Path -Parent $Output
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Force }
    if ($PreviewDir) { New-Item -ItemType Directory -Force -Path $PreviewDir | Out-Null }

    $writer = New-Object TutorialVideo.Mp4Writer($Output, $W, $H, $Fps, $Bitrate)
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($W, $H, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $pixels = New-Object byte[] ($W * $H * 4)
    $previous = $null
    $pointer = New-Object System.Windows.Point ($W * 0.62), ($H * 0.55)
    $fade = 0.45
    $total = 0
    $sceneNo = 0
    $full = New-Object System.Windows.Rect 0, 0, $W, $H
    try {
        foreach ($scene in $Scenes) {
            $sceneNo++
            $shot = $null
            if ($scene.Shot) { $shot = Get-Shot $scene.Shot }
            $frames = [int] ($scene.Seconds * $Fps)
            $sideWidth = 0; $x0 = 0; $y0 = 0; $area = [System.Windows.Rect]::Empty
            if ($shot) {
                $sw = $shot.Image.PixelWidth; $sh = $shot.Image.PixelHeight
                $x0 = $W - $sw - 8; $y0 = [math]::Floor(($H - $sh) / 2)
                $sideWidth = $x0 - 8
                $area = New-Object System.Windows.Rect $x0, $y0, $sw, $sh
            }

            # The still parts: the screen without its text, and with it (the text fades in).
            if ($shot) {
                $bare = New-Layer { param($dc) $dc.DrawRectangle($Ground, $null, $full); $dc.DrawImage($shot.Image, $area); Draw-Side $dc $scene $sideWidth 0 }
                $dressed = New-Layer { param($dc) $dc.DrawRectangle($Ground, $null, $full); $dc.DrawImage($shot.Image, $area); Draw-Side $dc $scene $sideWidth 1 }
            }
            else {
                $bare = New-Layer { param($dc) Draw-Card $dc $scene 0 }
                $dressed = New-Layer { param($dc) Draw-Card $dc $scene 1 }
            }

            $targets = @()
            if ($shot -and $scene.Targets) {
                foreach ($t in $scene.Targets) {
                    $rect = Get-TargetRect $shot $t.Names $x0 $y0
                    if (-not $rect.IsEmpty) { $targets += @{ Rect = $rect; Click = [bool] $t.Click } }
                }
            }
            $dialogLayer = $null; $dialogTarget = $null
            if ($scene.Dialog) {
                $holder = @{}
                $dialogLayer = New-Layer { param($dc) $holder.Yes = Draw-Dialog $dc $area $scene.Dialog $shot }
                $dialogTarget = $holder.Yes
            }
            $startPointer = $pointer
            $previewAt = [int] ($frames * 0.72)

            for ($f = 0; $f -lt $frames; $f++) {
                $time = $f / $Fps
                $dv = New-Object System.Windows.Media.DrawingVisual
                $dc = $dv.RenderOpen()
                $textAlpha = Get-Ease ($time / 0.6)
                if ($textAlpha -lt 1) {
                    $dc.DrawImage($bare, $full)
                    $dc.PushOpacity($textAlpha); $dc.DrawImage($dressed, $full); $dc.Pop()
                }
                else { $dc.DrawImage($dressed, $full) }

                if ($shot) {
                    $current = $null; $segmentStart = 0.0
                    if ($targets.Count -gt 0) {
                        $lead = 0.5
                        $segment = ($scene.Seconds - $lead - 0.3) / $targets.Count
                        if ($time -ge $lead) {
                            $k = [math]::Min([int] [math]::Floor(($time - $lead) / $segment), $targets.Count - 1)
                            $current = $targets[$k]
                            $segmentStart = $lead + $k * $segment
                        }
                    }
                    if ($dialogLayer) {
                        $dc.DrawImage($dialogLayer, $full)
                        $current = @{ Rect = $dialogTarget; Click = $true }
                        $segmentStart = 0.6
                    }
                    if ($current) {
                        $local = $time - $segmentStart
                        $grow = Get-Ease ($local / 0.35)
                        if (-not $dialogLayer) {
                            # spotlight: dim everything on the screen except the control
                            $outside = New-Object System.Windows.Media.CombinedGeometry ([System.Windows.Media.GeometryCombineMode]::Exclude), (New-Object System.Windows.Media.RectangleGeometry $area), (New-Object System.Windows.Media.RectangleGeometry $current.Rect, 10, 10)
                            $dc.PushOpacity(0.55 * $grow); $dc.DrawGeometry($Dark, $null, $outside); $dc.Pop()
                        }
                        $pulse = 0.65 + 0.35 * [math]::Sin($local * 5)
                        $dc.DrawRoundedRectangle($null, (New-Object System.Windows.Media.Pen (New-Brush '#F59E0B' (0.35 * $grow)), 12), $current.Rect, 10, 10)
                        $dc.DrawRoundedRectangle($null, (New-Object System.Windows.Media.Pen (New-Brush '#F59E0B' ($pulse * $grow)), 4), $current.Rect, 10, 10)

                        # the pointer glides to the control, then clicks when this step is a click
                        $aim = New-Object System.Windows.Point ($current.Rect.X + $current.Rect.Width * 0.5), ($current.Rect.Y + $current.Rect.Height * 0.62)
                        if ($current.Rect.Width -gt 260) { $aim = New-Object System.Windows.Point ($current.Rect.X + 60), ($current.Rect.Y + [math]::Min(40, $current.Rect.Height * 0.5)) }
                        $m = Get-Ease ($local / 0.9)
                        $pointer = New-Object System.Windows.Point ($startPointer.X + ($aim.X - $startPointer.X) * $m), ($startPointer.Y + ($aim.Y - $startPointer.Y) * $m)
                        $click = 0.0
                        if ($current.Click) { $click = ($local - 1.1) / 0.6 }
                        if ($current.Click) { Draw-Pointer $dc $pointer $click }
                        if ($m -ge 1) { $startPointer = $aim }
                    }
                }

                # cross-fade from the previous scene
                if ($previous -and $time -lt $fade) {
                    $dc.PushOpacity(1 - (Get-Ease ($time / $fade))); $dc.DrawImage($previous, $full); $dc.Pop()
                }
                $dc.Close()
                $rtb.Clear(); $rtb.Render($dv)
                $rtb.CopyPixels($pixels, $W * 4, 0)
                $writer.WriteFrame($pixels)
                if ($PreviewDir -and $f -eq $previewAt) { Save-Png $rtb (Join-Path $PreviewDir ('scene-{0:00}.png' -f $sceneNo)) }
                $total++
            }
            $previous = $rtb.Clone(); $previous.Freeze()
            $label = $scene.Title
            if ($scene.Shot) { $label = $scene.Shot }
            Write-Host ("  scene {0,2} {1,-24} {2,4} frames" -f $sceneNo, $label, $frames)
        }
    }
    finally { $writer.Dispose() }
    Write-Host ("Video written: {0}  ({1} frames, {2:N1} s, {3:N1} MB)" -f $Output, $total, ($total / $Fps), ((Get-Item -LiteralPath $Output).Length / 1MB))
}

if (-not $SkipCapture) { Invoke-Capture }
Render-Video
