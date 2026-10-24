<#
.SYNOPSIS
    Scans a cabled iPhone (or any folder), reports what is on it, and copies the photos and
    videos to a folder on the PC - verified, resumable, with live progress.

.DESCRIPTION
    An iPhone connected by cable appears as an MTP device: it has no drive letter, so cp,
    robocopy and Get-ChildItem cannot read it. This script talks to the same Windows shell
    interface Explorer uses, so it can walk the device directly.

    The run has four steps:

      1. SCAN     Every folder is read first. You get a report per folder (file count,
                  photos / videos / other, size, date range) and a breakdown by file type.
      2. PLAN     The scan is compared with the destination: files already there are
                  skipped, a same-named but different file is kept alongside as name_1.ext.
      3. COPY     Each file is streamed into a staging area on the destination drive, its
                  size is checked against what the phone reported, its SHA-256 is computed
                  on the way in and checked again by reading the file back, timestamps are
                  restored, and only then is it moved into place - so a file at its final
                  path is always complete. One file failing never stops the run: it is
                  retried, the script waits for an unplugged phone to come back, and
                  whatever still fails is listed at the end. Re-run the same command to
                  pick up where it stopped.
      4. SUMMARY  Counts, bytes, speed, failures, and where the log and manifest are.

    Progress is shown live: overall bytes and percent, throughput, ETA, and the current file.

    The source may be a device path ("This PC\Apple iPhone\Internal Storage") or an
    ordinary folder ("E:\DCIM") - both work. Started without arguments, the script finds
    the phone and asks for everything it needs.

.PARAMETER Source
    "This PC\Apple iPhone\Internal Storage", a month folder inside it, or a normal folder.
    Leave out to be asked.

.PARAMETER Destination
    Folder on the PC to copy into. Created if missing. Leave out to be asked.

.PARAMETER Extensions
    File types to copy. Default: .MOV .JPG .HEIC .PNG .MP4. Use '*' for everything.

.PARAMETER Folders
    One or more wildcards for the first-level folders to read, e.g. "2026*","202508_*".
    Default: all of them.

.PARAMETER Flat
    Put every file straight into the destination instead of recreating 202406_a\...

.PARAMETER Overwrite
    Replace a same-named file that has a different size (default: keep both as name_1.ext).

.PARAMETER DryRun
    Scan, plan, and list what would be copied - without writing anything.

.PARAMETER ScanOnly
    Scan and print the report, then stop. No destination needed.

.PARAMETER NoVerify
    Skip reading each copied file back to compare its hash. The size check still happens.

.PARAMETER Retries
    How many times a failing file is tried again (default 3).

.PARAMETER ReconnectWaitMinutes
    How long to wait for the phone to come back after it disappears mid-copy (default 10).

.PARAMETER Yes
    Never ask a question: accept the defaults and start copying.

.PARAMETER LogDirectory
    Where the log, manifest and scan report go. Default: <Destination>\.iphone-transfer

.PARAMETER Engine
    Stream (default) reads the file bytes directly, which gives exact progress and hashing.
    Shell uses the Explorer copy operation instead, as a fallback.

.PARAMETER BufferMB
    Read buffer size for the Stream engine in megabytes (default 4; bigger is faster on USB).

.EXAMPLE
    .\Copy-IPhoneMedia.ps1
    Interactive: finds the phone, scans it, asks where to copy.

.EXAMPLE
    .\Copy-IPhoneMedia.ps1 "This PC\Apple iPhone\Internal Storage" -ScanOnly
    Just the report: what is on the phone, per folder and per file type.

.EXAMPLE
    .\Copy-IPhoneMedia.ps1 "This PC\Apple iPhone\Internal Storage" "D:\Photos" -Folders "2026*"

.EXAMPLE
    .\Copy-IPhoneMedia.ps1 "This PC\Apple iPhone\Internal Storage" "D:\Photos" -DryRun

.NOTES
    Exit codes: 0 all good, 1 could not start (bad arguments, device not found),
                2 finished but some files failed, 3 interrupted (Ctrl+C or device gone).
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Source = '',

    [Parameter(Position = 1)]
    [string] $Destination = '',

    [string[]] $Extensions = @('.MOV', '.JPG', '.HEIC', '.PNG', '.MP4'),

    [string[]] $Folders = @('*'),

    [switch] $Flat,

    [switch] $Overwrite,

    [switch] $DryRun,

    [switch] $ScanOnly,

    [switch] $NoVerify,

    [ValidateRange(0, 50)]
    [int] $Retries = 3,

    [ValidateRange(0, 1440)]
    [int] $ReconnectWaitMinutes = 10,

    [switch] $Yes,

    [string] $LogDirectory = '',

    [ValidateSet('Auto', 'Stream', 'Shell')]
    [string] $Engine = 'Auto',

    [ValidateRange(1, 64)]
    [int] $BufferMB = 4
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# constants and run-wide state
# ---------------------------------------------------------------------------

$THIS_PC = 17                                  # ssfDRIVES: the "This PC" shell folder
$COPY_FLAGS = 4 -bor 16 -bor 512 -bor 1024     # silent, no confirmation, no mkdir prompt, no error dialogs
$PHOTO_TYPES   = @('.jpg', '.jpeg', '.heic', '.heif', '.png', '.dng', '.gif', '.tif', '.tiff', '.webp', '.bmp', '.raw', '.cr2', '.arw')
$VIDEO_TYPES   = @('.mov', '.mp4', '.m4v', '.hevc', '.avi', '.3gp', '.mkv', '.wmv')
$SIDECAR_TYPES = @('.aae')

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture

$script:Stamp          = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:Shell          = New-Object -ComObject Shell.Application
$script:NativeReady    = $false
$script:EngineInUse    = 'Shell'
$script:LogWriter      = $null
$script:LogPath        = ''
$script:LogPartial     = ''
$script:OutputBuffer   = New-Object System.Collections.ArrayList   # lines printed before the log file exists
$script:ManifestWriter = $null
$script:ManifestPath   = ''
$script:CurrentStaging = ''
$script:CopyStarted    = $false
$script:SummaryPrinted = $false
$script:ExitCode       = 0
$script:SourceIsDevice = $false
$script:Interactive    = $false
$script:ReadBuffer     = $null

$script:Totals = @{
    Copied = 0; CopiedBytes = [int64] 0; Renamed = 0; Replaced = 0
    Failed = 0; FailedList = New-Object System.Collections.ArrayList
    Exists = 0; ExistsBytes = [int64] 0; Unwanted = 0; UnwantedBytes = [int64] 0
    Pending = 0; StopReason = ''
    CopyStart = $null; CopyEnd = $null
}

# ---------------------------------------------------------------------------
# native helpers (compiled on first run; takes about a second)
#
# ItemStream opens the same byte stream Explorer reads when it copies a file off the
# phone, which lets the script count bytes, hash them and show exact progress.
# GetFreeBytes works for drive letters and UNC paths alike.
# ---------------------------------------------------------------------------

$NativeSource = @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace IPhoneTransfer
{
    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellItem
    {
        [PreserveSig] int BindToHandler(IntPtr pbc, [In] ref Guid bhid, [In] ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object ppv);
        [PreserveSig] int GetParent(out IShellItem ppsi);
        [PreserveSig] int GetDisplayName(uint sigdnName, out IntPtr ppszName);
        [PreserveSig] int GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        [PreserveSig] int Compare(IShellItem psi, uint hint, out int piOrder);
    }

    public static class Native
    {
        [DllImport("shell32.dll", PreserveSig = false)]
        public static extern IShellItem SHCreateItemFromIDList(IntPtr pidl, [In] ref Guid riid);

        [DllImport("shell32.dll", PreserveSig = false)]
        public static extern IntPtr SHGetIDListFromObject([MarshalAs(UnmanagedType.IUnknown)] object punk);

        [DllImport("ole32.dll")]
        public static extern void CoTaskMemFree(IntPtr p);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool GetDiskFreeSpaceEx(string lpDirectoryName, out ulong lpFreeBytesAvailable, out ulong lpTotalNumberOfBytes, out ulong lpTotalNumberOfFreeBytes);

        public static long GetFreeBytes(string path)
        {
            ulong free, total, totalFree;
            if (!GetDiskFreeSpaceEx(path, out free, out total, out totalFree)) return -1;
            return (long)free;
        }
    }

    public sealed class ItemStream : IDisposable
    {
        static readonly Guid IID_IShellItem = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");
        static readonly Guid BHID_Stream    = new Guid("1CEBB3AB-7C10-499a-A417-92CA16C4CB83");
        static readonly Guid IID_IStream    = new Guid("0000000c-0000-0000-C000-000000000046");

        IStream _stream;
        IntPtr _pRead = IntPtr.Zero;
        public long Length = -1;

        public static ItemStream Open(object folderItem)
        {
            IntPtr pidl = Native.SHGetIDListFromObject(folderItem);
            IShellItem item = null;
            try
            {
                Guid iid = IID_IShellItem;
                item = Native.SHCreateItemFromIDList(pidl, ref iid);
                Guid bhid = BHID_Stream;
                Guid iidStream = IID_IStream;
                object o;
                int hr = item.BindToHandler(IntPtr.Zero, ref bhid, ref iidStream, out o);
                if (hr != 0) Marshal.ThrowExceptionForHR(hr);
                ItemStream s = new ItemStream();
                s._stream = (IStream)o;
                s._pRead = Marshal.AllocHGlobal(8);
                try
                {
                    System.Runtime.InteropServices.ComTypes.STATSTG st;
                    s._stream.Stat(out st, 1 /* STATFLAG_NONAME */);
                    s.Length = st.cbSize;
                }
                catch (Exception) { s.Length = -1; }
                return s;
            }
            finally
            {
                if (item != null) Marshal.ReleaseComObject(item);
                Native.CoTaskMemFree(pidl);
            }
        }

        public int Read(byte[] buffer, int count)
        {
            Marshal.WriteInt32(_pRead, 0);
            _stream.Read(buffer, count, _pRead);
            return Marshal.ReadInt32(_pRead);
        }

        public void Dispose()
        {
            if (_stream != null) { try { Marshal.ReleaseComObject(_stream); } catch (Exception) { } _stream = null; }
            if (_pRead != IntPtr.Zero) { Marshal.FreeHGlobal(_pRead); _pRead = IntPtr.Zero; }
        }
    }
}
'@

