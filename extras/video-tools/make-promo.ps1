<#
.SYNOPSIS
    Records the Smart PC Tools promo video: output\smart-pc-tools-demo.mp4, with subtitles burned
    in and as a separate output\smart-pc-tools-demo.srt (for LinkedIn, YouTube and the like).

.DESCRIPTION
    1. Capture: builds demo data in C:\SmartPCTools-Demo (a pretend iPhone, a cluttered laptop,
       a messy Downloads folder, a few stand-in apps and startup entries under a test registry
       key), runs each tool on autopilot to take screenshots of its real screens, then removes
       all of it again. No real file, app or setting is touched.
    2. Render: title cards, the problem, every tool on its real screens with a slow zoom, big
       subtitles, the real result and how to get it - encoded to H.264 MP4 with Windows' own
       Media Foundation. Nothing to install.

    Run it from anywhere:  powershell -STA -ExecutionPolicy Bypass -File extras\video-tools\make-promo.ps1

.PARAMETER SkipCapture
    Reuse the screenshots from an earlier run and only rebuild the video.

.PARAMETER CaptureOnly
    Only take the screenshots (into WorkDir\shots), without making the video. The launch film in
    extras\launch-film uses this.

.PARAMETER ScreenshotScale
    Take the screenshots this many times larger than the window (2 = twice as sharp).

.PARAMETER PreviewDir
    Also save one still frame per scene there, to look at without playing the video.

.PARAMETER Voice
    The Windows voice that reads every subtitle aloud: Microsoft Zira, Microsoft Mark or
    Microsoft David (whichever are installed). Each scene lasts at least as long as its sentence.

.PARAMETER NoVoice
    A silent video, without the narration.