function Initialize-Native {
    if (-not ('IPhoneTransfer.ItemStream' -as [type])) {
        try {
            Add-Type -TypeDefinition $NativeSource -ErrorAction Stop
        }
        catch {
            Write-Line "Note: could not compile the native helper ($($_.Exception.Message))." Yellow
            Write-Line '      Falling back to the Explorer copy engine; progress per file will be coarser.' Yellow
            $script:NativeReady = $false
            return
        }
    }
    $script:NativeReady = $true
}

# ---------------------------------------------------------------------------
# output: everything goes to the console and to the log file
# ---------------------------------------------------------------------------

function Add-LogText {
    param([string] $Text, [bool] $NewLine)
    if (-not $NewLine) { $script:LogPartial += $Text; return }
    $line = '{0:HH:mm:ss}  {1}{2}' -f (Get-Date), $script:LogPartial, $Text
    $script:LogPartial = ''
    if ($script:LogWriter) { $script:LogWriter.WriteLine($line) }
    else                   { [void] $script:OutputBuffer.Add($line) }
}

function Write-Line {
    param([string] $Text = '', [string] $Color = '', [switch] $NoNewline)
    if ($Color) { Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline }
    else        { Write-Host $Text -NoNewline:$NoNewline }
    Add-LogText -Text $Text -NewLine (-not $NoNewline)
}

function Write-LogOnly {
    param([string] $Text)
    Add-LogText -Text $Text -NewLine $true
}

function Open-Log {
    param([string] $Directory)
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $path = Join-Path $Directory ('transfer-{0}.log' -f $script:Stamp)
    $script:LogWriter = New-Object System.IO.StreamWriter($path, $true, (New-Object System.Text.UTF8Encoding($false)))
    $script:LogWriter.AutoFlush = $true
    foreach ($line in $script:OutputBuffer) { $script:LogWriter.WriteLine($line) }
    $script:OutputBuffer.Clear()
    $script:LogPath = $path
}

function Open-Manifest {
    param([string] $Directory)
    $path = Join-Path $Directory 'manifest.csv'
    $isNew = -not (Test-Path -LiteralPath $path)
    $script:ManifestWriter = New-Object System.IO.StreamWriter($path, $true, (New-Object System.Text.UTF8Encoding($false)))
    $script:ManifestWriter.AutoFlush = $true
    if ($isNew) {
        $script:ManifestWriter.WriteLine('timestamp,status,folder,name,size_bytes,destination,sha256,seconds,attempts,error')
    }
    $script:ManifestPath = $path
}

function ConvertTo-CsvField {
    param($Value)
    $text = [string] $Value
    if ($text -match '[,"\r\n]') { return '"' + $text.Replace('"', '""') + '"' }
    return $text
}

function Write-ManifestRow {
    param([string] $Status, $Job, [string] $FinalPath, [string] $Sha256, [double] $Seconds, [int] $Attempts, [string] $ErrorText)
    if (-not $script:ManifestWriter) { return }
    $fields = @(
        (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'),
        $Status,
        $Job.Entry.Relative,
        $Job.Entry.Name,
        $Job.Entry.Size,
        $FinalPath,
        $Sha256,
        $Seconds.ToString('0.00', $Invariant),
        $Attempts,
        $ErrorText
    )
    $script:ManifestWriter.WriteLine((($fields | ForEach-Object { ConvertTo-CsvField $_ }) -join ','))
}

function Close-Writers {
    foreach ($name in 'LogWriter', 'ManifestWriter') {
        $writer = Get-Variable -Name $name -Scope Script -ValueOnly
        if ($writer) { try { $writer.Close() } catch { } ; Set-Variable -Name $name -Scope Script -Value $null }
    }
}

# ---------------------------------------------------------------------------
# formatting
# ---------------------------------------------------------------------------

function Format-Count {
    param([int64] $Number)
    return $Number.ToString('N0', $Invariant)
}

function Format-Bytes {
    param([double] $Bytes)
    if ($Bytes -lt 1024) { return ('{0} B' -f [int64] $Bytes) }
    $value = $Bytes
    foreach ($unit in 'KB', 'MB', 'GB', 'TB') {
        $value = $value / 1024
        if ($value -lt 1024 -or $unit -eq 'TB') { return ($value.ToString('N1', $Invariant) + ' ' + $unit) }
    }
}

function Format-Rate {
    param([double] $BytesPerSecond)
    return (Format-Bytes $BytesPerSecond) + '/s'
}

function Format-Duration {
    param([TimeSpan] $Span)
    if ($Span.TotalHours -ge 1)   { return ('{0}h {1:00}m {2:00}s' -f [int] [math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds) }
    if ($Span.TotalMinutes -ge 1) { return ('{0}m {1:00}s' -f $Span.Minutes, $Span.Seconds) }
    return ($Span.TotalSeconds.ToString('0.0', $Invariant) + 's')
}

function Get-ErrorText {
    param($ErrorRecord)
    $exception = $ErrorRecord.Exception
    while ($exception.InnerException) { $exception = $exception.InnerException }
    $text = $exception.Message.Trim() -replace '\s+', ' '
    if ($exception -is [System.Runtime.InteropServices.COMException] -or $exception.HResult -lt 0) {
        $text += (' (0x{0:X8})' -f $exception.HResult)
    }
    return $text
}

function Test-DiskFull {
    param($ErrorRecord)
    $exception = $ErrorRecord.Exception
    while ($exception) {
        if (($exception.HResult -band 0xFFFF) -eq 0x70 -or ($exception.HResult -band 0xFFFF) -eq 0x27) { return $true }   # ERROR_DISK_FULL, ERROR_HANDLE_DISK_FULL
        if ($exception.Message -match 'not enough space') { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

# ---------------------------------------------------------------------------
# talking to the shell: device folders, file names, sizes, dates
# ---------------------------------------------------------------------------

function Get-ShellProperty {
    # ExtendedProperty is the only way to get real values off a phone: Size and
    # ModifyDate on the item itself come back empty for MTP devices.
    param($Item, [string] $Name)
    try {
        $value = $Item.ExtendedProperty($Name)
        if ($null -eq $value -or $value -is [System.DBNull]) { return $null }
        return $value
    }
    catch { return $null }
}

function Get-RealName {
    # With "Hide extensions for known file types" on, the shell hands back "IMG_1234"
    # instead of "IMG_1234.JPG". The file name property is never trimmed.
    param($Item)
    $name = Get-ShellProperty $Item 'System.FileName'
    if ($name) { return [string] $name }
    if ($Item.IsFileSystem) { return [System.IO.Path]::GetFileName($Item.Path) }
    $name = [string] $Item.Name
    $type = Get-ShellProperty $Item 'System.ItemType'
    if ($type -and $type.StartsWith('.') -and -not $name.ToLowerInvariant().EndsWith($type.ToLowerInvariant())) { $name += $type }
    return $name
}

function Get-ItemBytes {
    param($Item)
    if ($Item.IsFileSystem) {
        try { return (New-Object System.IO.FileInfo($Item.Path)).Length } catch { }
    }
    $value = Get-ShellProperty $Item 'System.Size'
    if ($null -ne $value) { try { return [int64] $value } catch { } }
    try { return [int64] $Item.Size } catch { return [int64] 0 }
}

function Get-ItemTimeUtc {
    # The shell reports device times as UTC values with no zone attached.
    param($Item, [string] $Property)
    if ($Item.IsFileSystem) {
        try {
            if ($Property -eq 'System.DateCreated') { return [System.IO.File]::GetCreationTimeUtc($Item.Path) }
            return [System.IO.File]::GetLastWriteTimeUtc($Item.Path)
        }
        catch { }
    }
    $value = Get-ShellProperty $Item $Property
    if ($value -is [DateTime]) {
        if ($value.Year -lt 1980) { return $null }
        return [DateTime]::SpecifyKind($value, [DateTimeKind]::Utc)
    }
    return $null
}

function Get-Category {
    param([string] $Extension)
    if ($PHOTO_TYPES -contains $Extension)   { return 'photo' }
    if ($VIDEO_TYPES -contains $Extension)   { return 'video' }
    if ($SIDECAR_TYPES -contains $Extension) { return 'sidecar' }
    return 'other'
}

function Split-DevicePath {
    param([string] $Path)
    $parts = @($Path -split '[\\/]+' | Where-Object { $_ -ne '' })
    if ($parts.Count -gt 0 -and @('this pc', 'computer', 'my computer') -contains $parts[0].ToLower()) {
        if ($parts.Count -gt 1) { $parts = $parts[1..($parts.Count - 1)] } else { $parts = @() }
    }
    return $parts
}

function Resolve-DeviceFolder {
    param([string] $Path)

    $folder = $script:Shell.NameSpace($THIS_PC)
    $walked = 'This PC'

    foreach ($part in (Split-DevicePath $Path)) {
        $next = $null
        foreach ($item in $folder.Items()) {
            if ($item.IsFolder -and $item.Name -eq $part) { $next = $item.GetFolder; break }
        }
        if ($null -eq $next) {
            $available = ($folder.Items() | Where-Object { $_.IsFolder } | ForEach-Object { $_.Name }) -join ', '
            throw "'$part' not found under $walked.`nAvailable: $available`nIs the phone plugged in, unlocked, and 'Trust This Computer' accepted?"
        }
        $folder = $next
        $walked = "$walked\$part"
    }
    return $folder
}

function Get-SourceFolder {
    param([string] $Path)
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $full = (Resolve-Path -LiteralPath $Path).ProviderPath
        $folder = $script:Shell.NameSpace($full)
        if ($null -eq $folder) { throw "Cannot open folder $full" }
        return $folder
    }
    return Resolve-DeviceFolder -Path $Path
}

function Test-SourceAvailable {
    try { [void] (Get-SourceFolder -Path $Source); return $true } catch { return $false }
}

function Get-SourceItem {
    # A fresh handle for one file, used after the device hiccups or comes back from a disconnect.
    param($Job)
    $folderPath = $Source
    if ($Job.Entry.Relative) { $folderPath = Join-Path $Source $Job.Entry.Relative }
    $folder = Get-SourceFolder -Path $folderPath
    $item = $folder.ParseName($Job.Entry.Name)
    if ($null -eq $item) { throw "'$($Job.Entry.Name)' is no longer listed in $folderPath" }
    return $item
}

# ---------------------------------------------------------------------------
# step 1: scan
# ---------------------------------------------------------------------------

$script:Scan = @{ Start = $null; FolderIndex = 0; FolderCount = 0; FilesSoFar = 0; BytesSoFar = [int64] 0; FolderFiles = 0; FolderBytes = [int64] 0; FolderName = ''; LastRender = [DateTime]::MinValue }

function Update-ScanProgress {
    param([switch] $Force, [switch] $Done)
    $s = $script:Scan
    if ($Done) { Write-Progress -Id 1 -Activity 'Scanning' -Completed; return }
    $now = [DateTime]::UtcNow
    if (-not $Force -and ($now - $s.LastRender).TotalMilliseconds -lt 200) { return }
    $s.LastRender = $now
    $percent = 0
    if ($s.FolderCount -gt 0) { $percent = [int] [math]::Max(0, [math]::Min(99, [math]::Floor(($s.FolderIndex - 1) * 100 / $s.FolderCount))) }
    $status = 'Folder {0} of {1}: {2} ({3} files, {4} so far)  |  total {5} files, {6}  |  elapsed {7}' -f `
        $s.FolderIndex, $s.FolderCount, $s.FolderName, (Format-Count $s.FolderFiles), (Format-Bytes $s.FolderBytes), `
        (Format-Count $s.FilesSoFar), (Format-Bytes $s.BytesSoFar), (Format-Duration ($now - $s.Start))
    Write-Progress -Id 1 -Activity "Scanning $script:SourceLabel" -Status $status -PercentComplete $percent
    try { $Host.UI.RawUI.WindowTitle = 'Scanning {0}/{1} - {2} files' -f $s.FolderIndex, $s.FolderCount, (Format-Count $s.FilesSoFar) } catch { }
}

function Read-FolderEntries {
    # Reads one folder (and everything below it) into $Bag. Reading a folder off a phone
    # costs about a tenth of a second per file, so progress is updated as it goes.
    param($Folder, [string] $Relative, [string] $Top, $Bag)

    foreach ($item in $Folder.Items()) {
        if ($item.IsFolder) {
            $childRelative = $item.Name
            if ($Relative) { $childRelative = Join-Path $Relative $item.Name }
            Read-FolderEntries -Folder $item.GetFolder -Relative $childRelative -Top $Top -Bag $Bag
            continue
        }

        $name = Get-RealName $item
        $extension = [System.IO.Path]::GetExtension($name).ToLowerInvariant()
        $size = Get-ItemBytes $item
        [void] $Bag.Add([pscustomobject] @{
            Top       = $Top
            Relative  = $Relative
            Name      = $name
            Extension = $extension
            Category  = Get-Category $extension
            Size      = $size
            Modified  = Get-ItemTimeUtc $item 'System.DateModified'
            Created   = Get-ItemTimeUtc $item 'System.DateCreated'
            Item      = $item
        })

        $s = $script:Scan
        $s.FolderFiles++; $s.FolderBytes += $size; $s.FilesSoFar++; $s.BytesSoFar += $size
        Update-ScanProgress
    }
}

function Read-FolderWithRetry {
    param($TopItem, [string] $Top)
    $attempts = 0
    while ($true) {
        $attempts++
        $bag = New-Object System.Collections.ArrayList
        $before = @($script:Scan.FilesSoFar, $script:Scan.BytesSoFar)
        $script:Scan.FolderFiles = 0; $script:Scan.FolderBytes = [int64] 0
        try {
            Read-FolderEntries -Folder $TopItem.GetFolder -Relative $Top -Top $Top -Bag $bag
            return , $bag   # the comma keeps an empty list from unrolling into nothing
        }
        catch {
            $script:Scan.FilesSoFar = $before[0]; $script:Scan.BytesSoFar = $before[1]
            $text = Get-ErrorText $_
            if ($attempts -gt 3) { throw "could not read folder $Top after $attempts attempts: $text" }
            Write-Line ''
            Write-Line "    problem reading $Top ($text) - trying again in 5 s" Yellow
            Start-Sleep -Seconds 5
            if ($script:SourceIsDevice -and -not (Test-SourceAvailable)) {
                if (-not (Wait-ForSource)) { throw "device did not come back while reading $Top" }
            }
            Write-Line ('  {0,-14}' -f $Top) -NoNewline
        }
    }
}

function Invoke-Scan {
    param($RootFolder)

    $result = @{ Files = New-Object System.Collections.ArrayList; Folders = New-Object System.Collections.ArrayList; Unreadable = New-Object System.Collections.ArrayList; Elapsed = $null; Empty = New-Object System.Collections.ArrayList }
    $script:Scan.Start = [DateTime]::UtcNow

    $topItems = @($RootFolder.Items())
    $topFolders = @($topItems | Where-Object { $_.IsFolder } | Sort-Object { $_.Name })
    $selected = @($topFolders | Where-Object { $name = $_.Name; ($Folders | Where-Object { $name -like $_ }).Count -gt 0 })
    $rootFiles = @($topItems | Where-Object { -not $_.IsFolder })

    $script:Scan.FolderCount = $selected.Count
    if ($rootFiles.Count -gt 0) {
        # Files sitting directly in the source (a month folder given as the source, or a plain folder).
        $script:Scan.FolderIndex = 0; $script:Scan.FolderName = '(files in the source folder)'
        Write-Line ('  {0,-14}' -f '(root)') -NoNewline
        $bag = New-Object System.Collections.ArrayList
        $script:Scan.FolderFiles = 0; $script:Scan.FolderBytes = [int64] 0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        foreach ($item in $rootFiles) {
            $name = Get-RealName $item
            $extension = [System.IO.Path]::GetExtension($name).ToLowerInvariant()
            $size = Get-ItemBytes $item
            [void] $bag.Add([pscustomobject] @{ Top = ''; Relative = ''; Name = $name; Extension = $extension; Category = (Get-Category $extension); Size = $size; Modified = (Get-ItemTimeUtc $item 'System.DateModified'); Created = (Get-ItemTimeUtc $item 'System.DateCreated'); Item = $item })
            $script:Scan.FolderFiles++; $script:Scan.FolderBytes += $size; $script:Scan.FilesSoFar++; $script:Scan.BytesSoFar += $size
            Update-ScanProgress
        }
        Write-Line ('{0,7} files  {1,10}  {2}' -f (Format-Count $bag.Count), (Format-Bytes $script:Scan.FolderBytes), (Format-Duration $sw.Elapsed))
        [void] $result.Folders.Add([pscustomobject] @{ Name = ''; Files = $bag.Count; Bytes = $script:Scan.FolderBytes; Seconds = $sw.Elapsed.TotalSeconds })
        $result.Files.AddRange($bag)
    }

    if ($selected.Count -eq 0) {
        $names = ($topFolders | ForEach-Object { $_.Name }) -join ', '
        if ($rootFiles.Count -eq 0) { throw "No folder under the source matches '$($Folders -join ', ')'. Folders there: $names" }
        Write-Line "  No folder matches '$($Folders -join ', ')' - only the files directly in the source are included. Folders there: $names" Yellow
    }

    $index = 0
    foreach ($topItem in $selected) {
        $index++
        $top = $topItem.Name
        $script:Scan.FolderIndex = $index; $script:Scan.FolderName = $top
        Update-ScanProgress -Force
        Write-Line ('  {0,-14}' -f $top) -NoNewline
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $bag = Read-FolderWithRetry -TopItem $topItem -Top $top
        }
        catch {
            Write-Line ("UNREADABLE: " + (Get-ErrorText $_)) Red
            [void] $result.Unreadable.Add($top)
            continue
        }
        $sw.Stop()
        Write-Line ('{0,7} files  {1,10}  {2}' -f (Format-Count $bag.Count), (Format-Bytes $script:Scan.FolderBytes), (Format-Duration $sw.Elapsed))
        [void] $result.Folders.Add([pscustomobject] @{ Name = $top; Files = $bag.Count; Bytes = $script:Scan.FolderBytes; Seconds = $sw.Elapsed.TotalSeconds; Item = $topItem })
        $result.Files.AddRange($bag)
        if ($bag.Count -eq 0) { [void] $result.Empty.Add($top) }
    }

    # A phone often lists a folder as empty the first time it is asked and fills it in on a
    # later read. Asking once more a moment later catches most of those.
    if ($script:SourceIsDevice -and $result.Empty.Count -gt 0) {
        Write-Line ''
        Write-Line ("  {0} folder(s) listed no files - asking the phone again..." -f $result.Empty.Count)
        Start-Sleep -Seconds 3
        $stillEmpty = New-Object System.Collections.ArrayList
        foreach ($top in @($result.Empty)) {
            $folderInfo = $result.Folders | Where-Object { $_.Name -eq $top } | Select-Object -First 1
            $script:Scan.FolderName = $top
            try { $bag = Read-FolderWithRetry -TopItem $folderInfo.Item -Top $top } catch { [void] $stillEmpty.Add($top); continue }
            if ($bag.Count -gt 0) {
                Write-Line ('  {0,-14}{1,7} files  {2,10}  (second read)' -f $top, (Format-Count $bag.Count), (Format-Bytes $script:Scan.FolderBytes))
                $folderInfo.Files = $bag.Count; $folderInfo.Bytes = $script:Scan.FolderBytes
                $result.Files.AddRange($bag)
            }
            else { [void] $stillEmpty.Add($top) }
        }
        $result.Empty = $stillEmpty
    }

    Update-ScanProgress -Done
    $result.Elapsed = [DateTime]::UtcNow - $script:Scan.Start
    return $result
}

function Get-WantedSet {
    # Normalises the -Extensions list: 'jpg', '.JPG' and 'JPG' all become '.jpg'. '*' means everything.
    param([string[]] $List)
    $set = @{}
    foreach ($raw in $List) {
        foreach ($piece in ($raw -split '[,\s]+')) {
            $e = $piece.Trim().ToLowerInvariant()
            if (-not $e) { continue }
            if ($e -eq '*' -or $e -eq 'all') { return $null }
            if (-not $e.StartsWith('.')) { $e = '.' + $e }
            $set[$e] = $true
        }
    }
    return $set
}

function Test-Wanted {
    param($Entry, $WantedSet)
    if ($null -eq $WantedSet) { return $true }
    return $WantedSet.ContainsKey($Entry.Extension)
}

function Write-ScanReport {
    param($Scan, $WantedSet, [string] $Title)

    $lines = New-Object System.Collections.ArrayList
    $add = { param($t) [void] $lines.Add($t); Write-Line $t }

    $files = $Scan.Files
    $totalBytes = [int64] 0
    foreach ($f in $files) { $totalBytes += $f.Size }

    & $add ''
    & $add ('Scan of {0}' -f $Title)
    & $add ('  {0} folders, {1} files, {2}, read in {3}' -f $Scan.Folders.Count, (Format-Count $files.Count), (Format-Bytes $totalBytes), (Format-Duration $Scan.Elapsed))
    & $add ''

    $header = '  {0,-16} {1,8} {2,8} {3,8} {4,8} {5,11}  {6}' -f 'Folder', 'Files', 'Photos', 'Videos', 'Other', 'Size', 'Dates'
    & $add $header
    & $add ('  ' + ('-' * ($header.Length - 2)))

    $grand = @{ Files = 0; Photos = 0; Videos = 0; Other = 0; Bytes = [int64] 0 }
    foreach ($folder in $Scan.Folders) {
        $group = @($files | Where-Object { $_.Top -eq $folder.Name })
        $photos = @($group | Where-Object { $_.Category -eq 'photo' }).Count
        $videos = @($group | Where-Object { $_.Category -eq 'video' }).Count
        $other  = $group.Count - $photos - $videos
        $bytes  = [int64] 0
        $minDate = $null; $maxDate = $null
        foreach ($f in $group) {
            $bytes += $f.Size
            if ($f.Modified) {
                if ($null -eq $minDate -or $f.Modified -lt $minDate) { $minDate = $f.Modified }
                if ($null -eq $maxDate -or $f.Modified -gt $maxDate) { $maxDate = $f.Modified }
            }
        }
        $dates = ''
        if ($minDate) {
            $dates = $minDate.ToLocalTime().ToString('yyyy-MM-dd')
            $last = $maxDate.ToLocalTime().ToString('yyyy-MM-dd')
            if ($last -ne $dates) { $dates += ' .. ' + $last }
        }
        $label = $folder.Name
        if (-not $label) { $label = '(root)' }
        & $add ('  {0,-16} {1,8} {2,8} {3,8} {4,8} {5,11}  {6}' -f $label, (Format-Count $group.Count), (Format-Count $photos), (Format-Count $videos), (Format-Count $other), (Format-Bytes $bytes), $dates)
        $grand.Files += $group.Count; $grand.Photos += $photos; $grand.Videos += $videos; $grand.Other += $other; $grand.Bytes += $bytes
    }
    & $add ('  ' + ('-' * ($header.Length - 2)))
    & $add ('  {0,-16} {1,8} {2,8} {3,8} {4,8} {5,11}' -f 'TOTAL', (Format-Count $grand.Files), (Format-Count $grand.Photos), (Format-Count $grand.Videos), (Format-Count $grand.Other), (Format-Bytes $grand.Bytes))

    & $add ''
    & $add '  By file type:'
    $byType = $files | Group-Object Extension | Sort-Object { -($_.Group | Measure-Object -Property Size -Sum).Sum }
    $wantedFiles = 0; $wantedBytes = [int64] 0
    foreach ($t in $byType) {
        $bytes = ($t.Group | Measure-Object -Property Size -Sum).Sum
        $ext = $t.Name
        if (-not $ext) { $ext = '(none)' }
        $sample = $t.Group[0]
        $flag = 'copy'
        if (-not (Test-Wanted $sample $WantedSet)) { $flag = 'skip (not in -Extensions)' }
        if ($sample.Category -eq 'sidecar') { $flag += '  edit data only, see README' }
        if (Test-Wanted $sample $WantedSet) { $wantedFiles += $t.Count; $wantedBytes += $bytes }
        & $add ('    {0,-8} {1,8} files  {2,11}   {3}' -f $ext.ToUpperInvariant(), (Format-Count $t.Count), (Format-Bytes $bytes), $flag)
    }
    & $add ''
    & $add ('  Matching the file-type filter: {0} files, {1}' -f (Format-Count $wantedFiles), (Format-Bytes $wantedBytes))

    if ($Scan.Empty.Count -gt 0 -and $script:SourceIsDevice) {
        & $add ''
        & $add ("  Note: {0} folder(s) listed no files even on a second read: {1}" -f $Scan.Empty.Count, ($Scan.Empty -join ', '))
        & $add '        Run the scan again later. If they stay empty, those photos live in iCloud and not on the'
        & $add '        phone (Settings > Photos > Download and Keep Originals brings them back).'
    }
    elseif ($Scan.Empty.Count -gt 0) {
        & $add ''
        & $add ("  Note: {0} empty folder(s): {1}" -f $Scan.Empty.Count, ($Scan.Empty -join ', '))
    }
    if ($Scan.Unreadable.Count -gt 0) {
        & $add ''
        & $add ("  Warning: {0} folder(s) could not be read: {1}" -f $Scan.Unreadable.Count, ($Scan.Unreadable -join ', '))
    }
    & $add ''
    return , $lines
}

function Save-ScanReport {
    param($Lines, [string] $Directory)
    try {
        New-Item -ItemType Directory -Force -Path $Directory | Out-Null
        $path = Join-Path $Directory ('scan-{0}.txt' -f $script:Stamp)
        [System.IO.File]::WriteAllLines($path, [string[]] $Lines, (New-Object System.Text.UTF8Encoding($false)))
        Write-Line "  Report saved to $path"
    }
    catch { Write-Line "  (could not save the report: $(Get-ErrorText $_))" Yellow }
}

# ---------------------------------------------------------------------------
# step 2: destination and plan
# ---------------------------------------------------------------------------

function Get-FreeBytes {
    param([string] $Path)
    if ($script:NativeReady) {
        try { return [IPhoneTransfer.Native]::GetFreeBytes($Path) } catch { }
    }
    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        return (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace
    }
    catch { return -1 }
}

function Initialize-Destination {
    param([string] $Path)
    $full = (New-Item -ItemType Directory -Force -Path $Path).FullName
    $probe = Join-Path $full ('.write-test-{0}' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($probe, 'ok')
        [System.IO.File]::Delete($probe)
    }
    catch { throw "Cannot write to $full ($($_.Exception.Message))" }
    return $full
}

function Get-DirectoryIndex {
    # name (lower case) -> size, for every file already in a destination folder
    param([string] $Directory, $Cache)
    $key = $Directory.ToLowerInvariant()
    if ($Cache.ContainsKey($key)) { return $Cache[$key] }
    $index = @{}
    if (Test-Path -LiteralPath $Directory -PathType Container) {
        foreach ($file in (New-Object System.IO.DirectoryInfo($Directory)).GetFiles()) {
            $index[$file.Name.ToLowerInvariant()] = $file.Length
        }
    }
    $Cache[$key] = $index
    return $index
}

function Resolve-Action {
    # Exists   - same file is already there (same name or a name_N sibling with the same size)
    # Copy     - nothing in the way
    # KeepBoth - same name, different size: save as name_1.ext
    # Replace  - same name, different size, -Overwrite given
    param($Index, [string] $Name, [int64] $Size)

    $lower = $Name.ToLowerInvariant()
    $base = [System.IO.Path]::GetFileNameWithoutExtension($lower)
    $extension = [System.IO.Path]::GetExtension($lower)
    $present = $Index.ContainsKey($lower)

    if ($present -and ($Size -le 0 -or $Index[$lower] -eq $Size)) { return 'Exists' }

    if ($Size -gt 0) {
        $n = 1
        while ($true) {
            $candidate = '{0}_{1}{2}' -f $base, $n, $extension
            if (-not $Index.ContainsKey($candidate)) { break }
            if ($Index[$candidate] -eq $Size) { return 'Exists' }
            $n++
        }
    }

    if (-not $present) { return 'Copy' }
    if ($Overwrite) { return 'Replace' }
    return 'KeepBoth'
}

function Get-FreeName {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $directory = Split-Path -Path $Path -Parent
    $base      = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $extension = [System.IO.Path]::GetExtension($Path)
    $n = 1
    while ($true) {
        $candidate = Join-Path $directory ('{0}_{1}{2}' -f $base, $n, $extension)
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $n++
    }
}

function Get-SafeName {
    param([string] $Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $chars = $Name.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '_' } else { $_ } }
    $safe = (-join $chars).TrimEnd('.', ' ')
    if (-not $safe) { $safe = 'unnamed' }
    return $safe
}

function Build-Plan {
    param($Scan, $WantedSet, [string] $DestinationPath)

    $jobs = New-Object System.Collections.ArrayList
    $cache = @{}
    $t = $script:Totals
    $toCopyBytes = [int64] 0

    $ordered = $Scan.Files | Sort-Object Top, Relative, Name
    foreach ($entry in $ordered) {
        if (-not (Test-Wanted $entry $WantedSet)) { $t.Unwanted++; $t.UnwantedBytes += $entry.Size; continue }

        $targetDirectory = $DestinationPath
        if (-not $Flat -and $entry.Relative) { $targetDirectory = Join-Path $DestinationPath $entry.Relative }
        $safeName = Get-SafeName $entry.Name
        $index = Get-DirectoryIndex -Directory $targetDirectory -Cache $cache
        $action = Resolve-Action -Index $index -Name $safeName -Size $entry.Size

        if ($action -eq 'Exists') { $t.Exists++; $t.ExistsBytes += $entry.Size; continue }

        [void] $jobs.Add([pscustomobject] @{
            Entry           = $entry
            TargetDirectory = $targetDirectory
            Landing         = Join-Path $targetDirectory $safeName
            Action          = $action
        })
        $toCopyBytes += $entry.Size

        # Remember what this run will put there, so a second file with the same name
        # (possible with -Flat) is planned as name_1 rather than colliding.
        $plannedName = $safeName.ToLowerInvariant()
        if ($action -eq 'KeepBoth') {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($plannedName); $extension = [System.IO.Path]::GetExtension($plannedName)
            $n = 1
            while ($index.ContainsKey(('{0}_{1}{2}' -f $base, $n, $extension))) { $n++ }
            $plannedName = '{0}_{1}{2}' -f $base, $n, $extension
        }
        $index[$plannedName] = $entry.Size
    }

    return @{ Jobs = $jobs; Bytes = $toCopyBytes }
}

# ---------------------------------------------------------------------------
# step 3: copy
# ---------------------------------------------------------------------------

$script:Prog = @{ Start = $null; TotalFiles = 0; TotalBytes = [int64] 0; DoneFiles = 0; DoneBytes = [int64] 0; CurrentBytes = [int64] 0; CurrentSize = [int64] 0; CurrentLabel = ''; Samples = (New-Object System.Collections.ArrayList); LastRender = [DateTime]::MinValue; Note = '' }

function Update-CopyProgress {
    param([int64] $CurrentBytes = -1, [switch] $Force, [switch] $Done)
    $p = $script:Prog
    if ($Done) {
        Write-Progress -Id 2 -ParentId 1 -Activity 'file' -Completed
        Write-Progress -Id 1 -Activity 'Copying' -Completed
        return
    }
    if ($CurrentBytes -ge 0) { $p.CurrentBytes = $CurrentBytes }
    $now = [DateTime]::UtcNow
    if (-not $Force -and ($now - $p.LastRender).TotalMilliseconds -lt 200) { return }
    $p.LastRender = $now

    $doneBytes = $p.DoneBytes + $p.CurrentBytes
    $elapsed = $now - $p.Start

    [void] $p.Samples.Add(@($now, $doneBytes))
    while ($p.Samples.Count -gt 2 -and ($now - $p.Samples[0][0]).TotalSeconds -gt 15) { $p.Samples.RemoveAt(0) }
    $speed = 0.0
    $first = $p.Samples[0]
    $window = ($now - $first[0]).TotalSeconds
    if ($window -ge 2) { $speed = ($doneBytes - $first[1]) / $window }
    elseif ($elapsed.TotalSeconds -gt 0) { $speed = $doneBytes / $elapsed.TotalSeconds }

    $percent = 0
    if ($p.TotalBytes -gt 0) { $percent = [int] [math]::Min(100, [math]::Floor($doneBytes * 100.0 / $p.TotalBytes)) }
    elseif ($p.TotalFiles -gt 0) { $percent = [int] [math]::Floor($p.DoneFiles * 100.0 / $p.TotalFiles) }

    $eta = -1
    $etaText = 'ETA --'
    if ($speed -gt 0 -and $p.TotalBytes -gt 0) {
        $eta = [int] [math]::Min([int]::MaxValue, [math]::Ceiling(($p.TotalBytes - $doneBytes) / $speed))
        $etaText = 'ETA ' + (Format-Duration ([TimeSpan]::FromSeconds($eta)))
    }

    $status = '{0} of {1} ({2}%)  |  {3}  |  elapsed {4}  |  {5}' -f (Format-Bytes $doneBytes), (Format-Bytes $p.TotalBytes), $percent, (Format-Rate $speed), (Format-Duration $elapsed), $etaText
    if ($p.Note) { $status = $p.Note + '  |  ' + $status }
    $activity = 'Copying file {0} of {1}' -f (Format-Count ([math]::Min($p.DoneFiles + 1, $p.TotalFiles))), (Format-Count $p.TotalFiles)
    if ($eta -ge 0) { Write-Progress -Id 1 -Activity $activity -Status $status -PercentComplete $percent -SecondsRemaining $eta }
    else            { Write-Progress -Id 1 -Activity $activity -Status $status -PercentComplete $percent }

    $filePercent = 0
    if ($p.CurrentSize -gt 0) { $filePercent = [int] [math]::Min(100, [math]::Floor($p.CurrentBytes * 100.0 / $p.CurrentSize)) }
    $fileStatus = '{0} of {1}' -f (Format-Bytes $p.CurrentBytes), (Format-Bytes $p.CurrentSize)
    if ($p.CurrentSize -le 0) { $fileStatus = Format-Bytes $p.CurrentBytes }
    Write-Progress -Id 2 -ParentId 1 -Activity $p.CurrentLabel -Status $fileStatus -PercentComplete $filePercent

    try { $Host.UI.RawUI.WindowTitle = '{0}% - {1} - {2}' -f $percent, (Format-Rate $speed), $etaText } catch { }
}

function Get-FileSha256 {
    param([string] $Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try { $hash = $sha.ComputeHash($stream) } finally { $stream.Close(); $sha.Dispose() }
    return ([System.BitConverter]::ToString($hash)).Replace('-', '')
}

function Copy-ViaStream {
    # Reads the file in chunks straight off the device into the staging file, hashing on
    # the way. Returns what arrived; the caller decides whether that is acceptable.
    param($Job, [string] $StagingPath)

    $item = $Job.Entry.Item
    if ($null -eq $script:ReadBuffer) { $script:ReadBuffer = New-Object byte[] ($BufferMB * 1MB) }
    $buffer = $script:ReadBuffer
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $expected = [int64] -1
    $fileStream = $null
    $deviceStream = $null
    $total = [int64] 0

    if ($item.IsFileSystem) {
        $fileStream = [System.IO.File]::Open($item.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $expected = $fileStream.Length
    }
    else {
        $deviceStream = [IPhoneTransfer.ItemStream]::Open($item)
        $expected = $deviceStream.Length
    }

    $out = New-Object System.IO.FileStream($StagingPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1MB)
    try {
        while ($true) {
            if ($fileStream) { $n = $fileStream.Read($buffer, 0, $buffer.Length) }
            else             { $n = $deviceStream.Read($buffer, $buffer.Length) }
            if ($n -le 0) { break }
            $out.Write($buffer, 0, $n)
            [void] $sha.TransformBlock($buffer, 0, $n, $null, 0)
            $total += $n
            Update-CopyProgress -CurrentBytes $total
        }
        $out.Flush($true)
    }
    finally {
        $out.Close()
        if ($fileStream) { $fileStream.Close() }
        if ($deviceStream) { $deviceStream.Dispose() }
    }
    [void] $sha.TransformFinalBlock($buffer, 0, 0)
    $hash = ([System.BitConverter]::ToString($sha.Hash)).Replace('-', '')
    $sha.Dispose()
    return @{ Bytes = $total; Sha256 = $hash; Expected = $expected; Verified = $false }
}

function Copy-ViaShell {
    # The Explorer copy operation. It always writes under the file's own name and reports
    # nothing back, so it gets a private folder per attempt and we watch for the file.
    param($Job, [string] $StagingPath)

    $private = $StagingPath + '.d'
    New-Item -ItemType Directory -Force -Path $private | Out-Null
    $target = $script:Shell.NameSpace($private)
    if ($null -eq $target) { throw "cannot open staging folder $private" }

    $arrival = Join-Path $private $Job.Entry.Name
    $size = $Job.Entry.Size
    $timeoutSeconds = [math]::Max(300, [int] ($size / 256KB))   # generous: a stalled copy, not a slow one

    $target.CopyHere($Job.Entry.Item, $COPY_FLAGS)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $arrived = $false
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSeconds) {
        if (Test-Path -LiteralPath $arrival) {
            try {
                $length = (Get-Item -LiteralPath $arrival -Force).Length
                Update-CopyProgress -CurrentBytes $length
                $probe = [System.IO.File]::Open($arrival, 'Open', 'Write', 'None')
                $probe.Close()
                $arrived = $true
                break
            }
            catch { }   # still being written
        }
        else { Update-CopyProgress }
        Start-Sleep -Milliseconds 100
    }
    if (-not $arrived) {
        try { Remove-Item -LiteralPath $private -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        throw "the file never arrived (waited $([int] $sw.Elapsed.TotalSeconds) s)"
    }

    Move-Item -LiteralPath $arrival -Destination $StagingPath -Force
    Remove-Item -LiteralPath $private -Recurse -Force -ErrorAction SilentlyContinue
    $bytes = (Get-Item -LiteralPath $StagingPath).Length
    Update-CopyProgress -CurrentBytes $bytes
    $hash = ''
    if (-not $NoVerify) { $hash = Get-FileSha256 $StagingPath }
    return @{ Bytes = $bytes; Sha256 = $hash; Expected = -1; Verified = $true }
}

function Test-Transfer {
    # Throws when what arrived cannot be trusted; the caller then retries.
    param($Job, $Result, [string] $StagingPath)

    $expected = $Result.Expected
    if ($expected -le 0) { $expected = $Job.Entry.Size }

    if ($Result.Bytes -le 0) { throw 'received 0 bytes' }
    if ($expected -gt 0 -and $Result.Bytes -ne $expected) {
        throw ('size mismatch: received {0} bytes, expected {1}' -f $Result.Bytes, $expected)
    }
    $onDisk = (Get-Item -LiteralPath $StagingPath -Force).Length
    if ($onDisk -ne $Result.Bytes) { throw ('staging file holds {0} bytes, expected {1}' -f $onDisk, $Result.Bytes) }

    if (-not $NoVerify -and -not $Result.Verified) {
        $again = Get-FileSha256 $StagingPath
        if ($again -ne $Result.Sha256) { throw 'verification failed: the file read back from disk differs from what was received' }
    }

    if ($Result.Expected -gt 0 -and $Job.Entry.Size -gt 0 -and $Result.Expected -ne $Job.Entry.Size) {
        return ('size differs from the scan ({0} then, {1} now) - the phone may have converted it' -f (Format-Bytes $Job.Entry.Size), (Format-Bytes $Result.Expected))
    }
    return ''
}

function Set-FileTimes {
    param([string] $Path, $Entry)
    try {
        if ($Entry.Modified) { [System.IO.File]::SetLastWriteTimeUtc($Path, $Entry.Modified) }
        if ($Entry.Created)  { [System.IO.File]::SetCreationTimeUtc($Path, $Entry.Created) }
        elseif ($Entry.Modified) { [System.IO.File]::SetCreationTimeUtc($Path, $Entry.Modified) }
    }
    catch { }
}

function Move-ToFinal {
    # Moves the verified staging file into place. Same volume, so this is a rename - the
    # final path never holds a half-written file.
    param($Job, [string] $StagingPath)

    New-Item -ItemType Directory -Force -Path $Job.TargetDirectory | Out-Null
    $final = $Job.Landing
    $status = 'copied'
    switch ($Job.Action) {
        'KeepBoth' { $final = Get-FreeName $Job.Landing; $status = 'renamed' }
        'Replace'  { if (Test-Path -LiteralPath $final) { $status = 'replaced' } }
        default    { if (Test-Path -LiteralPath $final) { $final = Get-FreeName $Job.Landing; $status = 'renamed' } }
    }

    if ($status -eq 'replaced') {
        try { [System.IO.File]::Replace($StagingPath, $final, $null, $true) }
        catch { [System.IO.File]::Copy($StagingPath, $final, $true); [System.IO.File]::Delete($StagingPath) }
    }
    else {
        try { [System.IO.File]::Move($StagingPath, $final) }
        catch {
            if (Test-Path -LiteralPath $final) { throw }
            [System.IO.File]::Copy($StagingPath, $final, $false); [System.IO.File]::Delete($StagingPath)
        }
    }
    return @{ Path = $final; Status = $status }
}

function Remove-Partial {
    param([string] $Path)
    foreach ($p in @($Path, ($Path + '.d'))) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop } catch { }
        }
    }
}

function Wait-ForSource {
    # The phone vanished (cable, lock screen, a hiccup). Poll until it is back or we give up.
    $deadline = (Get-Date).AddMinutes($ReconnectWaitMinutes)
    Write-Line ''
    Write-Line ("  Device not reachable. Waiting up to {0} minute(s) for it to come back - check the cable, unlock the phone..." -f $ReconnectWaitMinutes) Yellow
    $script:Prog.Note = 'waiting for device'
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if ($script:CopyStarted) { Update-CopyProgress -Force }
        if (Test-SourceAvailable) {
            Write-Line '  Device is back - continuing.' Green
            $script:Prog.Note = ''
            return $true
        }
    }
    $script:Prog.Note = ''
    return $false
}