#>
[CmdletBinding()]
param(
    [string] $WorkDir = (Join-Path $env:TEMP 'smart-pc-tools-promo'),
    [string] $Output = '',
    [switch] $SkipCapture,
    [switch] $CaptureOnly,
    [double] $ScreenshotScale = 1,
    [switch] $MemoryOnly,
    [int] $Fps = 30,
    [int] $Bitrate = 6000000,
    [string] $PreviewDir = '',
    [string] $Voice = 'Microsoft Zira',
    [double] $SpeakingRate = 1.0,
    [switch] $NoVoice
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # this script lives in extras\video-tools
if (-not $Output) { $Output = Join-Path $PSScriptRoot 'output\smart-pc-tools-demo.mp4' }
$Shots = Join-Path $WorkDir 'shots'
$Demo = 'C:\SmartPCTools-Demo'
$DemoKey = 'Software\SmartPCToolsDemo'

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
if (-not ('TutorialVideo.Mp4Writer' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'VideoWriter.cs') }

$AudioRate = 48000
$VoiceLead = 0.3    # seconds into a scene before its sentence starts
$VoiceTail = 0.5    # seconds of quiet after it, before the next scene

if (-not ('PromoAudio' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
public static class PromoAudio
{
    // The samples of a 16-bit mono WAV file, and its sample rate.
    public static short[] FromWav(byte[] wav, out int rate)
    {
        rate = 0; int pos = 12;
        while (pos + 8 <= wav.Length)
        {
            string id = System.Text.Encoding.ASCII.GetString(wav, pos, 4);
            int size = BitConverter.ToInt32(wav, pos + 4);
            if (id == "fmt ") rate = BitConverter.ToInt32(wav, pos + 12);
            if (id == "data")
            {
                int n = Math.Min(size, wav.Length - pos - 8) / 2;
                short[] s = new short[n];
                Buffer.BlockCopy(wav, pos + 8, s, 0, n * 2);
                return s;
            }
            pos += 8 + size + (size & 1);
        }
        return new short[0];
    }

    // Three times the sample rate (16 kHz speech to 48 kHz), smoothly in between.
    public static short[] Upsample3(short[] s)
    {
        short[] o = new short[s.Length * 3];
        for (int i = 0; i < s.Length; i++)
        {
            int a = s[i], b = i + 1 < s.Length ? s[i + 1] : s[i];
            o[3 * i] = (short)a; o[3 * i + 1] = (short)((2 * a + b) / 3); o[3 * i + 2] = (short)((a + 2 * b) / 3);
        }
        return o;
    }

    // Louder or softer, so the loudest moment reaches the given share of full scale.
    public static void Normalize(short[] s, double peak)
    {
        int max = 1;
        foreach (short v in s) max = Math.Max(max, Math.Abs((int)v));
        double g = peak * 32767.0 / max;
        for (int i = 0; i < s.Length; i++) s[i] = (short)Math.Max(-32768, Math.Min(32767, s[i] * g));
    }

    // count mono samples from start (silence outside the track), as interleaved 16-bit stereo.
    public static void Stereo(short[] mono, long start, int count, byte[] dest)
    {
        for (int i = 0; i < count; i++)
        {
            long k = start + i;
            short v = (k >= 0 && k < mono.Length) ? mono[k] : (short)0;
            dest[i * 4] = (byte)v; dest[i * 4 + 1] = (byte)(v >> 8);
            dest[i * 4 + 2] = (byte)v; dest[i * 4 + 3] = (byte)(v >> 8);
        }
    }
}
'@
}

function Get-Speech {
    # Every subtitle read aloud by a Windows voice, as 48 kHz samples. Each scene then lasts at
    # least as long as its sentence, so voice, subtitle and picture always change together.
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Media.SpeechSynthesis.SpeechSynthesizer, Windows.Media.SpeechSynthesis, ContentType = WindowsRuntime]
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
    $asTask = $asTask.MakeGenericMethod([Windows.Media.SpeechSynthesis.SpeechSynthesisStream])
    $synth = New-Object Windows.Media.SpeechSynthesis.SpeechSynthesizer
    $chosen = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices | Where-Object { $_.DisplayName -eq $Voice } | Select-Object -First 1
    if (-not $chosen) { throw ("The voice '{0}' is not installed. Installed: {1}" -f $Voice, (([Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices | ForEach-Object { $_.DisplayName }) -join ', ')) }
    $synth.Voice = $chosen
    $synth.Options.SpeakingRate = $SpeakingRate
    Write-Host ("Narration: {0}" -f $Voice)
    foreach ($scene in $Scenes) {
        $text = $scene.Caption -replace ' - ', ', '
        $task = $asTask.Invoke($null, @($synth.SynthesizeTextToStreamAsync($text)))
        $task.Wait()
        $stream = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($task.Result)
        $ms = New-Object System.IO.MemoryStream; $stream.CopyTo($ms); $stream.Dispose()
        $rate = 0
        $samples = [PromoAudio]::FromWav($ms.ToArray(), [ref] $rate)
        if ($rate -ne 16000) { throw "Unexpected speech sample rate $rate" }
        $samples = [PromoAudio]::Upsample3($samples)
        [PromoAudio]::Normalize($samples, 0.89)
        $scene.Speech = $samples
        $needed = $VoiceLead + $samples.Length / $AudioRate + $VoiceTail
        if ($needed -gt $scene.Seconds) { $scene.Seconds = [math]::Round($needed, 2) }
    }
}

# ---------------------------------------------------------------------------
# 1. capture
# ---------------------------------------------------------------------------

$script:Random = New-Object System.Random 2026
$script:Block = New-Object byte[] (8MB); $script:Random.NextBytes($script:Block)
$JpgHead = [byte[]] @(0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 74, 70, 73, 70, 0, 1, 1, 0, 0, 1)
$MovHead = [byte[]] @(0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20, 0, 0, 0, 0)

function New-DemoFile {
    # A file of the given size: a header so it looks like what its name says, then bytes that
    # are unique to this file (so no two demo files are accidental duplicates).
    param([string] $Path, [int64] $Size, [byte[]] $Head = $null, [int] $DaysOld = 0)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $stream = [System.IO.File]::Create($Path)
    try {
        $salt = [System.Text.Encoding]::UTF8.GetBytes($Path + [guid]::NewGuid())
        if ($Head) { $stream.Write($Head, 0, $Head.Length) }
        $stream.Write($salt, 0, $salt.Length)
        $left = $Size - $stream.Length
        $offset = $script:Random.Next(0, 1MB)
        while ($left -gt 0) {
            $n = [int] [math]::Min($left, $script:Block.Length - $offset)
            $stream.Write($script:Block, $offset, $n); $left -= $n; $offset = 0
        }
    }
    finally { $stream.Close() }
    if ($DaysOld) { $when = (Get-Date).AddDays(-$DaysOld); [System.IO.File]::SetLastWriteTime($Path, $when); [System.IO.File]::SetCreationTime($Path, $when) }
}

function New-DemoData {
    if (Test-Path -LiteralPath $Demo) { Remove-Item -LiteralPath $Demo -Recurse -Force }
    # A pretend iPhone: six months of photos and a few videos, the oldest already on the PC.
    $no = 4100
    $months = @('202605_a', '202606_a', '202607_a', '202608_a', '202609_a', '202610_a')
    foreach ($m in $months) {
        $monthDate = [datetime]::ParseExact($m.Substring(0, 6), 'yyyyMM', $null)
        for ($i = 0; $i -lt 36; $i++) {
            $no++
            $path = Join-Path $Demo ("iPhone\$m\IMG_{0}.JPG" -f $no)
            New-DemoFile $path ($script:Random.Next(1500, 3600) * 1KB) $JpgHead
            [System.IO.File]::SetLastWriteTime($path, $monthDate.AddDays($i % 27).AddHours(10 + $i % 9))
        }
        for ($i = 0; $i -lt 3; $i++) {
            $no++
            $path = Join-Path $Demo ("iPhone\$m\IMG_{0}.MOV" -f $no)
            New-DemoFile $path ($script:Random.Next(9, 22) * 1MB) $MovHead
            [System.IO.File]::SetLastWriteTime($path, $monthDate.AddDays(5 + $i * 7))
        }
    }
    $pc = Join-Path $Demo 'PC\iPhone Photos'
    New-Item -ItemType Directory -Force -Path $pc | Out-Null
    Copy-Item -LiteralPath (Join-Path $Demo 'iPhone\202605_a') -Destination $pc -Recurse

    # A cluttered laptop for Smart Cleanup.
    $l = Join-Path $Demo 'Laptop'
    $goa = New-Object byte[] (2600KB); $script:Random.NextBytes($goa); $goa[0] = 0xFF; $goa[1] = 0xD8
    $party = New-Object byte[] (38MB); $script:Random.NextBytes($party)
    foreach ($p in "$l\Pictures\Goa 2026\IMG_4521.jpg", "$l\Downloads\IMG_4521 (1).jpg", "$l\Desktop\IMG_4521 - Copy.jpg") { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null; [System.IO.File]::WriteAllBytes($p, $goa) }
    [System.IO.File]::SetLastWriteTime("$l\Pictures\Goa 2026\IMG_4521.jpg", (Get-Date).AddDays(-200))
    foreach ($p in "$l\Videos\Birthday party.mp4", "$l\Videos\Birthday party - Copy.mp4") { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null; [System.IO.File]::WriteAllBytes($p, $party) }
    [System.IO.File]::SetLastWriteTime("$l\Videos\Birthday party.mp4", (Get-Date).AddDays(-120))
    for ($i = 1; $i -le 14; $i++) { New-DemoFile "$l\Pictures\Goa 2026\IMG_$(4521 + $i).jpg" ($script:Random.Next(1800, 3400) * 1KB) $JpgHead 200 }
    New-DemoFile "$l\Downloads\PhotoEditorSetup.exe" 96MB $null 75
    New-DemoFile "$l\Downloads\MusicPlayer-installer.msi" 64MB $null 140
    New-DemoFile "$l\Downloads\Bank statement 2025.pdf" 3MB $null 160
    New-DemoFile "$l\Downloads\holiday-video.mp4.crdownload" 180MB $null 40
    New-DemoFile "$l\Documents\~`$Budget 2026.xlsx" 165 $null 9
    New-DemoFile "$l\Documents\Budget 2026.xlsx" 48KB $null 9
    New-DemoFile "$l\Documents\Resume.pdf" 420KB $null 30
    New-DemoFile "$l\Pictures\Thumbs.db" 2MB $null 300
    New-DemoFile "$l\Music\Playlist\track01.mp3" 8MB $null 400
    New-Item -ItemType Directory -Force -Path "$l\Documents\Old project\drafts", "$l\Desktop\New folder" | Out-Null

    # A messy Downloads folder for Organize.
    $mess = Join-Path $Demo 'Downloads'
    $files = @('IMG_2031.jpg', 'IMG_2032.jpg', 'screenshot-0412.png', 'wallpaper.jpg', 'Invoice-March.pdf', 'Offer letter.pdf',
               'notes.txt', 'Budget.xlsx', 'Presentation.pptx', 'song.mp3', 'podcast-ep12.mp3', 'clip.mp4', 'tutorial.mov',
               'project.zip', 'backup.rar', 'Setup.exe', 'script.py', 'data.json', 'mystery.dat')
    foreach ($f in $files) { New-DemoFile (Join-Path $mess $f) ($script:Random.Next(40, 2400) * 1KB) $null ($script:Random.Next(2, 90)) }
    New-Item -ItemType Directory -Force -Path (Join-Path $mess 'Course material') | Out-Null
}

function New-DemoApps {
    # Stand-ins for well-known apps, wearing the real app's icon (taken from the copy installed
    # on this PC) and holding real memory, so Smart Memory shows a believable list. They are
    # never the real apps: the real ones are not touched.
    $dir = Join-Path $Demo 'Apps'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Add-Type -AssemblyName System.Drawing
    $source = @'
using System; using System.Windows.Forms;
[assembly: System.Reflection.AssemblyTitle("__NAME__")] [assembly: System.Reflection.AssemblyProduct("__NAME__")]
public static class __CLASS__ { static byte[] hold; [STAThread] public static void Main() {
  hold = new byte[__MB__ * 1024 * 1024]; for (int i = 0; i < hold.Length; i += 4096) hold[i] = 1;
  Form f = new Form(); f.Text = "__NAME__"; f.Width = 360; f.Height = 200; f.ShowInTaskbar = true; f.WindowState = FormWindowState.Minimized; Application.Run(f); } }
'@
    $apps = @(
        @{ File = 'chrome.exe'; Name = 'Google Chrome';      MB = 420; Icon = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" },
        @{ File = 'Code.exe';   Name = 'Visual Studio Code'; MB = 360; Icon = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe" },
        @{ File = 'CapCut.exe'; Name = 'CapCut';             MB = 300; Icon = "$env:LOCALAPPDATA\CapCut\Apps\CapCut.exe" },
        @{ File = 'brave.exe';  Name = 'Brave Browser';      MB = 240; Icon = "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe" }
    )
    foreach ($a in $apps) {
        $options = '/target:winexe'
        if (Test-Path -LiteralPath $a.Icon) {
            $ico = Join-Path $dir ([IO.Path]::ChangeExtension($a.File, '.ico'))
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($a.Icon)
            $stream = [IO.File]::Create($ico); $icon.Save($stream); $stream.Close(); $icon.Dispose()
            $options += (' /win32icon:"{0}"' -f $ico)
        }
        $cp = New-Object System.CodeDom.Compiler.CompilerParameters
        $cp.GenerateExecutable = $true
        $cp.OutputAssembly = Join-Path $dir $a.File
        $cp.CompilerOptions = $options
        [void] $cp.ReferencedAssemblies.Add('System.dll'); [void] $cp.ReferencedAssemblies.Add('System.Windows.Forms.dll')
        $class = 'StandIn' + [IO.Path]::GetFileNameWithoutExtension($a.File)   # one compiled type name per app
        Add-Type -TypeDefinition ($source.Replace('__NAME__', $a.Name).Replace('__MB__', [string] $a.MB).Replace('__CLASS__', $class)) -CompilerParameters $cp
    }
    return $dir
}
function Invoke-Tool {
    # Runs one tool on autopilot and moves its screenshots into the shots folder, prefixed.
    param([string] $Script, [string] $Prefix, [string[]] $Arguments)
    $dir = Join-Path $WorkDir ('raw-' + $Prefix)
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    $p = Start-Process powershell.exe -ArgumentList (@('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root "app\$Script"), '-AutoPilot', '-ScreenshotDir', $dir) + $Arguments) -PassThru
    if (-not $p.WaitForExit(600000)) { Stop-Process -Id $p.Id -Force; throw "$Script did not finish" }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter *.png) {
        $name = $Prefix + '-' + ($f.BaseName -replace '^\d+-', '') + '.png'
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Shots $name) -Force
    }
    Write-Host ("  {0}: {1} screens" -f $Prefix, @(Get-ChildItem -LiteralPath $dir -Filter *.png).Count)
}

function Invoke-Capture {
    Write-Host 'Capturing the real screens (demo data only)...'
    $env:SMART_SCREENSHOT_SCALE = [string] $ScreenshotScale   # read by Save-Screenshot in the tools
    if ((Test-Path -LiteralPath $Shots) -and -not $MemoryOnly) { Remove-Item -LiteralPath $Shots -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Shots | Out-Null
    $procs = @()
    try {
        if (-not $MemoryOnly) {
            New-DemoData
            Invoke-Tool 'SmartTransfer.ps1' 'transfer' @('-DemoPhone', (Join-Path $Demo 'iPhone'), '-Destination', (Join-Path $Demo 'PC\iPhone Photos'), '-AutoStopAfter', 'Delete')
            Invoke-Tool 'SmartCleanup.ps1' 'cleanup' @('-Folder', (Join-Path $Demo 'Laptop'), '-AutoDownloads', (Join-Path $Demo 'Laptop\Downloads'))
            Invoke-Tool 'SmartCleanup.ps1' 'organize' @('-Folder', (Join-Path $Demo 'Downloads'), '-AutoTask', 'Organize')
        }

        $apps = New-DemoApps
        foreach ($exe in Get-ChildItem -LiteralPath $apps -Filter *.exe) { $procs += Start-Process $exe.FullName -PassThru }
        Start-Sleep -Seconds 3
        Invoke-Tool 'SmartMemory.ps1' 'memory' @('-AutoTask', 'Close', '-TestAppsFolder', $apps)
        $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$DemoKey\Run")
        foreach ($e in @(@('Brave', 'brave.exe'), @('GoogleChromeAutoLaunch', 'chrome.exe'), @('CapCut', 'CapCut.exe'))) { $k.SetValue($e[0], ('"{0}" --no-startup-window' -f (Join-Path $apps $e[1]))) }
        $k.Close()
        Invoke-Tool 'SmartMemory.ps1' 'startup' @('-AutoTask', 'Startup', '-TestRegistryKey', $DemoKey)
    }
    finally {
        foreach ($p in $procs) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
        Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($Demo, [StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force -ErrorAction SilentlyContinue
        if ([Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($DemoKey)) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($DemoKey) }
        Start-Sleep -Milliseconds 500
        if (Test-Path -LiteralPath $Demo) { Remove-Item -LiteralPath $Demo -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
# 2. the story
# ---------------------------------------------------------------------------

$BLUE = '#3B82F6'; $TEAL = '#14B8A6'; $INDIGO = '#818CF8'; $GREEN = '#22C55E'; $AMBER = '#F59E0B'

# Kind: Title, Problem, Meet, Start, Chapter, Shot, Trust, Stat, Cta. Caption: the subtitle.
# Focus: where a screen slowly zooms towards (0..1 across, 0..1 down).
$Scenes = @(
    @{ Kind = 'Title';   Seconds = 4.0; Caption = 'Smart PC Tools: three free, simple tools for your Windows PC.' }
    @{ Kind = 'Problem'; Seconds = 7.5; Caption = 'Moving photos takes hours with no proof. The PC fills up. The laptop slows down.' }
    @{ Kind = 'Meet';    Seconds = 5.0; Caption = 'One easy question per screen. Nothing is deleted until you say yes.' }
    @{ Kind = 'Start';   Seconds = 5.0; Caption = 'Download the ZIP from GitHub, extract it, and double-click a tool. Nothing to install.' }

    @{ Kind = 'Chapter'; Seconds = 2.6; No = 1; Name = 'Smart Transfer'; Tagline = 'Move photos and files - every single file checked'; Accent = $BLUE; Icon = 0xE895; Caption = 'Smart Transfer: move your photos and files safely.' }
    @{ Kind = 'Shot'; Shot = 'transfer-source';     Chapter = 1; Seconds = 3.6; Focus = @(0.55, 0.35); Caption = 'Pick where your files come from: iPhone, Android, or any folder or drive.' }
    @{ Kind = 'Shot'; Shot = 'transfer-connect';    Chapter = 1; Seconds = 3.2; Focus = @(0.6, 0.3);  Caption = 'Plug in your phone and unlock it. It is found automatically.' }
    @{ Kind = 'Shot'; Shot = 'transfer-dest';       Chapter = 1; Seconds = 3.4; Focus = @(0.6, 0.35); Caption = 'Choose where to save. Every drive shows its free space.' }
    @{ Kind = 'Shot'; Shot = 'transfer-choose';     Chapter = 1; Seconds = 3.8; Focus = @(0.6, 0.35); Caption = 'It compares first, and only copies what is not on your PC yet.' }
    @{ Kind = 'Shot'; Shot = 'transfer-originals';  Chapter = 1; Seconds = 3.4; Focus = @(0.6, 0.4);  Caption = 'Keep the originals, or free up your phone once everything is checked.' }
    @{ Kind = 'Shot'; Shot = 'transfer-review';     Chapter = 1; Seconds = 3.4; Focus = @(0.6, 0.45); Caption = 'One last look at your choices. Change anything with one click.' }
    @{ Kind = 'Shot'; Shot = 'transfer-copying';    Chapter = 1; Seconds = 4.2; Focus = @(0.5, 0.45); Caption = 'Live progress. Pause, stop or unplug any time - it continues where it stopped.' }
    @{ Kind = 'Shot'; Shot = 'transfer-checking';   Chapter = 1; Seconds = 3.6; Focus = @(0.5, 0.45); Caption = 'Then every single file is checked against its digital fingerprint.' }
    @{ Kind = 'Shot'; Shot = 'transfer-result';     Chapter = 1; Seconds = 3.6; Focus = @(0.45, 0.35); Caption = 'All files safely copied - with a report as proof.' }
    @{ Kind = 'Shot'; Shot = 'transfer-free-ready'; Chapter = 1; Seconds = 3.6; Focus = @(0.55, 0.5); Caption = 'Only now can you free up space on the phone - after you confirm.' }
    @{ Kind = 'Shot'; Shot = 'transfer-done';       Chapter = 1; Seconds = 3.4; Focus = @(0.45, 0.4); Caption = 'Done. Your photos are safe, and your phone has room again.' }

    @{ Kind = 'Chapter'; Seconds = 2.6; No = 2; Name = 'Smart Cleanup'; Tagline = 'Free up space - and tidy up messy folders'; Accent = $TEAL; Icon = 0xE9D9; Caption = 'Smart Cleanup: free up space, safely.' }
    @{ Kind = 'Shot'; Shot = 'cleanup-findings';       Chapter = 2; Seconds = 4.0; Focus = @(0.55, 0.35); Caption = 'See what can go: duplicates, junk, old installers. The safe ones are ticked for you.' }
    @{ Kind = 'Shot'; Shot = 'cleanup-findings-usage'; Chapter = 2; Seconds = 3.4; Focus = @(0.55, 0.75); Caption = 'And see exactly where your space goes.' }
    @{ Kind = 'Shot'; Shot = 'cleanup-details';        Chapter = 2; Seconds = 3.6; Focus = @(0.55, 0.4);  Caption = 'Check any suggestion file by file. One copy of every duplicate always stays.' }
    @{ Kind = 'Shot'; Shot = 'cleanup-done';           Chapter = 2; Seconds = 3.4; Focus = @(0.45, 0.4);  Caption = 'Cleaned up. Everything removed goes to the Recycle Bin first.' }
    @{ Kind = 'Shot'; Shot = 'organize-org-how';       Chapter = 2; Seconds = 3.4; Focus = @(0.55, 0.4);  Caption = 'A messy Downloads folder? Sort it by type, or by date.' }
    @{ Kind = 'Shot'; Shot = 'organize-org-preview';   Chapter = 2; Seconds = 3.6; Focus = @(0.55, 0.45); Caption = 'See exactly which files go where, before anything moves.' }
    @{ Kind = 'Shot'; Shot = 'organize-org-done';      Chapter = 2; Seconds = 3.4; Focus = @(0.45, 0.4);  Caption = 'Tidy in one click - and Undo puts everything back.' }

    @{ Kind = 'Chapter'; Seconds = 2.6; No = 3; Name = 'Smart Memory'; Tagline = 'Make a slow laptop fast again'; Accent = $INDIGO; Icon = 0xE964; Caption = 'Smart Memory: make a slow laptop fast again.' }
    @{ Kind = 'Shot'; Shot = 'memory-home';    Chapter = 3; Seconds = 3.6; Focus = @(0.5, 0.3);  Caption = 'See how full your memory is - in plain words.' }
    @{ Kind = 'Shot'; Shot = 'memory-apps';    Chapter = 3; Seconds = 3.6; Focus = @(0.5, 0.35); Caption = 'Pick the apps you do not need right now. Biggest first.' }
    @{ Kind = 'Shot'; Shot = 'memory-closed';  Chapter = 3; Seconds = 3.6; Focus = @(0.45, 0.4); Caption = 'They close as if you clicked X - so they can still ask you to save.' }
    @{ Kind = 'Shot'; Shot = 'startup-startup'; Chapter = 3; Seconds = 3.8; Focus = @(0.5, 0.35); Caption = 'And stop apps from starting with Windows - the lasting fix.' }

    @{ Kind = 'Trust'; Seconds = 5.0; Caption = 'You stay in control: nothing is deleted, moved or closed without your yes.' }
    @{ Kind = 'Stat';  Seconds = 5.0; Caption = 'On my own PC: 27,120 photos and videos moved - every single one verified.' }
    @{ Kind = 'Cta';   Seconds = 6.0; Caption = 'Free, open source, nothing uploaded. Try it and tell me what you think!' }
)

# ---------------------------------------------------------------------------
# 3. drawing
# ---------------------------------------------------------------------------

$W = 1920; $H = 1080
$Culture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
$Ui = New-Object System.Windows.Media.FontFamily 'Segoe UI'
$Glyphs = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'

function New-Brush([string] $Hex, [double] $Opacity = 1.0) {
    $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Opacity = $Opacity; $b.Freeze(); return $b
}
$White = New-Brush '#FFFFFF'; $Soft = New-Brush '#CBD5E1'; $Muted = New-Brush '#94A3B8'; $Ink = New-Brush '#0F172A'

function New-Text {
    param([string] $Text, [double] $Size, $Brush, [string] $Weight = 'Normal', [double] $MaxWidth = 0, [string] $Align = 'Left', $Family = $Ui)
    $face = New-Object System.Windows.Media.Typeface $Family, ([System.Windows.FontStyles]::Normal), ([System.Windows.FontWeights]::$Weight), ([System.Windows.FontStretches]::Normal)
    $ft = New-Object System.Windows.Media.FormattedText $Text, $Culture, ([System.Windows.FlowDirection]::LeftToRight), $face, $Size, $Brush
    if ($MaxWidth -gt 0) { $ft.MaxTextWidth = $MaxWidth }
    $ft.TextAlignment = [System.Windows.TextAlignment]::$Align
    return $ft
}

function Get-Ease([double] $t) { $t = [math]::Max(0, [math]::Min(1, $t)); return $t * $t * (3 - 2 * $t) }
function Pt([double] $x, [double] $y) { return (New-Object System.Windows.Point $x, $y) }
function Rect([double] $x, [double] $y, [double] $w, [double] $h) { return (New-Object System.Windows.Rect $x, $y, $w, $h) }

function Draw-Centered($dc, $Text, [double] $Y) { $dc.DrawText($Text, (Pt (($W - $Text.Width) / 2) $Y)) }

function Draw-Background($dc, [string] $Accent = $BLUE) {
    $g = New-Object System.Windows.Media.LinearGradientBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#0B1220')), ([System.Windows.Media.ColorConverter]::ConvertFromString('#1E1B4B')), 35.0
    $dc.DrawRectangle($g, $null, (Rect 0 0 $W $H))
    $glow = New-Object System.Windows.Media.RadialGradientBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Accent)), ([System.Windows.Media.Colors]::Transparent)
    $glow.Opacity = 0.28
    $dc.DrawEllipse($glow, $null, (Pt 260 160), 720, 520)
    $glow2 = $glow.Clone(); $glow2.Opacity = 0.16
    $dc.DrawEllipse($glow2, $null, (Pt ($W - 200) ($H - 80)), 680, 480)
}

function Draw-Brand($dc) {
    $dc.DrawRoundedRectangle((New-Brush '#4F46E5'), $null, (Rect 56 34 44 44), 12, 12)
    $g = New-Text ([string] [char] 0xE964) 22 $White 'Normal' 0 'Left' $Glyphs
    $dc.DrawText($g, (Pt (78 - $g.Width / 2) (56 - $g.Height / 2)))
    $dc.DrawText((New-Text 'Smart PC Tools' 24 $White 'SemiBold'), (Pt 114 40))
}

function Draw-IconCircle($dc, [double] $Cx, [double] $Cy, [double] $Radius, [int] $Glyph, [string] $Accent, [double] $Alpha = 1.0) {
    $dc.PushOpacity($Alpha)
    $dc.DrawEllipse((New-Brush $Accent 0.18), (New-Object System.Windows.Media.Pen (New-Brush $Accent 0.55), 2), (Pt $Cx $Cy), $Radius, $Radius)
    $g = New-Text ([string] [char] $Glyph) ($Radius * 0.9) (New-Brush $Accent) 'Normal' 0 'Left' $Glyphs
    $dc.DrawText($g, (Pt ($Cx - $g.Width / 2) ($Cy - $g.Height / 2)))
    $dc.Pop()
}

function Draw-Subtitle($dc, [string] $Text, [double] $Alpha) {
    if (-not $Text -or $Alpha -le 0) { return }
    $t = New-Text $Text 38 $White 'SemiBold' 1500 'Center'
    $pad = 26
    $box = Rect (($W - [math]::Min(1560, $t.Width + 2 * $pad)) / 2) (968 - $t.Height / 2 - 14) ([math]::Min(1560, $t.Width + 2 * $pad)) ($t.Height + 28)
    $dc.PushOpacity($Alpha)
    $dc.DrawRoundedRectangle((New-Brush '#020617' 0.82), $null, $box, 16, 16)
    $dc.DrawText($t, (Pt (($W - 1500) / 2) ($box.Y + 14)))
    $dc.Pop()
}

function Draw-Chip($dc, [string] $Text, [string] $Accent) {
    $t = New-Text $Text 22 $White 'SemiBold'
    $box = Rect ($W - 56 - $t.Width - 44) 36 ($t.Width + 44) 42
    $dc.DrawRoundedRectangle((New-Brush $Accent 0.22), (New-Object System.Windows.Media.Pen (New-Brush $Accent 0.7), 1.5), $box, 21, 21)
    $dc.DrawText($t, (Pt ($box.X + 22) ($box.Y + 7)))
}

$ChapterInfo = @{ 1 = @{ Name = 'Smart Transfer'; Accent = $BLUE }; 2 = @{ Name = 'Smart Cleanup'; Accent = $TEAL }; 3 = @{ Name = 'Smart Memory'; Accent = $INDIGO } }

function Draw-Card($dc, $Scene, [double] $Time) {
    # The scenes without a screenshot. Parts fade in one after another.
    $accent = $BLUE; if ($Scene.Accent) { $accent = $Scene.Accent }
    Draw-Background $dc $accent
    Draw-Brand $dc
    $in = { param([double] $at) Get-Ease (($Time - $at) / 0.5) }
    switch ($Scene.Kind) {
        'Title' {
            $dc.PushOpacity((& $in 0.1))
            Draw-Centered $dc (New-Text 'Smart PC Tools' 112 $White 'Bold') 300
            $dc.Pop()
            $dc.PushOpacity((& $in 0.6))
            Draw-Centered $dc (New-Text 'Three free, simple tools for a full phone, a full PC and a slow laptop.' 38 $Soft 'Normal' 1400 'Center') 460
            $dc.Pop()
            $x = $W / 2 - 220
            foreach ($i in @(@(0xE895, $BLUE), @(0xE9D9, $TEAL), @(0xE964, $INDIGO))) { Draw-IconCircle $dc $x 650 54 $i[0] $i[1] (& $in (1.0 + ($x - ($W / 2 - 220)) / 1100)); $x += 220 }
        }
        'Problem' {
            Draw-Centered $dc (New-Text 'Sound familiar?' 76 $White 'Bold') 170
            $rows = @(
                @(0xE8EA, $BLUE, 'Moving photos off your phone takes hours - and you never know if every file arrived.'),
                @(0xEDA2, $TEAL, 'Your PC is full of duplicates, junk and old downloads you can''t even find.'),
                @(0xE964, $INDIGO, 'Your laptop slows down with just a few apps open.')
            )
            $y = 360
            for ($i = 0; $i -lt 3; $i++) {
                $a = & $in (0.6 + $i * 1.6)
                $dc.PushOpacity($a)
                # The text decides the height of its row, so a two-line point still fits.
                $text = New-Text $rows[$i][2] 34 $White 'SemiBold' 1120
                $rowH = [math]::Max(130, $text.Height + 56)
                $top = $y - 20 + (1 - $a) * 20
                $dc.DrawRoundedRectangle((New-Brush '#FFFFFF' 0.06), (New-Object System.Windows.Media.Pen (New-Brush '#FFFFFF' 0.12), 1), (Rect 300 $top 1320 $rowH), 22, 22)
                Draw-IconCircle $dc 380 ($top + $rowH / 2) 42 $rows[$i][0] $rows[$i][1]
                $dc.DrawText($text, (Pt 460 ($top + ($rowH - $text.Height) / 2)))
                $dc.Pop()
                $y += 170
            }
        }
        'Meet' {
            Draw-Centered $dc (New-Text 'Meet Smart PC Tools' 76 $White 'Bold') 150
            $tiles = @(
                @(0xE895, $BLUE, 'Smart Transfer', 'Move photos and files from iPhone, Android or any drive - every file checked.'),
                @(0xE9D9, $TEAL, 'Smart Cleanup', 'Find duplicates and junk, free up space, and tidy messy folders.'),
                @(0xE964, $INDIGO, 'Smart Memory', 'Close the apps you don''t need and stop apps starting by themselves.')
            )
            for ($i = 0; $i -lt 3; $i++) {
                $a = & $in (0.4 + $i * 0.45)
                $x = 210 + $i * 520
                $dc.PushOpacity($a)
                $dc.DrawRoundedRectangle((New-Brush '#FFFFFF' 0.07), (New-Object System.Windows.Media.Pen (New-Brush $tiles[$i][1] 0.6), 2), (Rect $x 330 460 400), 26, 26)
                Draw-IconCircle $dc ($x + 90) 420 50 $tiles[$i][0] $tiles[$i][1]
                $dc.DrawText((New-Text $tiles[$i][2] 40 $White 'Bold'), (Pt ($x + 40) 500))
                $dc.DrawText((New-Text $tiles[$i][3] 26 $Soft 'Normal' 380), (Pt ($x + 40) 565))
                $dc.Pop()
            }
            $dc.PushOpacity((& $in 2.0))
            Draw-Centered $dc (New-Text 'Free   ·   No install   ·   No account   ·   Nothing uploaded' 32 (New-Brush $GREEN) 'SemiBold') 790
            $dc.Pop()
        }
        'Start' {
            Draw-Centered $dc (New-Text 'Get started in 3 steps' 76 $White 'Bold') 160
            $steps = @(@('Download', 'Press Code > Download ZIP on GitHub.'), @('Extract', 'Right-click the ZIP > Extract All.'), @('Double-click', 'Open Smart Transfer, Cleanup or Memory.'))
            for ($i = 0; $i -lt 3; $i++) {
                $a = & $in (0.4 + $i * 0.6)
                $x = 210 + $i * 520
                $dc.PushOpacity($a)
                $dc.DrawRoundedRectangle((New-Brush '#FFFFFF' 0.07), (New-Object System.Windows.Media.Pen (New-Brush '#FFFFFF' 0.14), 1.5), (Rect $x 330 460 330), 26, 26)
                $dc.DrawEllipse((New-Brush $BLUE), $null, (Pt ($x + 80) 410), 40, 40)
                $n = New-Text ([string] ($i + 1)) 40 $White 'Bold'; $dc.DrawText($n, (Pt ($x + 80 - $n.Width / 2) (410 - $n.Height / 2)))
                $dc.DrawText((New-Text $steps[$i][0] 42 $White 'Bold'), (Pt ($x + 40) 480))
                $dc.DrawText((New-Text $steps[$i][1] 28 $Soft 'Normal' 380), (Pt ($x + 40) 545))
                $dc.Pop()
            }
            $dc.PushOpacity((& $in 2.2))
            Draw-Centered $dc (New-Text 'Windows 10 or 11  ·  nothing else needed' 30 $Muted 'SemiBold') 730
            $dc.Pop()
        }
        'Chapter' {
            $a = & $in 0.05
            $dc.PushOpacity($a)
            Draw-IconCircle $dc ($W / 2) 330 86 $Scene.Icon $accent
            Draw-Centered $dc (New-Text ('{0}  ·  {1}' -f $Scene.No, $Scene.Name) 92 $White 'Bold') 460
            Draw-Centered $dc (New-Text $Scene.Tagline 40 $Soft 'Normal' 1500 'Center') 600
            $dc.Pop()
        }
        'Trust' {
            Draw-Centered $dc (New-Text 'You stay in control' 76 $White 'Bold') 170
            $rows = @('Nothing is deleted, moved or closed until you have seen it and said yes.',
                      'Removed files go to the Recycle Bin first.',
                      'Windows and your programs are never touched.',
                      'Everything stays on your PC - nothing is uploaded.')
            $y = 340
            for ($i = 0; $i -lt 4; $i++) {
                $a = & $in (0.4 + $i * 0.6)
                $dc.PushOpacity($a)
                $dc.DrawEllipse((New-Brush $GREEN), $null, (Pt 430 ($y + 24)), 24, 24)
                $c = New-Text ([string] [char] 0xE73E) 24 $White 'Normal' 0 'Left' $Glyphs
                $dc.DrawText($c, (Pt (430 - $c.Width / 2) ($y + 24 - $c.Height / 2)))
                $dc.DrawText((New-Text $rows[$i] 36 $White 'SemiBold' 1100), (Pt 485 ($y + 2)))
                $dc.Pop()
                $y += 110
            }
        }
        'Stat' {
            $dc.PushOpacity((& $in 0.1))
            Draw-Centered $dc (New-Text 'A real move, on my own PC' 44 $Soft 'SemiBold') 210
            $dc.Pop()
            $count = [int] (27120 * (Get-Ease (($Time - 0.4) / 1.6)))
            Draw-Centered $dc (New-Text ($count.ToString('N0', $Culture)) 190 (New-Brush $BLUE) 'Bold') 290
            $dc.PushOpacity((& $in 1.2))
            Draw-Centered $dc (New-Text 'photos and videos moved  ·  253 GB' 46 $White 'SemiBold') 540
            $dc.Pop()
            $dc.PushOpacity((& $in 2.2))
            $t = New-Text ('27,120 of 27,120 verified  ·  0 lost') 44 (New-Brush $GREEN) 'Bold'
            $box = Rect (($W - $t.Width) / 2 - 36) 650 ($t.Width + 72) ($t.Height + 30)
            $dc.DrawRoundedRectangle((New-Brush $GREEN 0.14), (New-Object System.Windows.Media.Pen (New-Brush $GREEN 0.6), 2), $box, 18, 18)
            $dc.DrawText($t, (Pt (($W - $t.Width) / 2) 665))
            $dc.Pop()
        }
        'Cta' {
            Draw-Centered $dc (New-Text 'Try it free' 104 $White 'Bold') 200
            $dc.PushOpacity((& $in 0.5))
            $u = New-Text 'github.com/sashankbanda/smart-pc-tools' 50 $White 'SemiBold'
            $box = Rect (($W - $u.Width) / 2 - 44) 390 ($u.Width + 88) ($u.Height + 40)
            $dc.DrawRoundedRectangle((New-Brush '#4F46E5'), $null, $box, 22, 22)
            $dc.DrawText($u, (Pt (($W - $u.Width) / 2) 410))
            $dc.Pop()
            $dc.PushOpacity((& $in 1.2))
            Draw-Centered $dc (New-Text 'Download  ·  Extract  ·  Double-click' 38 $Soft 'SemiBold') 560
            $dc.Pop()
            $dc.PushOpacity((& $in 2.0))
            Draw-Centered $dc (New-Text 'Your feedback is very welcome!' 44 (New-Brush $AMBER) 'Bold') 680
            $dc.Pop()
            $x = $W / 2 - 220
            foreach ($i in @(@(0xE895, $BLUE), @(0xE9D9, $TEAL), @(0xE964, $INDIGO))) { Draw-IconCircle $dc $x 830 44 $i[0] $i[1] (& $in 2.4); $x += 220 }
        }
    }
}

function Get-Image([string] $Name) {
    $path = Join-Path $Shots "$Name.png"
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing screenshot $Name.png - run without -SkipCapture first." }
    $img = New-Object System.Windows.Media.Imaging.BitmapImage
    $img.BeginInit(); $img.CacheOption = 'OnLoad'; $img.UriSource = New-Object System.Uri $path; $img.EndInit(); $img.Freeze()
    return $img
}

function Draw-Shot($dc, $Scene, $Image, [double] $Time) {
    # The real screen in a rounded frame with a soft shadow, slowly zooming towards what matters.
    $info = $ChapterInfo[$Scene.Chapter]
    Draw-Background $dc $info.Accent
    Draw-Brand $dc
    Draw-Chip $dc ('{0}  ·  {1}' -f $Scene.Chapter, $info.Name) $info.Accent
    $ih = 790.0; $iw = $ih * $Image.PixelWidth / $Image.PixelHeight
    $frame = Rect (($W - $iw) / 2) 112 $iw $ih
    for ($s = 1; $s -le 6; $s++) {
        $grow = $s * 7
        $dc.DrawRoundedRectangle((New-Brush '#000000' 0.06), $null, (Rect ($frame.X - $grow + 6) ($frame.Y - $grow + 18) ($frame.Width + 2 * $grow) ($frame.Height + 2 * $grow)), 18 + $grow, 18 + $grow)
    }
    $z = 1 + 0.03 * (Get-Ease ($Time / $Scene.Seconds))
    $fx = $Scene.Focus[0]; $fy = $Scene.Focus[1]
    $img = Rect ($frame.X - ($z - 1) * $frame.Width * $fx) ($frame.Y - ($z - 1) * $frame.Height * $fy) ($frame.Width * $z) ($frame.Height * $z)
    $dc.PushClip((New-Object System.Windows.Media.RectangleGeometry $frame, 16, 16))
    # The window's own light background: a screenshot of its content is see-through there.
    $dc.DrawRectangle((New-Brush '#F1F5F9'), $null, $frame)
    $dc.DrawImage($Image, $img)
    $dc.Pop()
    $dc.DrawRoundedRectangle($null, (New-Object System.Windows.Media.Pen (New-Brush '#FFFFFF' 0.18), 1.5), $frame, 16, 16)
}

function Save-Png($Bitmap, [string] $Path) {
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
    $stream = [System.IO.File]::Create($Path); $encoder.Save($stream); $stream.Close()
}

function Format-SrtTime([double] $Seconds) {
    $t = [TimeSpan]::FromSeconds($Seconds)
    return ('{0:00}:{1:00}:{2:00},{3:000}' -f [int] [math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds, $t.Milliseconds)
}

function Render-Video {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Output) | Out-Null
    if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Force }
    if ($PreviewDir) { New-Item -ItemType Directory -Force -Path $PreviewDir | Out-Null }
    # The sound track: every scene's sentence, starting a moment after the scene does.
    $perFrame = [int] ($AudioRate / $Fps)
    $track = $null
    if (-not $NoVoice) {
        $frameCount = 0; foreach ($s in $Scenes) { $frameCount += [int] ($s.Seconds * $Fps) }
        $track = New-Object int16[] ($frameCount * $perFrame)
        $at = 0
        foreach ($s in $Scenes) {
            if ($s.Speech) {
                $start = $at * $perFrame + [int] ($VoiceLead * $AudioRate)
                [Array]::Copy($s.Speech, 0, $track, $start, [math]::Min($s.Speech.Length, $track.Length - $start))
            }
            $at += [int] ($s.Seconds * $Fps)
        }
        $writer = New-Object TutorialVideo.Mp4Writer($Output, $W, $H, $Fps, $Bitrate, $AudioRate, 2)
    }
    else { $writer = New-Object TutorialVideo.Mp4Writer($Output, $W, $H, $Fps, $Bitrate) }
    $pcm = New-Object byte[] ($perFrame * 4)
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($W, $H, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $pixels = New-Object byte[] ($W * $H * 4)
    $full = Rect 0 0 $W $H
    $fade = 0.4
    $previous = $null
    $srt = New-Object System.Text.StringBuilder
    $clock = 0.0; $total = 0; $no = 0
    try {
        foreach ($scene in $Scenes) {
            $no++
            $image = $null; if ($scene.Kind -eq 'Shot') { $image = Get-Image $scene.Shot }
            $frames = [int] ($scene.Seconds * $Fps)
            for ($f = 0; $f -lt $frames; $f++) {
                $time = $f / $Fps
                $dv = New-Object System.Windows.Media.DrawingVisual
                $dc = $dv.RenderOpen()
                if ($image) { Draw-Shot $dc $scene $image $time; Draw-Subtitle $dc $scene.Caption (Get-Ease (($time - 0.15) / 0.35)) }
                else { Draw-Card $dc $scene $time }
                if ($previous -and $time -lt $fade) { $dc.PushOpacity(1 - (Get-Ease ($time / $fade))); $dc.DrawImage($previous, $full); $dc.Pop() }
                $dc.Close()
                $rtb.Clear(); $rtb.Render($dv)
                $rtb.CopyPixels($pixels, $W * 4, 0)
                $writer.WriteFrame($pixels)
                if ($track) { [PromoAudio]::Stereo($track, [int64] $total * $perFrame, $perFrame, $pcm); $writer.WriteAudio($pcm, $pcm.Length) }
                if ($PreviewDir -and $f -eq [int] ($frames * 0.8)) { Save-Png $rtb (Join-Path $PreviewDir ('scene-{0:00}.png' -f $no)) }
                $total++
            }
            $previous = $rtb.Clone(); $previous.Freeze()
            [void] $srt.AppendLine([string] $no)
            [void] $srt.AppendLine(('{0} --> {1}' -f (Format-SrtTime ($clock + 0.15)), (Format-SrtTime ($clock + $scene.Seconds - 0.05))))
            [void] $srt.AppendLine($scene.Caption)
            [void] $srt.AppendLine()
            $clock += $scene.Seconds
            $label = $scene.Kind; if ($scene.Shot) { $label = $scene.Shot }
            Write-Host ("  scene {0,2} {1,-24} {2,4} frames" -f $no, $label, $frames)
        }
    }
    finally { $writer.Dispose() }
    $srtPath = [System.IO.Path]::ChangeExtension($Output, '.srt')
    [System.IO.File]::WriteAllText($srtPath, $srt.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("Video written: {0}  ({1} frames, {2:N1} s, {3:N1} MB)" -f $Output, $total, ($total / $Fps), ((Get-Item -LiteralPath $Output).Length / 1MB))
    Write-Host ("Subtitles:     {0}" -f $srtPath)
}

if (-not $SkipCapture) { Invoke-Capture }
if ($CaptureOnly) { return }
if (-not $NoVoice) { Get-Speech }
Render-Video