function Invoke-CopyPlan {
    param($Plan, [string] $StagingDirectory)

    $jobs = $Plan.Jobs
    $t = $script:Totals
    $p = $script:Prog
    $p.Start = [DateTime]::UtcNow; $p.TotalFiles = $jobs.Count; $p.TotalBytes = $Plan.Bytes
    $t.CopyStart = Get-Date
    $script:CopyStarted = $true
    New-Item -ItemType Directory -Force -Path $StagingDirectory | Out-Null

    $width = (Format-Count $jobs.Count).Length
    $currentTop = $null
    $index = 0

    foreach ($job in $jobs) {
        $index++
        $entry = $job.Entry

        if ($entry.Top -ne $currentTop) {
            $currentTop = $entry.Top
            $label = $currentTop
            if (-not $label) { $label = '(root)' }
            Write-Line ''
            Write-Line "--- $label ---"
        }

        $prefix = '[{0}/{1}]' -f (Format-Count $index).PadLeft($width), (Format-Count $jobs.Count)
        $display = $entry.Name
        if ($entry.Relative -and $entry.Relative -ne $entry.Top) { $display = Join-Path ($entry.Relative.Substring([math]::Min($entry.Relative.Length, $entry.Top.Length)).TrimStart('\')) $entry.Name }
        $sizeText = (Format-Bytes $entry.Size).PadLeft(10)
        $p.CurrentLabel = $entry.Name; $p.CurrentSize = $entry.Size; $p.CurrentBytes = 0
        Update-CopyProgress -Force

        $attempt = 0
        $finished = $false
        $lastError = ''
        $useShell = ($script:EngineInUse -eq 'Shell')

        while (-not $finished) {
            $attempt++
            $staging = Join-Path $StagingDirectory ('{0}.{1}.part' -f (Get-SafeName $entry.Name), [guid]::NewGuid().ToString('N').Substring(0, 8))
            $script:CurrentStaging = $staging
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                if ($useShell) { $result = Copy-ViaShell -Job $job -StagingPath $staging }
                else           { $result = Copy-ViaStream -Job $job -StagingPath $staging }
                $note = Test-Transfer -Job $job -Result $result -StagingPath $staging
                Set-FileTimes -Path $staging -Entry $entry
                $moved = Move-ToFinal -Job $job -StagingPath $staging
                $script:CurrentStaging = ''
                $sw.Stop()

                $t.Copied++; $t.CopiedBytes += $result.Bytes
                if ($moved.Status -eq 'renamed') { $t.Renamed++ }
                if ($moved.Status -eq 'replaced') { $t.Replaced++ }
                $p.DoneFiles++; $p.DoneBytes += $result.Bytes; $p.CurrentBytes = 0
                Write-ManifestRow -Status $moved.Status -Job $job -FinalPath $moved.Path -Sha256 $result.Sha256 -Seconds $sw.Elapsed.TotalSeconds -Attempts $attempt -ErrorText ''

                $extra = ''
                if ($moved.Status -eq 'renamed')  { $extra = '  saved as ' + (Split-Path -Leaf $moved.Path) }
                if ($moved.Status -eq 'replaced') { $extra = '  replaced the old file' }
                if ($attempt -gt 1) { $extra += "  ($attempt attempts)" }
                if ($note) { $extra += "  $note" }
                $rate = ''
                if ($sw.Elapsed.TotalSeconds -ge 1 -and $result.Bytes -gt 1MB) { $rate = '  ' + (Format-Rate ($result.Bytes / $sw.Elapsed.TotalSeconds)) }
                Write-Line ('{0} {1,-34} {2}  ok  {3,6}{4}{5}' -f $prefix, $display, $sizeText, (Format-Duration $sw.Elapsed), $rate, $extra)
                $finished = $true
            }
            catch {
                $sw.Stop()
                Remove-Partial $staging
                $script:CurrentStaging = ''
                $lastError = Get-ErrorText $_
                $p.CurrentBytes = 0

                if (Test-DiskFull $_) {
                    Write-Line ('{0} {1,-34} {2}  FAILED  {3}' -f $prefix, $display, $sizeText, $lastError) Red
                    Write-Line ''
                    Write-Line '  The destination drive is full. Stopping here - free some space and run the same command again.' Red
                    $t.Failed++; [void] $t.FailedList.Add(@{ Job = $job; Error = $lastError })
                    Write-ManifestRow -Status 'failed' -Job $job -FinalPath $job.Landing -Sha256 '' -Seconds $sw.Elapsed.TotalSeconds -Attempts $attempt -ErrorText $lastError
                    $t.Pending = $jobs.Count - $index
                    $t.StopReason = 'destination full'
                    $t.CopyEnd = Get-Date
                    Update-CopyProgress -Done
                    return
                }

                if ($attempt -gt $Retries) {
                    Write-Line ('{0} {1,-34} {2}  FAILED after {3} attempt(s): {4}' -f $prefix, $display, $sizeText, $attempt, $lastError) Red
                    $t.Failed++; [void] $t.FailedList.Add(@{ Job = $job; Error = $lastError })
                    Write-ManifestRow -Status 'failed' -Job $job -FinalPath $job.Landing -Sha256 '' -Seconds $sw.Elapsed.TotalSeconds -Attempts $attempt -ErrorText $lastError
                    break
                }

                Write-Line ('{0} {1,-34} {2}  retry {3}/{4} after: {5}' -f $prefix, $display, $sizeText, $attempt, $Retries, $lastError) Yellow

                if ($script:SourceIsDevice -and -not (Test-SourceAvailable)) {
                    if (-not (Wait-ForSource)) {
                        Write-Line '  The device did not come back. Stopping here - plug it in and run the same command again.' Red
                        $t.Failed++; [void] $t.FailedList.Add(@{ Job = $job; Error = 'device disconnected' })
                        Write-ManifestRow -Status 'failed' -Job $job -FinalPath $job.Landing -Sha256 '' -Seconds $sw.Elapsed.TotalSeconds -Attempts $attempt -ErrorText 'device disconnected'
                        $t.Pending = $jobs.Count - $index
                        $t.StopReason = 'device disconnected'
                        $t.CopyEnd = Get-Date
                        Update-CopyProgress -Done
                        return
                    }
                }
                else {
                    Start-Sleep -Seconds ([math]::Min(30, [math]::Pow(2, $attempt)))
                }

                # A fresh handle on the file: the old one may be stale after a hiccup.
                if ($script:SourceIsDevice) {
                    try { $entry.Item = Get-SourceItem $job } catch { Write-Line "    (could not re-open it on the device yet: $(Get-ErrorText $_))" Yellow }
                }

                # Last attempt in Auto mode: let Explorer try, in case the stream handler is the problem.
                # (Only for a phone: on a normal folder a read error is final, and Explorer's copy
                # would just fail silently and leave us waiting for a file that never comes.)
                if ($Engine -eq 'Auto' -and $script:SourceIsDevice -and $script:NativeReady -and $attempt -ge $Retries -and -not $useShell) {
                    $useShell = $true
                    Write-Line '    (switching to the Explorer copy engine for this file)' Yellow
                }
            }
        }
    }

    $t.CopyEnd = Get-Date
    Update-CopyProgress -Done
}

# ---------------------------------------------------------------------------
# step 4: summary
# ---------------------------------------------------------------------------

function Write-Summary {
    if ($script:SummaryPrinted) { return }
    $script:SummaryPrinted = $true
    $t = $script:Totals
    $end = $t.CopyEnd
    if (-not $end) { $end = Get-Date }
    $elapsed = [TimeSpan]::Zero
    if ($t.CopyStart) { $elapsed = $end - $t.CopyStart }

    Write-Line ''
    if ($t.StopReason) { Write-Line ("Stopped: {0}" -f $t.StopReason) Red }
    Write-Line ('Finished in {0}' -f (Format-Duration $elapsed))
    $rate = ''
    if ($elapsed.TotalSeconds -gt 0 -and $t.CopiedBytes -gt 0) { $rate = '   avg ' + (Format-Rate ($t.CopiedBytes / $elapsed.TotalSeconds)) }
    Write-Line ('  Copied         {0,8} files  {1,10}{2}' -f (Format-Count $t.Copied), (Format-Bytes $t.CopiedBytes), $rate)
    if ($t.Renamed -gt 0)  { Write-Line ('    saved as name_N {0,5} files  (same name, different file already there)' -f (Format-Count $t.Renamed)) }
    if ($t.Replaced -gt 0) { Write-Line ('    replaced      {0,7} files' -f (Format-Count $t.Replaced)) }
    Write-Line ('  Already there  {0,8} files  {1,10}' -f (Format-Count $t.Exists), (Format-Bytes $t.ExistsBytes))
    if ($t.Unwanted -gt 0) { Write-Line ('  Not selected   {0,8} files  {1,10}  (file types outside -Extensions)' -f (Format-Count $t.Unwanted), (Format-Bytes $t.UnwantedBytes)) }
    $color = ''
    if ($t.Failed -gt 0) { $color = 'Red' }
    Write-Line ('  Failed         {0,8} files' -f (Format-Count $t.Failed)) $color
    if ($t.Pending -gt 0) { Write-Line ('  Not attempted  {0,8} files  (run the same command again to continue)' -f (Format-Count $t.Pending)) Yellow }

    if ($t.FailedList.Count -gt 0) {
        Write-Line ''
        Write-Line 'Failed files:' Red
        foreach ($f in $t.FailedList) {
            $rel = $f.Job.Entry.Name
            if ($f.Job.Entry.Relative) { $rel = Join-Path $f.Job.Entry.Relative $f.Job.Entry.Name }
            Write-Line ('  {0}  -  {1}' -f $rel, $f.Error)
        }
        Write-Line ''
        Write-Line 'Run the same command again to retry them - everything already copied is skipped.'
    }
    Write-Line ''
    if ($script:LogPath)      { Write-Line "Log:       $script:LogPath" }
    if ($script:ManifestPath) { Write-Line "Manifest:  $script:ManifestPath" }
}

# ---------------------------------------------------------------------------
# asking the user, when the script is started without arguments
# ---------------------------------------------------------------------------

function Read-Answer {
    param([string] $Question, [string] $Default)
    if ($Default) { $answer = Read-Host "$Question [$Default]" }
    else          { $answer = Read-Host $Question }
    # Read-Host hands back nothing at all (not even an empty line) when there is no input:
    # a scheduler, a closed pipe. Silently taking every default then could copy a whole
    # phone somewhere nobody chose, so refuse instead.
    if ($null -eq $answer) {
        throw "Cannot ask '$Question' - there is no console input. Pass -Source and -Destination (and -Yes) to run without questions."
    }
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default } else { $answer = $answer.Trim() }
    Write-LogOnly ("> {0}: {1}" -f $Question, $answer)
    return $answer
}

function Write-InColumns {
    param([string[]] $Items, [int] $PerRow = 5)
    if ($Items.Count -eq 0) { return }
    $width = 2 + ($Items | Measure-Object -Property Length -Maximum).Maximum
    for ($i = 0; $i -lt $Items.Count; $i += $PerRow) {
        $row = $Items[$i..([math]::Min($i + $PerRow - 1, $Items.Count - 1))]
        Write-Line ('  ' + (($row | ForEach-Object { $_.PadRight($width) }) -join '')).TrimEnd()
    }
}

function Select-Device {
    # Pick the phone out of This PC, or let the user choose if we cannot spot it.
    while ($true) {
        $thisPc  = $script:Shell.NameSpace($THIS_PC)
        $entries = @($thisPc.Items() | Where-Object { $_.IsFolder })
        $phones  = @($entries | Where-Object { $_.Name -match 'iPhone|iPad|Apple' })

        if ($phones.Count -eq 1) {
            Write-Line "Found device: $($phones[0].Name)"
            return $phones[0]
        }
        if ($phones.Count -gt 1) {
            Write-Line 'More than one Apple device is connected:'
            for ($i = 0; $i -lt $phones.Count; $i++) { Write-Line "  [$($i + 1)] $($phones[$i].Name)" }
            $answer = Read-Answer 'Which one' '1'
            $number = 0
            if ([int]::TryParse($answer, [ref] $number) -and $number -ge 1 -and $number -le $phones.Count) { return $phones[$number - 1] }
            continue
        }

        Write-Line 'No iPhone found. Check that it is plugged in and unlocked, and that'
        Write-Line 'you tapped "Trust This Computer" on the phone itself.'
        Write-Line ''
        Write-Line 'Everything currently under This PC:'
        for ($i = 0; $i -lt $entries.Count; $i++) { Write-Line "  [$($i + 1)] $($entries[$i].Name)" }
        Write-Line ''

        $answer = Read-Answer 'Enter a number, r to look again, or q to quit' 'r'
        if ($answer -match '^q') { Write-Line 'Nothing copied.'; exit 0 }
        if ($answer -match '^r') { Write-Line ''; continue }

        $number = 0
        if ([int]::TryParse($answer, [ref] $number) -and $number -ge 1 -and $number -le $entries.Count) { return $entries[$number - 1] }
        Write-Line "'$answer' is not one of the choices."
        Write-Line ''
    }
}

function Select-SourceInteractively {
    Write-Line ''
    Write-Line '--- Copy media off an iPhone ---'
    Write-Line ''

    $device = Select-Device
    $folder = $device.GetFolder
    $path   = $device.Name

    # A phone shows a single "Internal Storage" folder - step straight into it.
    $inside = @($folder.Items() | Where-Object { $_.IsFolder })
    if ($inside.Count -eq 1) {
        $path   = "$path\$($inside[0].Name)"
        $folder = $inside[0].GetFolder
        $inside = @($folder.Items() | Where-Object { $_.IsFolder })
    }

    $capacity = Get-ShellProperty $device 'System.Capacity'
    if ($null -eq $capacity) {
        foreach ($item in $device.GetFolder.Items()) { $c = Get-ShellProperty $item 'System.Capacity'; if ($c) { $capacity = $c; break } }
    }
    if ($capacity) { Write-Line ("Storage: {0}" -f (Format-Bytes ([double] $capacity))) }

    if ($inside.Count -gt 0) {
        $names = @($inside | ForEach-Object { $_.Name } | Sort-Object)
        Write-Line ''
        Write-Line "Folders found ($($names.Count)) - a phone names them by year and month:"
        Write-InColumns -Items $names
        Write-Line ''
        $answer = Read-Answer 'Which folders to scan (* for all, or patterns like 2026*, 202508_*)' '*'
        $script:Folders = @($answer -split '[,\s]+' | Where-Object { $_ })
        if ($script:Folders.Count -eq 0) { $script:Folders = @('*') }
    }

    $script:Source = "This PC\$path"
    Write-Line ''
}

function Confirm-Start {
    param([string] $Question)
    if ($Yes) { return $true }
    return ((Read-Answer $Question 'y') -match '^y')
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

$originalTitle = ''
try { $originalTitle = $Host.UI.RawUI.WindowTitle } catch { }
$script:SourceLabel = ''

try {
    Initialize-Native
    if ($Engine -eq 'Stream' -and -not $script:NativeReady) { throw 'The Stream engine is not available on this machine (see the note above). Use -Engine Shell.' }
    if ($Engine -ne 'Shell' -and $script:NativeReady) { $script:EngineInUse = 'Stream' }

    # When the destination is known from the start, the log can open right away.
    if ($Destination -and -not $ScanOnly) {
        $Destination = Initialize-Destination -Path $Destination
        if (-not $LogDirectory) { $LogDirectory = Join-Path $Destination '.iphone-transfer' }
        Open-Log -Directory $LogDirectory
    }
    Write-LogOnly ('Copy-IPhoneMedia started: Source="{0}" Destination="{1}" Folders={2} Extensions={3} Flat={4} Overwrite={5} DryRun={6} ScanOnly={7} Engine={8}' -f $Source, $Destination, ($Folders -join ','), ($Extensions -join ','), $Flat, $Overwrite, $DryRun, $ScanOnly, $script:EngineInUse)

    if (-not $Source) {
        $script:Interactive = $true
        Select-SourceInteractively
    }

    # "-Folders 2026*,202508_*" arrives as one string when launched with -File: split it.
    $script:Folders = @($Folders | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
    if ($Folders.Count -eq 0) { $script:Folders = @('*') }

    # -- source --------------------------------------------------------------------
    $script:SourceIsDevice = -not (Test-Path -LiteralPath $Source -PathType Container)
    if ($script:SourceIsDevice) { Write-Line "Opening device: $Source" }
    $sourceFolder = Get-SourceFolder -Path $Source
    $script:SourceLabel = $Source
    if ($script:SourceIsDevice) { $script:SourceLabel = (Split-DevicePath $Source) -join '\' }

    # -- step 1: scan --------------------------------------------------------------
    Write-Line ''
    Write-Line ("Scanning {0}  (folders: {1})" -f $script:SourceLabel, ($Folders -join ', '))
    if ($script:SourceIsDevice) { Write-Line '  Reading a folder off a phone takes about a tenth of a second per file - large months take minutes.' }
    Write-Line ''
    $scan = Invoke-Scan -RootFolder $sourceFolder

    $wantedSet = Get-WantedSet $Extensions
    $reportLines = Write-ScanReport -Scan $scan -WantedSet $wantedSet -Title $script:SourceLabel

    if ($ScanOnly) {
        $reportDirectory = $LogDirectory
        if (-not $reportDirectory -and $Destination) { $reportDirectory = Join-Path $Destination '.iphone-transfer' }
        if (-not $reportDirectory) { $reportDirectory = Join-Path $env:TEMP 'iphone-transfer' }
        Save-ScanReport -Lines $reportLines -Directory $reportDirectory
        $script:ExitCode = 0
        return
    }

    if ($scan.Files.Count -eq 0) {
        Write-Line "No files found in $script:SourceLabel"
        return
    }

    # -- step 2: destination ---------------------------------------------------------
    if (-not $Destination) {
        $suggested = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'iPhone'
        while ($true) {
            $answer = Read-Answer 'Copy them to' $suggested
            try { $Destination = Initialize-Destination -Path $answer; break }
            catch { Write-Line "  $(Get-ErrorText $_)" Red }
        }
        $answer = Read-Answer 'File types to copy (* for everything)' ($Extensions -join ',')
        $script:Extensions = @($answer -split '[,\s]+' | Where-Object { $_ })
        $wantedSet = Get-WantedSet $Extensions
        if (-not $LogDirectory) { $LogDirectory = Join-Path $Destination '.iphone-transfer' }
        Open-Log -Directory $LogDirectory
    }
    if (-not $LogDirectory) { $LogDirectory = Join-Path $Destination '.iphone-transfer' }
    if (-not $script:LogWriter) { Open-Log -Directory $LogDirectory }
    try { (Get-Item -LiteralPath (Join-Path $Destination '.iphone-transfer') -Force -ErrorAction Stop).Attributes = 'Directory, Hidden' } catch { }
    Save-ScanReport -Lines $reportLines -Directory $LogDirectory

    $stagingDirectory = Join-Path (Join-Path $Destination '.iphone-transfer') 'staging'
    if (Test-Path -LiteralPath $stagingDirectory) {
        $leftovers = @(Get-ChildItem -LiteralPath $stagingDirectory -Force -ErrorAction SilentlyContinue)
        if ($leftovers.Count -gt 0) {
            Write-Line ("  Removing {0} unfinished file(s) left in staging by an earlier run." -f $leftovers.Count)
            Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # -- step 3: plan --------------------------------------------------------------
    Write-Line ''
    Write-Line "Comparing with $Destination ..."
    $plan = Build-Plan -Scan $scan -WantedSet $wantedSet -DestinationPath $Destination
    $t = $script:Totals
    $structure = 'keeping the folder structure'
    if ($Flat) { $structure = 'all into one folder' }
    Write-Line ('  To copy        {0,8} files  {1,10}   ({2})' -f (Format-Count $plan.Jobs.Count), (Format-Bytes $plan.Bytes), $structure)
    Write-Line ('  Already there  {0,8} files  {1,10}' -f (Format-Count $t.Exists), (Format-Bytes $t.ExistsBytes))
    if ($t.Unwanted -gt 0) { Write-Line ('  Not selected   {0,8} files  {1,10}   (file types outside the filter)' -f (Format-Count $t.Unwanted), (Format-Bytes $t.UnwantedBytes)) }
    $keepBoth = @($plan.Jobs | Where-Object { $_.Action -eq 'KeepBoth' }).Count
    $replace  = @($plan.Jobs | Where-Object { $_.Action -eq 'Replace' }).Count
    if ($keepBoth -gt 0) { Write-Line ('  {0} file(s) have a same-named but different file at the destination - they will be saved as name_1.ext (use -Overwrite to replace instead)' -f (Format-Count $keepBoth)) Yellow }
    if ($replace -gt 0)  { Write-Line ('  {0} file(s) will REPLACE a same-named but different file at the destination (-Overwrite)' -f (Format-Count $replace)) Yellow }

    $free = Get-FreeBytes $Destination
    if ($free -ge 0) {
        Write-Line ('  Free space     {0,19}' -f (Format-Bytes $free))
        if ($plan.Jobs.Count -gt 0 -and $free -lt ($plan.Bytes * 1.02 + 64MB)) {
            Write-Line ('  NOT ENOUGH SPACE: {0} needed, {1} free.' -f (Format-Bytes $plan.Bytes), (Format-Bytes $free)) Red
            if (-not $DryRun) {
                if ($Yes -or (-not $script:Interactive -and -not $Destination)) { throw 'Not enough free space at the destination.' }
                if (-not $script:Interactive) { throw 'Not enough free space at the destination. Free some space, pick another destination, or narrow -Folders / -Extensions.' }
                if (-not (Confirm-Start 'Copy anyway until the drive is full? (y/n)')) { Write-Line 'Nothing copied.'; return }
            }
        }
    }

    if ($plan.Jobs.Count -eq 0) {
        Write-Line ''
        Write-Line 'Nothing to copy - everything selected is already at the destination.' Green
        $script:Totals.CopyStart = Get-Date
        return
    }

    if ($DryRun) {
        Write-Line ''
        Write-Line 'Dry run - these would be copied:'
        $i = 0
        foreach ($job in $plan.Jobs) {
            $i++
            $what = 'copy'
            if ($job.Action -eq 'KeepBoth') { $what = 'keep both' }
            if ($job.Action -eq 'Replace')  { $what = 'replace' }
            $rel = $job.Entry.Name
            if ($job.Entry.Relative) { $rel = Join-Path $job.Entry.Relative $job.Entry.Name }
            Write-Line ('  [{0}/{1}] {2,-10} {3,-40} {4,10}  -> {5}' -f $i, $plan.Jobs.Count, $what, $rel, (Format-Bytes $job.Entry.Size), $job.Landing)
        }
        Write-Line ''
        Write-Line ('Dry run: {0} file(s) ({1}) would be copied, {2} already there. Nothing was written.' -f (Format-Count $plan.Jobs.Count), (Format-Bytes $plan.Bytes), (Format-Count $t.Exists))
        return
    }

    if ($script:Interactive) {
        Write-Line ''
        Write-Line "  from   $script:SourceLabel   (folders: $($Folders -join ', '))"
        Write-Line "  to     $Destination"
        Write-Line "  types  $($Extensions -join ', ')"
        Write-Line ''
        if (-not (Confirm-Start 'Start copying? (y/n)')) { Write-Line 'Nothing copied.'; return }
    }

    # -- step 4: copy --------------------------------------------------------------
    Open-Manifest -Directory $LogDirectory
    Write-Line ''
    Write-Line ('Copying {0} files ({1}) to {2} using the {3} engine{4}' -f (Format-Count $plan.Jobs.Count), (Format-Bytes $plan.Bytes), $Destination, $script:EngineInUse, $(if ($NoVerify) { ', without read-back verification' } else { '' }))
    Invoke-CopyPlan -Plan $plan -StagingDirectory $stagingDirectory

    try { if ((Test-Path -LiteralPath $stagingDirectory) -and @(Get-ChildItem -LiteralPath $stagingDirectory -Force).Count -eq 0) { Remove-Item -LiteralPath $stagingDirectory -Force } } catch { }

    Write-Summary
    if ($script:Totals.Failed -gt 0 -or $script:Totals.Pending -gt 0) { $script:ExitCode = 2 } else { $script:ExitCode = 0 }
}
catch {
    Write-Line ''
    Write-Line ("ERROR: " + $_.Exception.Message) Red
    Write-LogOnly ($_.ScriptStackTrace)
    if ($script:CopyStarted) { Write-Summary; $script:ExitCode = 2 } else { $script:ExitCode = 1 }
}
finally {
    # Runs on Ctrl+C as well: never leave a half-written file behind, and say where things stand.
    if ($script:CurrentStaging) { Remove-Partial $script:CurrentStaging; $script:CurrentStaging = '' }
    if ($script:CopyStarted -and -not $script:SummaryPrinted) {
        $script:Totals.StopReason = 'interrupted'
        $script:Totals.CopyEnd = Get-Date
        $script:Totals.Pending = $script:Prog.TotalFiles - $script:Prog.DoneFiles - $script:Totals.Failed
        try { Write-Summary } catch { }
        $script:ExitCode = 3
    }
    try { Write-Progress -Id 2 -ParentId 1 -Activity 'file' -Completed; Write-Progress -Id 1 -Activity 'Copying' -Completed } catch { }
    try { $Host.UI.RawUI.WindowTitle = $originalTitle } catch { }
    Close-Writers
}

exit $script:ExitCode
