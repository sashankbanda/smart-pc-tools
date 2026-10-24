# Engine for the iPhone Transfer app.
#
# Runs on its own background thread (a separate runspace), so the window stays responsive
# while the phone is read. It talks to the window only through $sync:
#   $sync.Commands  queue of work the window asks for (one at a time, in order)
#   $sync.Events    queue of things that happened, for the window to show
#   $sync.Progress  live numbers (bytes done, speed, current file) the window polls
#   $sync.Cancel / $sync.Pause / $sync.Quit   flags set by the window
#
# The rules that protect your files:
#   - a copy is written to a staging file first, checked (size, SHA-256 read back), given
#     the phone's dates, and only then moved into place - a file at its final path is
#     always complete
#   - nothing at the destination is ever overwritten; a same-named different file is kept
#     alongside as name_1.ext
#   - the check compares every file on the phone with its copy on the PC; a folder only
#     counts as safe when every single file in it matches
#   - deleting from the phone is refused for any folder that did not pass the check, and
#     each file is re-confirmed on the PC just before it is deleted

$ErrorActionPreference = 'Stop'

$PHOTO_TYPES = @('.jpg', '.jpeg', '.heic', '.heif', '.png', '.dng', '.gif', '.tif', '.tiff', '.webp', '.bmp', '.raw')
$VIDEO_TYPES = @('.mov', '.mp4', '.m4v', '.hevc', '.avi', '.3gp', '.mkv')
$COPY_FLAGS  = 4 -bor 16 -bor 512 -bor 1024   # Explorer copy: silent, no prompts, no error dialogs
$RESERVE_BYTES = 512MB                        # never fill the PC's disk completely

$script:Invariant      = [System.Globalization.CultureInfo]::InvariantCulture
$script:Shell          = New-Object -ComObject Shell.Application
$script:Source         = $null    # @{ Kind = 'Device' | 'Folder'; Device; Storage; Path; Label }
$script:Folders        = @{}      # folder name -> @{ Files = list of entries; Error }
$script:Verified       = @{}      # folder name -> @{ Ok; Files = key -> record }
$script:Manifest       = @{}      # "folder|name" -> @{ Dest; Sha; Size }
$script:Unavailable    = @{}      # "folder|name" -> why the phone would not hand the file over
$script:BadCopies      = @{}      # "source key>pc path" pairs the check found not to match
$script:Dest           = ''
$script:Log            = $null
$script:ManifestWriter = $null
$script:Buffer         = New-Object byte[] (4MB)
$script:Samples        = New-Object System.Collections.Queue
$script:LastTick       = [DateTime]::MinValue
$script:LastDeviceSig  = ''
$P = $sync.Progress

# ---------------------------------------------------------------------------
# plumbing
# ---------------------------------------------------------------------------

function Write-Log {
    param([string] $Text)
    if (-not $script:Log) { return }
    try { $script:Log.WriteLine(('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Text)) } catch { }
}

function Send-Event {
    param([string] $Type, [hashtable] $Data = @{})
    $Data['Type'] = $Type
    $sync.Events.Enqueue($Data)
}

function Assert-NotCancelled {
    if ($sync.Cancel) { throw (New-Object System.OperationCanceledException) }
}

function Format-Bytes {
    param([double] $Bytes)
    if ($Bytes -lt 1024) { return ('{0} B' -f [int64] $Bytes) }
    $value = $Bytes
    foreach ($unit in 'KB', 'MB', 'GB', 'TB') {
        $value = $value / 1024
        if ($value -lt 1024 -or $unit -eq 'TB') { return ($value.ToString('N1', $script:Invariant) + ' ' + $unit) }
    }
}

function Get-ErrorText {
    param($ErrorRecord)
    $exception = $ErrorRecord.Exception
    while ($exception.InnerException) { $exception = $exception.InnerException }
    $text = ($exception.Message.Trim() -replace '\s+', ' ')
    if ($exception.HResult -lt 0 -and $text -notmatch '0x[0-9A-F]{8}') { $text += (' (0x{0:X8})' -f $exception.HResult) }
    return $text
}

function Test-Cancelled {
    param($ErrorRecord)
    $exception = $ErrorRecord.Exception
    while ($exception) {
        if ($exception -is [System.OperationCanceledException]) { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

function Test-DiskFull {
    param($ErrorRecord)
    $exception = $ErrorRecord.Exception
    while ($exception) {
        $code = $exception.HResult -band 0xFFFF
        if ($code -eq 0x70 -or $code -eq 0x27) { return $true }   # ERROR_DISK_FULL, ERROR_HANDLE_DISK_FULL
        if ($exception.Message -match 'not enough space') { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

function Reset-Progress {
    param([string] $Phase, [int64] $FilesTotal = 0, [int64] $BytesTotal = 0, [string] $Step = '')
    $P.Phase = $Phase; $P.Step = $Step
    $P.FilesTotal = $FilesTotal; $P.BytesTotal = $BytesTotal
    $P.FilesDone = [int64] 0; $P.BytesDone = [int64] 0
    $P.CurrentName = ''; $P.CurrentFolder = ''; $P.CurrentBytes = [int64] 0; $P.CurrentSize = [int64] 0; $P.Current = $null
    $P.Speed = 0.0; $P.Eta = -1.0; $P.Waiting = $false; $P.Paused = $false
    $P.Started = [DateTime]::UtcNow
    $script:Samples.Clear()
}

function Set-Current {
    # The window reads these from another thread; one snapshot object means it never pairs
    # one file's name with another file's size.
    param([string] $Name, [string] $Folder, [int64] $Size)
    $P.CurrentBytes = [int64] 0
    $P.CurrentName = $Name; $P.CurrentFolder = $Folder; $P.CurrentSize = $Size
    $P.Current = @{ Name = $Name; Folder = $Folder; Size = $Size }
}

function Update-Progress {
    param([int64] $Current = -1, [switch] $Force)
    if ($Current -ge 0) { $P.CurrentBytes = $Current }
    $now = [DateTime]::UtcNow
    if (-not $Force -and ($now - $script:LastTick).TotalMilliseconds -lt 250) { return }
    $script:LastTick = $now
    $done = [int64] $P.BytesDone + [int64] $P.CurrentBytes
    $script:Samples.Enqueue(@($now, $done))
    while ($script:Samples.Count -gt 2 -and ($now - $script:Samples.Peek()[0]).TotalSeconds -gt 12) { [void] $script:Samples.Dequeue() }
    $first = $script:Samples.Peek()
    $span = ($now - $first[0]).TotalSeconds
    if ($span -ge 1.5) { $P.Speed = [double] ($done - $first[1]) / $span }
    if ($P.Speed -gt 0 -and $P.BytesTotal -gt 0) { $P.Eta = [math]::Max([double] 0, [double] ($P.BytesTotal - $done) / [double] $P.Speed) }
    else { $P.Eta = -1.0 }
}

# ---------------------------------------------------------------------------
# reading the shell: names, sizes, dates
# ---------------------------------------------------------------------------

function Get-ShellProperty {
    # On a phone, ExtendedProperty is the only way to get real values: the plain Size and
    # ModifyDate on the item come back empty.
    param($Item, [string] $Name)
    try {
        $value = $Item.ExtendedProperty($Name)
        if ($null -eq $value -or $value -is [System.DBNull]) { return $null }
        return $value
    }
    catch { return $null }
}

function Get-RealName {
    # With "Hide extensions for known file types" on, the shell says "IMG_1234" instead
    # of "IMG_1234.JPG". The file-name property is never trimmed.
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
    return [int64] 0
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
    if ($value -is [DateTime] -and $value.Year -ge 1980) { return [DateTime]::SpecifyKind($value, [DateTimeKind]::Utc) }
    return $null
}

function Get-Category {
    param([string] $Extension)
    if ($PHOTO_TYPES -contains $Extension) { return 'photo' }
    if ($VIDEO_TYPES -contains $Extension) { return 'video' }
    return 'other'
}

function Get-SafeName {
    param([string] $Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $chars = $Name.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '_' } else { $_ } }
    $safe = (-join $chars).TrimEnd('.', ' ')
    if (-not $safe) { $safe = 'unnamed' }
    return $safe
}

function New-Entry {
    param($Item, [string] $Rel)
    $name = Get-RealName $Item
    $extension = [System.IO.Path]::GetExtension($name).ToLowerInvariant()
    return @{
        Name     = $name
        Rel      = $Rel
        Ext      = $extension
        Cat      = Get-Category $extension
        Size     = Get-ItemBytes $Item
        Mod      = Get-ItemTimeUtc $Item 'System.DateModified'
        Cre      = Get-ItemTimeUtc $Item 'System.DateCreated'
        Item     = $Item
    }
}

# ---------------------------------------------------------------------------
# the device
# ---------------------------------------------------------------------------

function Get-AppleDevices {
    $list = New-Object System.Collections.ArrayList
    foreach ($item in $script:Shell.NameSpace(17).Items()) {
        if ($item.IsFolder -and -not $item.IsFileSystem -and $item.Name -match 'iPhone|iPad|iPod|Apple') { [void] $list.Add($item) }
    }
    return , $list
}

function Get-DeviceState {
    $devices = Get-AppleDevices
    if ($devices.Count -eq 0) { return @{ State = 'None' } }
    $device = $devices[0]
    $storages = @($device.GetFolder.Items() | Where-Object { $_.IsFolder })
    if ($storages.Count -eq 0) { return @{ State = 'Locked'; Device = [string] $device.Name } }
    $storage = $storages[0]
    $names = @($storage.GetFolder.Items() | Where-Object { $_.IsFolder } | ForEach-Object { [string] $_.Name } | Sort-Object)
    if ($names.Count -eq 0) { return @{ State = 'Empty'; Device = [string] $device.Name; Storage = [string] $storage.Name } }
    $capacity = [int64] 0
    $c = Get-ShellProperty $storage 'System.Capacity'
    if ($null -ne $c) { try { $capacity = [int64] $c } catch { } }
    return @{ State = 'Ready'; Device = [string] $device.Name; Storage = [string] $storage.Name; Capacity = $capacity; Folders = [string[]] $names; DeviceCount = $devices.Count }
}

function Update-DeviceWatch {
    if ($script:Source -and $script:Source.Kind -eq 'Folder') { return }
    try { $state = Get-DeviceState } catch { $state = @{ State = 'None'; Message = (Get-ErrorText $_) } }
    $signature = '{0}|{1}|{2}' -f $state.State, $state.Device, ($state.Folders -join ',')
    if ($signature -ne $script:LastDeviceSig) {
        $script:LastDeviceSig = $signature
        Write-Log "device: $($state.State) $($state.Device)"
        Send-Event 'DeviceState' $state
    }
}

function Get-StorageFolder {
    $s = $script:Source
    if ($null -eq $s) { throw 'No source chosen yet.' }
    if ($s.Kind -eq 'Folder') {
        $folder = $script:Shell.NameSpace($s.Path)
        if ($null -eq $folder) { throw (New-Object System.IO.IOException "Cannot open $($s.Path)") }
        return $folder
    }
    foreach ($device in $script:Shell.NameSpace(17).Items()) {
        if ($device.IsFolder -and $device.Name -eq $s.Device) {
            foreach ($storage in $device.GetFolder.Items()) {
                if ($storage.IsFolder -and $storage.Name -eq $s.Storage) { return $storage.GetFolder }
            }
        }
    }
    throw (New-Object System.IO.IOException 'The iPhone is not connected, or it is locked.')
}

function Test-SourceAvailable {
    try {
        $root = Get-StorageFolder
        if ($script:Source.Kind -eq 'Device') {
            # A locked phone still shows its storage but lists nothing in it.
            foreach ($i in $root.Items()) { return $true }
            return $false
        }
        return $true
    }
    catch { return $false }
}

function Wait-ForDevice {
    # The phone vanished (cable, lock screen, a hiccup). Wait until it is back or the user
    # stops - there is no time limit, the window shows what is going on.
    Write-Log 'waiting for the device to come back'
    $P.Waiting = $true
    Send-Event 'Waiting' @{ On = $true }
    try {
        while (-not $sync.Cancel) {
            Start-Sleep -Seconds 2
            if (Test-SourceAvailable) {
                Write-Log 'device is back'
                $script:Samples.Clear()
                return $true
            }
        }
        return $false
    }
    finally {
        $P.Waiting = $false
        Send-Event 'Waiting' @{ On = $false }
    }
}

function Get-TopFolderItem {
    param([string] $Name)
    $root = Get-StorageFolder
    foreach ($item in $root.Items()) {
        if ($item.IsFolder -and $item.Name -eq $Name) { return $item }
    }
    throw "The folder '$Name' is no longer there."
}

function Get-SourceFile {
    # A fresh handle for one file, after the device hiccupped or came back.
    param($Entry)
    $parts = @($Entry.Rel -split '\\' | Where-Object { $_ })
    $folder = (Get-TopFolderItem $parts[0]).GetFolder
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $next = $null
        foreach ($item in $folder.Items()) { if ($item.IsFolder -and $item.Name -eq $parts[$i]) { $next = $item; break } }
        if ($null -eq $next) { throw "The folder '$($Entry.Rel)' is no longer there." }
        $folder = $next.GetFolder
    }
    $file = $folder.ParseName($Entry.Name)
    if ($null -eq $file) { throw "'$($Entry.Name)' is no longer there." }
    return $file
}

# ---------------------------------------------------------------------------
# scanning
# ---------------------------------------------------------------------------

function Read-FolderEntries {
    param($Folder, [string] $Rel, $List)
    foreach ($item in $Folder.Items()) {
        Assert-NotCancelled
        if ($item.IsFolder) {
            Read-FolderEntries -Folder $item.GetFolder -Rel (Join-Path $Rel $item.Name) -List $List
            continue
        }
        if ($sync.DemoScanDelayMs) { Start-Sleep -Milliseconds $sync.DemoScanDelayMs }   # tutorial recording only
        $entry = New-Entry $item $Rel
        [void] $List.Add($entry)
        $P.ScanFiles = [int64] $P.ScanFiles + 1
        $P.ScanBytes = [int64] $P.ScanBytes + $entry.Size
        $P.FolderFiles = [int64] $P.FolderFiles + 1
    }
}

function Read-TopFolder {
    param([string] $Name)
    $attempt = 0
    $beforeFiles = [int64] $P.ScanFiles; $beforeBytes = [int64] $P.ScanBytes
    while ($true) {
        $attempt++
        $P.ScanFiles = $beforeFiles; $P.ScanBytes = $beforeBytes; $P.FolderFiles = [int64] 0
        $list = New-Object System.Collections.ArrayList
        try {
            $item = Get-TopFolderItem $Name
            Read-FolderEntries -Folder $item.GetFolder -Rel $Name -List $list
            # An iPhone often lists a folder as empty the first time it is asked.
            if ($list.Count -eq 0 -and $script:Source.Kind -eq 'Device' -and $attempt -eq 1) { Start-Sleep -Seconds 3; continue }
            return , $list
        }
        catch {
            if (Test-Cancelled $_) { throw }
            $text = Get-ErrorText $_
            Write-Log "reading $Name failed (attempt $attempt): $text"
            if ($attempt -ge 4) { throw "Could not read the folder $Name ($text)" }
            if ($script:Source.Kind -eq 'Device' -and -not (Test-SourceAvailable)) {
                if (-not (Wait-ForDevice)) { throw (New-Object System.OperationCanceledException) }
            }
            else { Start-Sleep -Seconds 3 }
        }
    }
}

function Get-FolderSummary {
    param([string] $Name, $Cache)
    $record = $script:Folders[$Name]
    $summary = @{ Name = $Name; Files = 0; Bytes = [int64] 0; Photos = 0; Videos = 0; Other = 0; FirstDate = ''; LastDate = ''; Types = @(); Error = '' }
    if ($null -eq $record) { return $summary }
    $summary.Error = [string] $record.Error
    $types = @{}
    $min = $null; $max = $null
    foreach ($e in $record.Files) {
        $summary.Files++
        $summary.Bytes += $e.Size
        switch ($e.Cat) { 'photo' { $summary.Photos++ } 'video' { $summary.Videos++ } default { $summary.Other++ } }
        if ($e.Mod) {
            if ($null -eq $min -or $e.Mod -lt $min) { $min = $e.Mod }
            if ($null -eq $max -or $e.Mod -gt $max) { $max = $e.Mod }
        }
        $key = $e.Ext
        if (-not $key) { $key = '(none)' }
        if (-not $types.ContainsKey($key)) { $types[$key] = @{ Ext = $key.ToUpperInvariant(); Count = 0; Bytes = [int64] 0 } }
        $types[$key].Count++
        $types[$key].Bytes += $e.Size
    }
    if ($min) { $summary.FirstDate = $min.ToLocalTime().ToString('yyyy-MM-dd'); $summary.LastDate = $max.ToLocalTime().ToString('yyyy-MM-dd') }
    $summary.Types = @($types.Values | Sort-Object { - $_.Bytes })

    if ($script:Dest) {
        if ($null -eq $Cache) { $Cache = @{} }
        $present = 0; $presentBytes = [int64] 0; $fingerprinted = 0; $elsewhere = 0
        foreach ($e in $record.Files) {
            $copy = Find-Copy -Entry $e -Cache $Cache
            if ($copy) {
                $present++; $presentBytes += $e.Size
                if ($copy.Sha) { $fingerprinted++ }
                $homeDir = (Join-Path $script:Dest $e.Rel).TrimEnd('\')
                if (-not (Split-Path -Parent $copy.Path).Equals($homeDir, [StringComparison]::OrdinalIgnoreCase)) { $elsewhere++ }
            }
        }
        $summary.ElsewhereFiles = $elsewhere
        $summary.PresentFiles = $present
        $summary.PresentBytes = $presentBytes
        $summary.Fingerprinted = $fingerprinted
        $summary.Verified = [bool] ($script:Verified.ContainsKey($Name) -and $script:Verified[$Name].Ok)
    }
    return $summary
}

function Invoke-Scan {
    param([string[]] $Names)
    $P.Phase = 'Scan'
    $P.ScanTotal = $Names.Count; $P.ScanIndex = 0; $P.ScanFiles = [int64] 0; $P.ScanBytes = [int64] 0
    $P.Started = [DateTime]::UtcNow
    $cancelled = $false
    foreach ($name in $Names) {
        Use-PendingDestination
        if ($sync.Cancel) { $cancelled = $true; break }
        $P.ScanIndex = [int] $P.ScanIndex + 1
        $P.ScanFolder = $name
        $P.FolderStarted = [DateTime]::UtcNow
        Send-Event 'FolderScanning' @{ Name = $name }
        try {
            $list = Read-TopFolder $name
            $script:Folders[$name] = @{ Files = $list; Error = '' }
            Write-Log ("scanned {0}: {1} files, {2}" -f $name, $list.Count, (Format-Bytes $P.ScanBytes))
        }
        catch {
            if (Test-Cancelled $_) { $cancelled = $true; break }
            $text = Get-ErrorText $_
            $script:Folders[$name] = @{ Files = (New-Object System.Collections.ArrayList); Error = $text }
            Write-Log "scan of $name failed: $text"
        }
        Send-Event 'FolderScanned' (Get-FolderSummary -Name $name)
    }
    Send-Event 'ScanDone' @{ Cancelled = $cancelled }
}

# ---------------------------------------------------------------------------
# the destination: what is already there
# ---------------------------------------------------------------------------

function Get-MetaDirectory { return (Join-Path $script:Dest '.iphone-transfer') }

function Import-Manifest {
    # The manifest records, for every file ever copied here, where it went and the SHA-256
    # of the bytes as they came off the phone - the "fingerprint" the check relies on.
    $script:Manifest = @{}
    if (-not $script:Dest) { return }
    $path = Join-Path (Get-MetaDirectory) 'manifest.csv'
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $previousSha = ''
        foreach ($row in (Import-Csv -LiteralPath $path)) {
            if (@('copied', 'renamed', 'replaced') -notcontains $row.status) { continue }
            $thisSha = [string] $row.sha256
            $samePrevious = ($thisSha -and $thisSha -eq $previousSha)
            $previousSha = $thisSha
            if (-not $thisSha) { continue }
            $tries = 1
            [void] [int]::TryParse([string] $row.attempts, [ref] $tries)
            if ($tries -gt 1 -or $samePrevious) { [void] $script:Manifest.Remove(([string] $row.folder + '|' + [string] $row.name).ToLowerInvariant()); continue }
            $size = [int64] 0
            [void] [int64]::TryParse([string] $row.size_bytes, [ref] $size)
            $script:Manifest[([string] $row.folder + '|' + [string] $row.name).ToLowerInvariant()] = @{ Dest = [string] $row.destination; Sha = ([string] $row.sha256).ToUpperInvariant(); Size = $size }
        }
    }
    catch { Write-Log "could not read the manifest: $(Get-ErrorText $_)" }
}

function Get-DirIndex {
    param([string] $Directory, $Cache)
    $key = $Directory.ToLowerInvariant()
    if ($Cache.ContainsKey($key)) { return $Cache[$key] }
    $index = @{}
    if ([System.IO.Directory]::Exists($Directory)) {
        foreach ($file in (New-Object System.IO.DirectoryInfo($Directory)).GetFiles()) { $index[$file.Name.ToLowerInvariant()] = $file.Length }
    }
    $Cache[$key] = $index
    return $index
}

function Get-EntryKey { param($Entry) return ($Entry.Rel + '|' + $Entry.Name).ToLowerInvariant() }

function Get-AssetKey {
    # Which photo a file belongs to. On an iPhone one photo is several files: IMG_0077.JPG,
    # its Live Photo video IMG_0077.MOV, the edit IMG_E0077.JPG / IMG_E0077.MOV and the edit
    # instructions IMG_0077.AAE / IMG_O0077.AAE. Deleting any one of them from the phone can
    # remove the whole photo, so they are kept or deleted together.
    param([string] $Rel, [string] $Name)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    if ($stem -match '^([A-Za-z]{3}_|[A-Za-z]{4})([EO])?(\d{4,5})$') { $stem = $Matches[1] + $Matches[3] }
    return ($Rel + '|' + $stem).ToLowerInvariant()
}

# A PC file the check found not to match a particular source file. Per source file, because
# the same PC file can be the right copy of another source file with the same name and size.
function Test-BadCopy { param([string] $Key, [string] $Path) return $script:BadCopies.ContainsKey($Key + '>' + $Path.ToLowerInvariant()) }
function Set-BadCopy  { param([string] $Key, [string] $Path) $script:BadCopies[$Key + '>' + $Path.ToLowerInvariant()] = $true }

function Update-DestIndex {
    # Every file anywhere in the destination, by name. The iPhone regroups its month folders
    # over time (a photo once in 202605_b can later be listed under 202605_a), so a copy made
    # earlier may sit in a differently named folder. Folders starting with "." (this app's own
    # .iphone-transfer, other apps' trash such as .dtrash) and "$" (system) are left out.
    $script:DestIndex = @{}
    if (-not $script:Dest -or -not [System.IO.Directory]::Exists($script:Dest)) { return }
    $count = 0
    $stack = New-Object System.Collections.Stack
    $stack.Push($script:Dest)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try { $info = New-Object System.IO.DirectoryInfo($dir); $subs = $info.GetDirectories(); $files = $info.GetFiles() }
        catch { continue }
        foreach ($s in $subs) {
            if ($s.Name.StartsWith('.') -or $s.Name.StartsWith('$') -or $s.Name -eq 'System Volume Information') { continue }
            if ($s.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $stack.Push($s.FullName)
        }
        foreach ($f in $files) { Add-DestIndex -Path $f.FullName -Size $f.Length -Mod $f.LastWriteTimeUtc; $count++ }
    }
    Write-Log "destination holds $count files"
}

function Add-DestIndex {
    param([string] $Path, [int64] $Size, $Mod)
    if ($null -eq $script:DestIndex) { $script:DestIndex = @{} }
    $key = [System.IO.Path]::GetFileName($Path).ToLowerInvariant()
    $list = $script:DestIndex[$key]
    if ($null -eq $list) { $list = New-Object System.Collections.ArrayList; $script:DestIndex[$key] = $list }
    [void] $list.Add(@{ Path = $Path; Size = $Size; Mod = $Mod })
}

function Find-Copies {
    # Every file on the PC that may be this source file - same name and same size - best first:
    #   1. where the manifest says it was copied to
    #   2. the same folder name as on the source (also name_1, name_2 ... kept alongside)
    #   3. anywhere else in the destination, same date first
    # The SHA-256 from the manifest (when there is one for this file) travels along, so the
    # check can prove the content; without it the check reads the source file again.
    param($Entry, $Cache)
    $key = Get-EntryKey $Entry
    $found = New-Object System.Collections.ArrayList
    $seen = @{}
    $add = {
        param([string] $Path, [int64] $Size)
        $l = $Path.ToLowerInvariant()
        if ($seen.ContainsKey($l) -or (Test-BadCopy $key $Path)) { return }
        $seen[$l] = $true
        [void] $found.Add(@{ Path = $Path; Sha = $sha; Size = $Size })
    }

    $m = $script:Manifest[$key]
    $sha = $null
    if ($m -and ($Entry.Size -le 0 -or $m.Size -eq $Entry.Size)) {
        $sha = $m.Sha
        if ($m.Dest) {
            $index = Get-DirIndex -Directory (Split-Path -Parent $m.Dest) -Cache $Cache
            $length = $index[(Split-Path -Leaf $m.Dest).ToLowerInvariant()]
            if ($null -ne $length -and $length -eq $m.Size) { & $add $m.Dest $length }
        }
    }

    $directory = Join-Path $script:Dest $Entry.Rel
    $index = Get-DirIndex -Directory $directory -Cache $Cache
    $safe = Get-SafeName $Entry.Name
    $lower = $safe.ToLowerInvariant()
    if ($index.ContainsKey($lower) -and $index[$lower] -eq $Entry.Size) { & $add (Join-Path $directory $safe) $Entry.Size }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($safe)
    $extension = [System.IO.Path]::GetExtension($safe)
    for ($n = 1; $n -lt 1000; $n++) {
        $candidate = '{0}_{1}{2}' -f $base, $n, $extension
        $l = $candidate.ToLowerInvariant()
        if (-not $index.ContainsKey($l)) { break }
        if ($index[$l] -eq $Entry.Size) { & $add (Join-Path $directory $candidate) $Entry.Size }
    }

    $elsewhere = $null
    if ($script:DestIndex) { $elsewhere = $script:DestIndex[$lower] }
    if ($elsewhere) {
        $same = @($elsewhere | Where-Object { $_.Size -eq $Entry.Size })
        if ($Entry.Mod) {
            $same = @($same | Sort-Object { if ($_.Mod -and [math]::Abs(($_.Mod - $Entry.Mod).TotalSeconds) -le 2) { 0 } else { 1 } })
        }
        foreach ($c in $same) { if ([System.IO.File]::Exists($c.Path)) { & $add $c.Path $c.Size } }
    }
    return , $found
}

function Find-Copy {
    param($Entry, $Cache)
    $all = Find-Copies -Entry $Entry -Cache $Cache
    if ($all.Count -gt 0) { return $all[0] }
    return $null
}

function Test-Overlap {
    # A destination inside the source (or the source inside it) would let every file count
    # as its own copy - and then be deleted. Path text first; Delete also compares file IDs.
    if (-not $script:Source -or $script:Source.Kind -ne 'Folder' -or -not $script:Dest) { return $false }
    $src = [System.IO.Path]::GetFullPath($script:Source.Path).TrimEnd('\') + '\'
    $dst = [System.IO.Path]::GetFullPath($script:Dest).TrimEnd('\') + '\'
    return ($dst.StartsWith($src, [StringComparison]::OrdinalIgnoreCase) -or $src.StartsWith($dst, [StringComparison]::OrdinalIgnoreCase))
}

function Assert-NoOverlap {
    if (Test-Overlap) { throw 'The destination is the same as, or inside, the folder being copied from. Please choose a destination somewhere else.' }
}

function Set-Destination {
    param([string] $Path)
    $script:Dest = $Path
    $script:Verified = @{}   # checks were against the old destination
    if (-not $Path) {
        $script:Manifest = @{}; $script:DestIndex = @{}
        Send-Event 'Session' @{ State = '' }
        return
    }
    if (Test-Overlap) {
        Send-Event 'Error' @{ Command = 'SetDestination'; Message = 'The destination is the same as, or inside, the folder being copied from. Please choose a destination somewhere else.' }
    }
    Import-Manifest
    Update-DestIndex
    Write-Log "destination: $Path ($($script:Manifest.Count) fingerprints on record)"
    $cache = @{}
    foreach ($name in @($script:Folders.Keys)) { Send-Event 'FolderStatus' (Get-FolderSummary -Name $name -Cache $cache) }

    $sessionPath = Join-Path (Get-MetaDirectory) 'session.json'
    $session = $null
    if (Test-Path -LiteralPath $sessionPath) {
        try { $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json } catch { }
    }
    if ($session -and $session.State -eq 'copying') {
        Send-Event 'Session' @{ State = [string] $session.State; Folders = [string[]] @($session.Folders); Started = [string] $session.Started }
    }
    else { Send-Event 'Session' @{ State = '' } }
}

function Use-PendingDestination {
    # The window may change the destination while a long scan is running; pick it up between folders.
    $pending = $sync.NewDest
    if ($pending) {
        $sync.NewDest = $null
        Set-Destination $pending
    }
}

function Save-Session {
    param([string] $State, [string[]] $Names)
    try {
        $path = Join-Path (Get-MetaDirectory) 'session.json'
        $data = @{ State = $State; Folders = $Names; Started = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Source = $script:Source.Label }
        [System.IO.File]::WriteAllText($path, ($data | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { Write-Log "could not save the session file: $(Get-ErrorText $_)" }
}

# ---------------------------------------------------------------------------
# copying one file
# ---------------------------------------------------------------------------

function ConvertTo-CsvField {
    param($Value)
    $text = [string] $Value
    if ($text -match '[,"\r\n]') { return '"' + $text.Replace('"', '""') + '"' }
    return $text
}

function Open-Manifest {
    $path = Join-Path (Get-MetaDirectory) 'manifest.csv'
    $isNew = -not (Test-Path -LiteralPath $path)
    $script:ManifestWriter = New-Object System.IO.StreamWriter($path, $true, (New-Object System.Text.UTF8Encoding($false)))
    $script:ManifestWriter.AutoFlush = $true
    if ($isNew) { $script:ManifestWriter.WriteLine('timestamp,status,folder,name,size_bytes,destination,sha256,seconds,attempts,error') }
}

function Close-Manifest {
    if ($script:ManifestWriter) { try { $script:ManifestWriter.Close() } catch { }; $script:ManifestWriter = $null }
}

function Write-ManifestRow {
    param([string] $Status, $Entry, [int64] $Size, [string] $FinalPath, [string] $Sha, [double] $Seconds, [int] $Attempts, [string] $ErrorText)
    if (-not $script:ManifestWriter) { return }
    $fields = @((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Status, $Entry.Rel, $Entry.Name, $Size, $FinalPath, $Sha, $Seconds.ToString('0.00', $script:Invariant), $Attempts, $ErrorText)
    try { $script:ManifestWriter.WriteLine((($fields | ForEach-Object { ConvertTo-CsvField $_ }) -join ',')) }
    catch { Write-Log "could not write to the manifest: $(Get-ErrorText $_)" }
}

function Get-FreeName {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $directory = Split-Path -Path $Path -Parent
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $extension = [System.IO.Path]::GetExtension($Path)
    for ($n = 1; ; $n++) {
        $candidate = Join-Path $directory ('{0}_{1}{2}' -f $base, $n, $extension)
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
}

function Read-SourceStream {
    # Reads a source file start to end in chunks, hashing on the way, writing to $Target
    # when one is given. Progress and cancellation are checked after every chunk.
    param($Entry, [string] $Target = '')
    $item = $Entry.Item
    $buffer = $script:Buffer
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fileIn = $null; $deviceIn = $null; $out = $null
    $total = [int64] 0
    $expected = [int64] -1
    try {
        if ($item.IsFileSystem) {
            $fileIn = [System.IO.File]::Open($item.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            $expected = $fileIn.Length
        }
        else {
            $deviceIn = [IPhoneTransferApp.ItemStream]::Open($item)
            $expected = $deviceIn.Length
        }
        if ($Target) { $out = New-Object System.IO.FileStream($Target, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1MB) }
        $head = $null
        while ($true) {
            Assert-NotCancelled
            if ($fileIn) { $n = $fileIn.Read($buffer, 0, $buffer.Length) }
            else         { $n = $deviceIn.Read($buffer, $buffer.Length) }
            if ($n -le 0) { break }
            if ($null -eq $head) { $head = New-Object byte[] ([math]::Min(32, $n)); [Array]::Copy($buffer, $head, $head.Length) }
            if ($out) { $out.Write($buffer, 0, $n) }
            [void] $sha.TransformBlock($buffer, 0, $n, $null, 0)
            $total += $n
            Update-Progress -Current $total
        }
        if ($out) { $out.Flush($true) }
    }
    finally {
        if ($out) { $out.Close() }
        if ($fileIn) { $fileIn.Close() }
        if ($deviceIn) { $deviceIn.Dispose() }
    }
    [void] $sha.TransformFinalBlock($buffer, 0, 0)
    $hash = ([System.BitConverter]::ToString($sha.Hash)).Replace('-', '')
    $sha.Dispose()
    return @{ Bytes = $total; Sha = $hash; Expected = $expected; Head = $head }
}

function Get-FileSha256 {
    # Hashes a file on the PC, with progress; used to read every copy back.
    param([string] $Path)
    $buffer = $script:Buffer
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $total = [int64] 0
    try {
        while ($true) {
            Assert-NotCancelled
            $n = $stream.Read($buffer, 0, $buffer.Length)
            if ($n -le 0) { break }
            [void] $sha.TransformBlock($buffer, 0, $n, $null, 0)
            $total += $n
            Update-Progress -Current $total
        }
    }
    finally { $stream.Close() }
    [void] $sha.TransformFinalBlock($buffer, 0, 0)
    $hash = ([System.BitConverter]::ToString($sha.Hash)).Replace('-', '')
    $sha.Dispose()
    return $hash
}

function Copy-ViaExplorer {
    # Last-resort engine for a phone file the byte stream keeps failing on: Explorer's own
    # copy. It reports nothing back, so it gets a private folder and we watch for the file.
    param($Entry, [string] $Staging)
    $private = $Staging + '.d'
    New-Item -ItemType Directory -Force -Path $private | Out-Null
    $target = $script:Shell.NameSpace($private)
    if ($null -eq $target) { throw "cannot open the staging folder $private" }
    $arrival = Join-Path $private $Entry.Name
    $timeout = [math]::Max([double] 60, [double] $Entry.Size / 1MB * 2)
    $target.CopyHere($Entry.Item, $COPY_FLAGS)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeout) {
        Assert-NotCancelled
        if (Test-Path -LiteralPath $arrival) {
            try {
                $probe = [System.IO.File]::Open($arrival, 'Open', 'Write', 'None'); $probe.Close()
                Move-Item -LiteralPath $arrival -Destination $Staging -Force
                Remove-Item -LiteralPath $private -Recurse -Force -ErrorAction SilentlyContinue
                $hash = Get-FileSha256 $Staging
                return @{ Bytes = (Get-Item -LiteralPath $Staging).Length; Sha = $hash; Expected = [int64] -1; ReadBack = $true; FromExplorer = $true }
            }
            catch { if (Test-Cancelled $_) { throw } }
        }
        Start-Sleep -Milliseconds 200
    }
    throw "the file never arrived (waited $([int] $sw.Elapsed.TotalSeconds) s)"
}

function Remove-Partial {
    param([string] $Path)
    foreach ($p in @($Path, ($Path + '.d'))) {
        if ($p -and (Test-Path -LiteralPath $p)) { try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop } catch { } }
    }
}

function Set-FileTimes {
    param([string] $Path, $Entry)
    try {
        if ($Entry.Mod) { [System.IO.File]::SetLastWriteTimeUtc($Path, $Entry.Mod) }
        if ($Entry.Cre) { [System.IO.File]::SetCreationTimeUtc($Path, $Entry.Cre) }
        elseif ($Entry.Mod) { [System.IO.File]::SetCreationTimeUtc($Path, $Entry.Mod) }
    }
    catch { }
}

function Test-Signature {
    # Does the start of the data look like this kind of file? A phone in a bad state has been
    # seen to hand over the previous file's bytes; this catches that when the types differ.
    # Unknown types pass. Returns $true when it looks right.
    param([byte[]] $Head, [string] $Extension)
    if ($null -eq $Head -or $Head.Length -lt 12) { return $true }
    $ascii = [System.Text.Encoding]::ASCII.GetString($Head, 0, [math]::Min($Head.Length, 16))
    $box = [System.Text.Encoding]::ASCII.GetString($Head, 4, 4)
    switch ($Extension) {
        { $_ -in '.jpg', '.jpeg' } { return ($Head[0] -eq 0xFF -and $Head[1] -eq 0xD8) }
        '.png'  { return ($Head[0] -eq 0x89 -and $ascii.Substring(1, 3) -eq 'PNG') }
        { $_ -in '.heic', '.heif', '.mov', '.mp4', '.m4v', '.3gp' } { return (@('ftyp', 'moov', 'wide', 'mdat', 'free', 'skip', 'pnot') -contains $box) }
        '.aae'  { return ($ascii.TrimStart([char] 0xFEFF, ' ', "`r", "`n", "`t").StartsWith('<?xml') -or $ascii.StartsWith('bplist') -or $ascii.TrimStart().StartsWith('<')) }
        { $_ -in '.dng', '.tif', '.tiff' } { return ($ascii.StartsWith('II') -or $ascii.StartsWith('MM')) }
        '.gif'  { return $ascii.StartsWith('GIF8') }
        '.webp' { return $ascii.StartsWith('RIFF') }
        default { return $true }
    }
}

function Reset-DeviceConnection {
    # A fresh connection to the phone after it handed over wrong data or stopped answering.
    Write-Log 'opening a fresh connection to the source'
    $script:Shell = New-Object -ComObject Shell.Application
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 800
}

function Copy-OneFile {
    # Returns @{ Ok; Status; Path; Bytes; Sha; Error; DiskFull }. Never throws except for cancel.
    param($Job, [string] $StagingDirectory)
    $entry = $Job.Entry
    $key = Get-EntryKey $entry
    $attempt = 0
    $disconnects = 0
    $useExplorer = $false
    $shaky = $false        # an attempt got data that cannot have been this file
    $suspect = $null       # SHA-256 of an attempt that looked wrong; accepted only if a fresh connection gives the same bytes
    $note = ''
    while ($true) {
        $attempt++
        $staging = Join-Path $StagingDirectory ('{0}.{1}.part' -f (Get-SafeName $entry.Name), [guid]::NewGuid().ToString('N').Substring(0, 8))
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resetNeeded = $false
        try {
            if ($useExplorer) { $result = Copy-ViaExplorer -Entry $entry -Staging $staging }
            else              { $result = Read-SourceStream -Entry $entry -Target $staging }

            # Is what arrived this file, and complete?
            $expected = $result.Expected
            if ($expected -le 0) { $expected = $entry.Size }
            if ($result.Bytes -le 0 -and $expected -gt 0) { throw 'received 0 bytes' }
            if ($result.Bytes -le 0 -and $result.Expected -lt 0 -and $script:Source.Kind -eq 'Device') { throw 'received 0 bytes and the iPhone did not say how big the file is' }
            if ($expected -gt 0 -and $result.Bytes -ne $expected) {
                $shaky = $true; $resetNeeded = $true
                throw ('size mismatch: received {0} bytes, expected {1}' -f $result.Bytes, $expected)
            }
            $looksWrong = ''
            if (-not $result.FromExplorer -and -not (Test-Signature $result.Head $entry.Ext)) { $looksWrong = "the data does not look like a $($entry.Ext.TrimStart('.').ToUpperInvariant()) file" }
            elseif ($script:LastCopy -and $script:LastCopy.Key -ne $key -and $script:LastCopy.Sha -eq $result.Sha) { $looksWrong = "the data is identical to the previous file ($($script:LastCopy.Name))" }
            if ($looksWrong) {
                if ($suspect -and $suspect -eq $result.Sha) {
                    # A fresh connection gave exactly the same bytes: that is what the file holds.
                    # Kept, but without a fingerprint, so the check reads it from the phone again.
                    $shaky = $true
                    $note = $looksWrong + ' - confirmed over a fresh connection'
                }
                else {
                    $suspect = $result.Sha; $shaky = $true; $resetNeeded = $true
                    throw $looksWrong
                }
            }
            $onDisk = (Get-Item -LiteralPath $staging -Force).Length
            if ($onDisk -ne $result.Bytes) { throw ('the staged file holds {0} bytes, expected {1}' -f $onDisk, $result.Bytes) }
            if (-not $result.ReadBack) {
                $P.Step = 'reading back'
                $again = Get-FileSha256 $staging
                $P.Step = ''
                if ($again -ne $result.Sha) { throw 'the copy read back from disk differs from what was received' }
            }

            Set-FileTimes -Path $staging -Entry $entry
            New-Item -ItemType Directory -Force -Path $Job.TargetDirectory | Out-Null
            $final = Get-FreeName $Job.Landing
            $status = 'copied'
            if ($final -ne $Job.Landing) { $status = 'renamed' }
            try { [System.IO.File]::Move($staging, $final) }
            catch {
                if (Test-Path -LiteralPath $final) { throw }
                [System.IO.File]::Copy($staging, $final, $false); [System.IO.File]::Delete($staging)
            }
            $sw.Stop()
            # A fingerprint only counts when it is beyond doubt: bytes we read ourselves, in a
            # transfer where the phone never handed over wrong data. Otherwise none is recorded
            # and the check reads the file from the phone again.
            $fingerprint = $result.Sha
            if ($result.FromExplorer -or $shaky) { $fingerprint = '' }
            Write-ManifestRow -Status $status -Entry $entry -Size $result.Bytes -FinalPath $final -Sha $fingerprint -Seconds $sw.Elapsed.TotalSeconds -Attempts $attempt -ErrorText $note
            Add-DestIndex -Path $final -Size $result.Bytes -Mod $entry.Mod
            if ($fingerprint) { $script:Manifest[$key] = @{ Dest = $final; Sha = $fingerprint; Size = $result.Bytes } }
            else { [void] $script:Manifest.Remove($key) }
            $script:LastCopy = @{ Key = $key; Sha = $result.Sha; Name = $entry.Name }
            return @{ Ok = $true; Status = $status; Path = $final; Bytes = $result.Bytes; Sha = $result.Sha; Attempts = $attempt }
        }
        catch {
            $sw.Stop()
            Remove-Partial $staging
            if (Test-Cancelled $_) { throw }
            $text = Get-ErrorText $_
            Write-Log "copy of $($entry.Rel)\$($entry.Name) failed (attempt $attempt): $text"
            $P.CurrentBytes = [int64] 0
            if (Test-DiskFull $_) { return @{ Ok = $false; DiskFull = $true; Error = $text; Attempts = $attempt } }

            if ($script:Source.Kind -eq 'Device' -and -not (Test-SourceAvailable)) {
                $disconnects++
                if ($disconnects -gt 50) { return @{ Ok = $false; Error = $text; Attempts = $attempt } }
                if (-not (Wait-ForDevice)) { throw (New-Object System.OperationCanceledException) }
                $attempt--   # a disconnect is not the file's fault
                $resetNeeded = $true
            }
            elseif ($attempt -ge 4) {
                if ($text -match 'received 0 bytes|0x8007001E|never arrived|0x80042007|0x8007065D') { $script:Unavailable[$key] = $text }
                return @{ Ok = $false; Error = $text; Attempts = $attempt }
            }
            else {
                Start-Sleep -Seconds ([math]::Min([double] 8, [math]::Pow(2, $attempt)))
            }

            if ($resetNeeded -and $script:Source.Kind -eq 'Device') { Reset-DeviceConnection }
            # A fresh handle: the old one may have gone stale with the hiccup.
            try { $entry.Item = Get-SourceFile $entry } catch { Write-Log "  could not re-open it yet: $(Get-ErrorText $_)" }
            # Last try on a phone: let Explorer's own copy have a go, in case the stream is the problem.
            if ($attempt -eq 3 -and $script:Source.Kind -eq 'Device') { $useExplorer = $true }
        }
    }
}

function Read-SourceTrusted {
    # Reads a source file for the check. Returns @{ Sha } only when the read can be trusted:
    # complete, the right kind of file, and not a repeat of the file read just before it
    # (a phone in a bad state hands over stale data). Otherwise reconnects and tries again;
    # gives up with @{ Sha = $null; Error } - which the check reports as "could not be read
    # reliably", never as "different", so a good copy is never written off because of it.
    param($Entry)
    $key = Get-EntryKey $Entry
    $lastError = ''
    $repeatSha = $null
    for ($round = 1; $round -le 2; $round++) {
        for ($try = 1; $try -le 3; $try++) {
            Assert-NotCancelled
            $problem = ''
            try {
                $r = Read-SourceStream -Entry $Entry
                $expected = $r.Expected
                if ($expected -le 0) { $expected = $Entry.Size }
                if ($r.Bytes -le 0 -and $expected -gt 0) { $problem = 'received 0 bytes' }
                elseif ($expected -gt 0 -and $r.Bytes -ne $expected) { $problem = "received $($r.Bytes) bytes, expected $expected" }
                elseif (-not (Test-Signature $r.Head $Entry.Ext)) {
                    # An unusual file is accepted only if a fresh connection gives exactly the same bytes.
                    if ($repeatSha -and $repeatSha -eq $r.Sha) { $problem = '' }
                    else { $repeatSha = $r.Sha; $problem = 'the data does not look like this kind of file' }
                }
                elseif ($script:LastCheckRead -and $script:LastCheckRead.Key -ne $key -and $script:LastCheckRead.Sha -eq $r.Sha) {
                    # Identical to the previous file: genuine (two equal edit files) only if a
                    # fresh connection gives exactly the same bytes again.
                    if ($repeatSha -and $repeatSha -eq $r.Sha) { $problem = '' }
                    else { $repeatSha = $r.Sha; $problem = 'the data repeats the previous file' }
                }
                if (-not $problem) {
                    $script:LastCheckRead = @{ Key = $key; Sha = $r.Sha }
                    $script:UnreliableInARow = 0
                    return @{ Sha = $r.Sha }
                }
            }
            catch {
                if (Test-Cancelled $_) { throw }
                $problem = Get-ErrorText $_
                if ($script:Source.Kind -eq 'Device' -and -not (Test-SourceAvailable)) {
                    if (-not (Wait-ForDevice)) { throw (New-Object System.OperationCanceledException) }
                }
            }
            $lastError = $problem
            Write-Log "check: unreliable read of $($Entry.Rel)\$($Entry.Name) (try $try): $problem"
            $P.CurrentBytes = [int64] 0
            if ($script:Source.Kind -eq 'Device') { Reset-DeviceConnection }
            try { $Entry.Item = Get-SourceFile $Entry } catch { }
        }
        # Several files in a row that cannot be read reliably: the phone itself is stuck.
        $script:UnreliableInARow = [int] $script:UnreliableInARow + 1
        if ($round -eq 1 -and $script:UnreliableInARow -ge 3 -and $script:Source.Kind -eq 'Device') {
            Wait-ForReplug
            $script:UnreliableInARow = 0
            try { $Entry.Item = Get-SourceFile $Entry } catch { }
            continue
        }
        break
    }
    return @{ Sha = $null; Error = $lastError }
}

function Wait-ForReplug {
    # The phone is connected but has stopped handing over files. Usually unplugging it and
    # plugging it back in (and unlocking it) fixes that. Wait for exactly that, or for the
    # "Try again now" button, or for Stop.
    Write-Log 'the source keeps failing - asking for it to be plugged in again'
    $P.Waiting = $true
    $sync.TryAgain = $false
    Send-Event 'Trouble' @{ On = $true }
    $sawGone = $false
    try {
        while (-not $sync.Cancel) {
            if ($sync.TryAgain) { $sync.TryAgain = $false; Write-Log 'trying again (button)'; break }
            Start-Sleep -Seconds 2
            if ($script:Source.Kind -ne 'Device') { continue }
            if (-not (Test-SourceAvailable)) { $sawGone = $true }
            elseif ($sawGone) { Write-Log 'source was plugged in again'; break }
        }
    }
    finally {
        $P.Waiting = $false
        Send-Event 'Trouble' @{ On = $false }
    }
    if ($sync.Cancel) { throw (New-Object System.OperationCanceledException) }
    Reset-DeviceConnection
    $script:Samples.Clear()
}

# ---------------------------------------------------------------------------
# copy command
# ---------------------------------------------------------------------------

function Invoke-Copy {
    param([string[]] $Names)
    if (-not $script:Dest) { throw 'No destination chosen.' }
    Assert-NoOverlap
    New-Item -ItemType Directory -Force -Path $script:Dest | Out-Null
    $meta = Get-MetaDirectory
    New-Item -ItemType Directory -Force -Path $meta | Out-Null
    try { (Get-Item -LiteralPath $meta -Force).Attributes = 'Directory, Hidden' } catch { }
    $staging = Join-Path $meta 'staging'
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    Import-Manifest
    Update-DestIndex

    # Plan: every file in the chosen folders that is not on the PC yet.
    $jobs = New-Object System.Collections.ArrayList
    $perFolder = [ordered] @{}
    $already = 0; $alreadyBytes = [int64] 0; $bytes = [int64] 0
    $cache = @{}
    foreach ($name in $Names) {
        $record = $script:Folders[$name]
        if ($null -eq $record) { continue }
        $info = @{ Name = $name; Total = $record.Files.Count; ToCopy = 0; ToCopyBytes = [int64] 0; Done = 0; DoneBytes = [int64] 0; Failed = 0; Already = 0 }
        foreach ($entry in ($record.Files | Sort-Object { $_.Rel }, { $_.Name })) {
            if (Find-Copy -Entry $entry -Cache $cache) { $already++; $alreadyBytes += $entry.Size; $info.Already++; continue }
            $targetDirectory = Join-Path $script:Dest $entry.Rel
            [void] $jobs.Add(@{ Entry = $entry; Folder = $name; TargetDirectory = $targetDirectory; Landing = (Join-Path $targetDirectory (Get-SafeName $entry.Name)) })
            $info.ToCopy++; $info.ToCopyBytes += $entry.Size; $bytes += $entry.Size
        }
        $perFolder[$name] = $info
    }

    Reset-Progress -Phase 'Copy' -FilesTotal $jobs.Count -BytesTotal $bytes
    $planList = @($perFolder.Values | ForEach-Object { @{ Name = $_.Name; Total = $_.Total; ToCopy = $_.ToCopy; ToCopyBytes = $_.ToCopyBytes; Already = $_.Already } })
    Send-Event 'CopyPlan' @{ Folders = $planList; Files = $jobs.Count; Bytes = $bytes; Already = $already; AlreadyBytes = $alreadyBytes }
    Write-Log ("copy plan: {0} files ({1}) to copy, {2} already there" -f $jobs.Count, (Format-Bytes $bytes), $already)

    $copied = 0; $copiedBytes = [int64] 0; $renamed = 0
    $script:LastCopy = $null
    $failed = New-Object System.Collections.ArrayList
    $stopReason = ''
    $cancelled = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    Save-Session -State 'copying' -Names $Names
    Open-Manifest
    [IPhoneTransferApp.Native]::KeepAwake($true)
    try {
        # Files that fail are tried once more at the end, after everything else - a phone often
        # manages a file later that it could not hand over a minute ago.
        $queue = New-Object System.Collections.ArrayList
        foreach ($job in $jobs) { [void] $queue.Add(@{ Job = $job; Round = 1 }) }
        $inARow = 0
        for ($q = 0; $q -lt $queue.Count; $q++) {
            $job = $queue[$q].Job
            $round = $queue[$q].Round
            while ($sync.Pause -and -not $sync.Cancel) { $P.Paused = $true; Start-Sleep -Milliseconds 200 }
            $P.Paused = $false
            if ($sync.Cancel) { $cancelled = $true; break }

            $entry = $job.Entry
            $free = [IPhoneTransferApp.Native]::GetFreeBytes($script:Dest)
            if ($free -ge 0 -and $free -lt ($entry.Size + $RESERVE_BYTES)) {
                $stopReason = 'The PC''s disk is almost full, so copying stopped. Free up some space (or pick another drive) and press Copy again - it continues where it stopped.'
                break
            }

            if ($round -gt 1) { $P.Step = 'second try' } else { $P.Step = '' }
            Set-Current -Name $entry.Name -Folder $job.Folder -Size $entry.Size
            Update-Progress -Force
            try { $result = Copy-OneFile -Job $job -StagingDirectory $staging }
            catch {
                if (Test-Cancelled $_) { $cancelled = $true; break }
                $result = @{ Ok = $false; Error = (Get-ErrorText $_); Attempts = 1 }
            }
            $P.Step = ''

            $info = $perFolder[$job.Folder]
            $final = $true
            if ($result.Ok) {
                $inARow = 0
                $copied++; $copiedBytes += $result.Bytes
                if ($result.Status -eq 'renamed') { $renamed++ }
                $info.Done++; $info.DoneBytes += $result.Bytes
            }
            else {
                $inARow++
                if ($result.DiskFull) {
                    $info.Failed++
                    [void] $failed.Add(@{ Folder = $job.Folder; Name = $entry.Name; Error = $result.Error })
                    Write-ManifestRow -Status 'failed' -Entry $entry -Size $entry.Size -FinalPath $job.Landing -Sha '' -Seconds 0 -Attempts $result.Attempts -ErrorText $result.Error
                    $stopReason = 'The PC''s disk is full, so copying stopped. Free up some space (or pick another drive) and press Copy again - it continues where it stopped.'
                    break
                }
                if ($round -eq 1) {
                    [void] $queue.Add(@{ Job = $job; Round = 2 })   # one more go at the end
                    $final = $false
                    Write-Log "  $($entry.Rel)\$($entry.Name) will be tried again at the end"
                }
                else {
                    $info.Failed++
                    [void] $failed.Add(@{ Folder = $job.Folder; Name = $entry.Name; Error = $result.Error })
                    Write-ManifestRow -Status 'failed' -Entry $entry -Size $entry.Size -FinalPath $job.Landing -Sha '' -Seconds 0 -Attempts $result.Attempts -ErrorText $result.Error
                }
                # Several files in a row failing means the phone itself is stuck, not the files.
                if ($inARow -ge 3 -and $script:Source.Kind -eq 'Device') {
                    try { Wait-ForReplug }
                    catch { if (Test-Cancelled $_) { $cancelled = $true; break } }
                    $inARow = 0
                }
            }
            if ($final) {
                $P.FilesDone = [int64] $P.FilesDone + 1
                $P.BytesDone = [int64] $P.BytesDone + $entry.Size
            }
            $P.CurrentBytes = [int64] 0
            Update-Progress -Force
            Send-Event 'CopyFolderProgress' @{ Name = $job.Folder; Done = $info.Done; ToCopy = $info.ToCopy; Failed = $info.Failed; DoneBytes = $info.DoneBytes; ToCopyBytes = $info.ToCopyBytes; TotalCopied = $copied; TotalFailed = $failed.Count }
        }
    }
    finally {
        [IPhoneTransferApp.Native]::KeepAwake($false)
        Close-Manifest
        try { if (@(Get-ChildItem -LiteralPath $staging -Force).Count -eq 0) { Remove-Item -LiteralPath $staging -Force } } catch { }
    }
    $sw.Stop()

    $complete = (-not $cancelled) -and (-not $stopReason) -and $failed.Count -eq 0
    if ($complete) { Save-Session -State 'copied' -Names $Names } else { Save-Session -State 'copying' -Names $Names }
    $speed = 0.0
    if ($sw.Elapsed.TotalSeconds -gt 0) { $speed = $copiedBytes / $sw.Elapsed.TotalSeconds }
    Write-Log ("copy finished: {0} copied ({1}), {2} failed, cancelled={3}, stop='{4}'" -f $copied, (Format-Bytes $copiedBytes), $failed.Count, $cancelled, $stopReason)
    Send-Event 'CopyDone' @{
        Copied = $copied; CopiedBytes = $copiedBytes; Renamed = $renamed; Already = $already; AlreadyBytes = $alreadyBytes
        Failed = @($failed); Cancelled = $cancelled; StopReason = $stopReason; Seconds = $sw.Elapsed.TotalSeconds; Speed = $speed
        NotAttempted = [int64] ($jobs.Count - $P.FilesDone)
    }
    $cache = @{}
    foreach ($name in $Names) { Send-Event 'FolderStatus' (Get-FolderSummary -Name $name -Cache $cache) }
}

# ---------------------------------------------------------------------------
# check command
# ---------------------------------------------------------------------------

function Invoke-Verify {
    # Compares what is on the phone right now with the copies on the PC, file by file.
    #   - every phone file must have a copy with the same name and size
    #   - the copy is read back and its SHA-256 compared with the fingerprint taken while
    #     the bytes came off the phone
    #   - where there is no fingerprint (copied by something else), or the dates do not
    #     line up, or a full check was asked for, the phone file is read again and compared
    param([string[]] $Names, [bool] $Full)
    if (-not $script:Dest) { throw 'No destination chosen.' }
    Assert-NoOverlap
    # Forget earlier results for these folders first: a check that is stopped or fails part-way
    # must never leave an older "OK" behind for Delete to act on.
    foreach ($n in $Names) { [void] $script:Verified.Remove($n) }
    Import-Manifest
    Update-DestIndex
    $script:LastCheckRead = $null; $script:UnreliableInARow = 0
    Reset-Progress -Phase 'Verify' -Step 'Reading the list of files from the iPhone again'
    $P.FilesTotal = [int64] $Names.Count

    $lists = [ordered] @{}
    foreach ($name in $Names) {
        Assert-NotCancelled
        $P.CurrentFolder = $name
        try { $lists[$name] = Read-TopFolder $name }
        catch {
            if (Test-Cancelled $_) { throw }
            $lists[$name] = $null
            Write-Log "check: could not list $name : $(Get-ErrorText $_)"
        }
        $P.FilesDone = [int64] $P.FilesDone + 1
    }

    # Work out what has to be read, so progress can be shown in bytes.
    $cache = @{}
    $plans = [ordered] @{}
    $files = [int64] 0; $bytes = [int64] 0
    foreach ($name in $Names) {
        $list = $lists[$name]
        $plan = New-Object System.Collections.ArrayList
        if ($null -ne $list) {
            foreach ($entry in $list) {
                $copies = Find-Copies -Entry $entry -Cache $cache
                $copy = $null
                if ($copies.Count -gt 0) { $copy = $copies[0] }
                $readPhone = $false
                if ($copy) {
                    $readPhone = $Full -or (-not $copy.Sha) -or (-not $entry.Mod)
                    if (-not $readPhone -and $entry.Mod) {
                        try {
                            $written = [System.IO.File]::GetLastWriteTimeUtc($copy.Path)
                            if ([math]::Abs(($written - $entry.Mod).TotalSeconds) -gt 2) { $readPhone = $true }
                        }
                        catch { }
                    }
                    $bytes += $copy.Size
                    if ($readPhone) { $bytes += $entry.Size }
                }
                $files++
                [void] $plan.Add(@{ Entry = $entry; Copy = $copy; Copies = $copies; ReadPhone = $readPhone })
            }
        }
        $plans[$name] = $plan
    }

    Reset-Progress -Phase 'Verify' -FilesTotal $files -BytesTotal $bytes -Step 'Checking every file'
    Send-Event 'VerifyPlan' @{ Files = $files; Bytes = $bytes; Full = $Full }
    $allResults = New-Object System.Collections.ArrayList
    $summaries = New-Object System.Collections.ArrayList

    foreach ($name in $Names) {
        $plan = $plans[$name]
        $folderFiles = New-Object System.Collections.ArrayList
        $okFiles = @{}
        $phoneFiles = 0; $phoneBytes = [int64] 0; $pcFiles = 0; $pcBytes = [int64] 0; $okCount = 0
        $problems = New-Object System.Collections.ArrayList
        foreach ($step in $plan) {
            Assert-NotCancelled
            $entry = $step.Entry; $copy = $step.Copy
            $phoneFiles++; $phoneBytes += $entry.Size
            Set-Current -Name $entry.Name -Folder $name -Size $entry.Size
            $record = @{ Folder = $name; Rel = $entry.Rel; Name = $entry.Name; Size = $entry.Size; Dest = ''; DestSize = [int64] -1; Sha = ''; Status = 'OK'; Method = ''; Detail = '' }

            if ($null -eq $copy) {
                $record.Status = 'Missing'; $record.Detail = 'not on the PC'
                $why = $script:Unavailable[(Get-EntryKey $entry)]
                if ($why) { $record.Detail = 'not on the PC - the iPhone lists it but would not hand it over (' + $why + ')' }
            }
            else {
                $key = Get-EntryKey $entry
                $record.Dest = $copy.Path; $record.DestSize = $copy.Size
                $pcFiles++; $pcBytes += $copy.Size

                # What the copy must equal: the fingerprint taken when it was copied - or, when
                # there is none, the dates disagree, or a full check was asked for, the source
                # file read again right now.
                $expected = $null; $how = ''
                if ($step.ReadPhone) {
                    Set-Current -Name $entry.Name -Folder $name -Size $entry.Size
                    $phone = Read-SourceTrusted -Entry $entry
                    $P.BytesDone = [int64] $P.BytesDone + $entry.Size; $P.CurrentBytes = [int64] 0
                    if ($null -eq $phone.Sha) {
                        $lastReadProblem = $phone.Error
                        $phone = $null
                        $record.Status = 'Unreadable'
                        $record.Detail = 'the iPhone did not give a reliable read (' + $lastReadProblem + ') - unplug and replug it, then check again'
                    }
                    else {
                        $expected = $phone.Sha
                        if ($script:Source.Kind -eq 'Device') { $how = 'read from the iPhone again' } else { $how = 'read from the source again' }
                    }
                }
                else { $expected = $copy.Sha; $how = 'fingerprint from the copy' }

                if ($expected) {
                    # Try each file on the PC with this name and size until one matches.
                    $matched = $null; $first = $true; $readable = $false
                    foreach ($candidate in $step.Copies) {
                        Set-Current -Name $entry.Name -Folder $name -Size $candidate.Size
                        try { $hash = Get-FileSha256 $candidate.Path; $readable = $true }
                        catch {
                            if (Test-Cancelled $_) { throw }
                            Write-Log "check: could not read $($candidate.Path): $(Get-ErrorText $_)"
                            Set-BadCopy $key $candidate.Path
                            continue
                        }
                        finally {
                            if ($first) { $P.BytesDone = [int64] $P.BytesDone + $candidate.Size; $first = $false }
                            $P.CurrentBytes = [int64] 0
                        }
                        if ($hash -eq $expected) { $matched = $candidate; break }
                        Set-BadCopy $key $candidate.Path
                    }
                    if ($matched) {
                        $record.Dest = $matched.Path; $record.DestSize = $matched.Size; $record.Sha = $hash; $record.Method = $how
                    }
                    elseif (-not $readable) {
                        $record.Status = 'Unreadable'; $record.Detail = 'could not read the copy on the PC'
                    }
                    else {
                        $record.Status = 'Different'
                        if ($step.ReadPhone) { $record.Detail = 'a file with this name and size is on the PC, but its content is different' }
                        else { $record.Detail = 'the copy on the PC changed since it was made' }
                    }
                }
            }

            if ($record.Status -eq 'OK') {
                $okCount++
                $okFiles[($entry.Rel + '|' + $entry.Name).ToLowerInvariant()] = @{ Size = $entry.Size; Dest = $record.Dest; Sha = $record.Sha; Mod = $entry.Mod }
            }
            else { [void] $problems.Add(@{ Name = (Join-Path $entry.Rel $entry.Name); Status = $record.Status; Detail = $record.Detail }) }
            [void] $folderFiles.Add($record)
            [void] $allResults.Add($record)
            $P.FilesDone = [int64] $P.FilesDone + 1
            Update-Progress -Force
        }

        $readable = $null -ne $lists[$name]
        $ok = $readable -and $phoneFiles -gt 0 -and $okCount -eq $phoneFiles
        # Photos with any file that did not match stay on the phone completely - every file of them.
        $blocked = @{}
        foreach ($r in $folderFiles) { if ($r.Status -ne 'OK') { $blocked[(Get-AssetKey $r.Rel $r.Name)] = $true } }
        $deletable = 0; $deletableBytes = [int64] 0
        foreach ($k in $okFiles.Keys) {
            $parts = $k.Split('|')
            if (-not $blocked.ContainsKey((Get-AssetKey $parts[0] $parts[1]))) { $deletable++; $deletableBytes += $okFiles[$k].Size }
        }
        if (-not $readable) { $deletable = 0; $deletableBytes = [int64] 0 }
        $script:Verified[$name] = @{ Ok = $ok; Files = $okFiles; Blocked = $blocked; Deletable = $deletable; At = (Get-Date) }
        $summary = @{
            Name = $name; Ok = $ok; Readable = $readable
            PhoneFiles = $phoneFiles; PhoneBytes = $phoneBytes; PcFiles = $pcFiles; PcBytes = $pcBytes; OkFiles = $okCount
            Problems = @($problems | Select-Object -First 200); ProblemCount = $problems.Count
            DeletableFiles = $deletable; DeletableBytes = $deletableBytes; KeptFiles = ($phoneFiles - $deletable)
        }
        [void] $summaries.Add($summary)
        Write-Log ("check {0}: {1} of {2} files OK" -f $name, $okCount, $phoneFiles)
        Send-Event 'FolderVerified' $summary
    }

    $report = Save-CheckReport -Summaries $summaries -Results $allResults -Full $Full
    $allOk = (@($summaries | Where-Object { -not $_.Ok }).Count -eq 0) -and $summaries.Count -gt 0
    Send-Event 'VerifyDone' @{ AllOk = $allOk; Report = $report; Full = $Full }
}

function ConvertTo-Html {
    param([string] $Text)
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Save-CheckReport {
    param($Summaries, $Results, [bool] $Full)
    try {
        $meta = Get-MetaDirectory
        New-Item -ItemType Directory -Force -Path $meta | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $csvPath = Join-Path $meta "check-$stamp.csv"
        $htmlPath = Join-Path $meta "check-$stamp.html"

        $csv = New-Object System.Text.StringBuilder
        [void] $csv.AppendLine('folder,name,phone_size,pc_size,result,how_checked,pc_path,sha256,detail')
        foreach ($r in $Results) {
            [void] $csv.AppendLine((@($r.Rel, $r.Name, $r.Size, $r.DestSize, $r.Status, $r.Method, $r.Dest, $r.Sha, $r.Detail) | ForEach-Object { ConvertTo-CsvField $_ }) -join ',')
        }
        [System.IO.File]::WriteAllText($csvPath, $csv.ToString(), (New-Object System.Text.UTF8Encoding($false)))

        $okAll = (@($Summaries | Where-Object { -not $_.Ok }).Count -eq 0)
        $h = New-Object System.Text.StringBuilder
        [void] $h.Append('<!doctype html><html><head><meta charset="utf-8"><title>iPhone Transfer - check report</title><style>')
        [void] $h.Append('body{font-family:Segoe UI,Arial,sans-serif;margin:32px;color:#0f172a;background:#f8fafc}h1{font-size:24px;margin:0 0 4px}')
        [void] $h.Append('.sub{color:#64748b;margin-bottom:24px}.verdict{padding:16px 20px;border-radius:10px;font-size:17px;margin-bottom:24px}')
        [void] $h.Append('.good{background:#dcfce7;color:#14532d}.bad{background:#fef3c7;color:#78350f}table{border-collapse:collapse;width:100%;background:#fff;margin-bottom:24px}')
        [void] $h.Append('th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #e2e8f0;font-size:13px}th{background:#f1f5f9}.ok{color:#15803d;font-weight:600}.no{color:#b45309;font-weight:600}')
        [void] $h.Append('details{background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:8px 12px;margin-bottom:10px}summary{cursor:pointer;font-weight:600}td.num{text-align:right}</style></head><body>')
        [void] $h.Append('<h1>Check report</h1><div class="sub">')
        [void] $h.Append((ConvertTo-Html ('{0} - from {1} to {2} - {3}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm'), $script:Source.Label, $script:Dest, $(if ($Full) { 'full check: every file read from the source again' } else { 'standard check: every copy read back and compared with its fingerprint' }))))
        [void] $h.Append('</div>')
        $totalFiles = 0; $totalOk = 0
        foreach ($s in $Summaries) { $totalFiles += $s.PhoneFiles; $totalOk += $s.OkFiles }
        if ($okAll) { [void] $h.Append('<div class="verdict good">Everything matches: ' + $totalOk + ' of ' + $totalFiles + ' files are safely on the PC.</div>') }
        else { [void] $h.Append('<div class="verdict bad">' + ($totalFiles - $totalOk) + ' of ' + $totalFiles + ' files need attention - see below. Folders with problems are not offered for deleting.</div>') }
        [void] $h.Append('<table><tr><th>Folder</th><th>On the iPhone</th><th>On the PC</th><th>Matching</th><th>Result</th></tr>')
        foreach ($s in $Summaries) {
            $cls = 'no'; $res = 'needs attention'
            if ($s.Ok) { $cls = 'ok'; $res = 'all files match' }
            if (-not $s.Readable) { $res = 'could not read the folder' }
            [void] $h.Append(('<tr><td>{0}</td><td>{1} files, {2}</td><td>{3} files, {4}</td><td>{5} of {1}</td><td class="{6}">{7}</td></tr>' -f (ConvertTo-Html $s.Name), $s.PhoneFiles, (Format-Bytes $s.PhoneBytes), $s.PcFiles, (Format-Bytes $s.PcBytes), $s.OkFiles, $cls, $res))
        }
        [void] $h.Append('</table>')
        foreach ($s in $Summaries) {
            [void] $h.Append('<details><summary>' + (ConvertTo-Html $s.Name) + ' - ' + $s.PhoneFiles + ' files</summary><table><tr><th>File</th><th>iPhone size</th><th>PC size</th><th>Result</th><th>How</th></tr>')
            foreach ($r in ($Results | Where-Object { $_.Folder -eq $s.Name })) {
                $cls = 'ok'; if ($r.Status -ne 'OK') { $cls = 'no' }
                $pcSize = ''; if ($r.DestSize -ge 0) { $pcSize = $r.DestSize.ToString('N0', $script:Invariant) }
                $how = $r.Method; if ($r.Detail) { $how = $r.Detail }
                [void] $h.Append(('<tr><td>{0}</td><td class="num">{1}</td><td class="num">{2}</td><td class="{3}">{4}</td><td>{5}</td></tr>' -f (ConvertTo-Html (Join-Path $r.Rel $r.Name)), ([int64] $r.Size).ToString('N0', $script:Invariant), $pcSize, $cls, (ConvertTo-Html $r.Status), (ConvertTo-Html $how)))
            }
            [void] $h.Append('</table></details>')
        }
        [void] $h.Append('</body></html>')
        [System.IO.File]::WriteAllText($htmlPath, $h.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        Write-Log "check report: $htmlPath"
        return $htmlPath
    }
    catch {
        Write-Log "could not save the check report: $(Get-ErrorText $_)"
        return ''
    }
}

# ---------------------------------------------------------------------------
# compare command: a quick look, nothing copied, nothing read in full
# ---------------------------------------------------------------------------

function Invoke-Compare {
    # For every file in the chosen folders: is a file with the same name and size anywhere in
    # the destination? Uses the lists already read; the content is proven only by the check.
    param([string[]] $Names)
    if (-not $script:Dest) { throw 'Choose where to save first.' }
    Assert-NoOverlap
    Import-Manifest
    Update-DestIndex
    $cache = @{}
    $rows = New-Object System.Collections.ArrayList
    $folders = New-Object System.Collections.ArrayList
    foreach ($name in $Names) {
        $record = $script:Folders[$name]
        if ($null -eq $record) { continue }
        $f = @{ Name = $name; Files = 0; Bytes = [int64] 0; Present = 0; Elsewhere = 0; Missing = 0; MissingBytes = [int64] 0; NameClash = 0 }
        foreach ($e in ($record.Files | Sort-Object { $_.Name })) {
            $f.Files++; $f.Bytes += $e.Size
            $copy = Find-Copy -Entry $e -Cache $cache
            $where = ''; $status = ''
            if ($copy) {
                $f.Present++
                $where = $copy.Path
                $homeDir = (Join-Path $script:Dest $e.Rel).TrimEnd('\')
                if ((Split-Path -Parent $copy.Path).Equals($homeDir, [StringComparison]::OrdinalIgnoreCase)) { $status = 'on the PC' }
                else { $status = 'on the PC, in another folder'; $f.Elsewhere++ }
            }
            else {
                $f.Missing++; $f.MissingBytes += $e.Size
                $status = 'not on the PC'
                $same = $null
                if ($script:DestIndex) { $same = $script:DestIndex[(Get-SafeName $e.Name).ToLowerInvariant()] }
                if ($same) { $status = 'not on the PC (a different file with this name is there)'; $f.NameClash++; $where = $same[0].Path }
            }
            [void] $rows.Add(@{ Folder = $name; Rel = $e.Rel; Name = $e.Name; Size = $e.Size; Date = $(if ($e.Mod) { $e.Mod.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '' }); Status = $status; Where = $where })
        }
        [void] $folders.Add($f)
    }

    $report = ''
    try {
        $meta = Get-MetaDirectory
        New-Item -ItemType Directory -Force -Path $meta | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $csv = New-Object System.Text.StringBuilder
        [void] $csv.AppendLine('folder,name,size_bytes,date,result,found_at')
        foreach ($r in $rows) { [void] $csv.AppendLine((@($r.Rel, $r.Name, $r.Size, $r.Date, $r.Status, $r.Where) | ForEach-Object { ConvertTo-CsvField $_ }) -join ',') }
        [System.IO.File]::WriteAllText((Join-Path $meta "compare-$stamp.csv"), $csv.ToString(), (New-Object System.Text.UTF8Encoding($false)))

        $h = New-Object System.Text.StringBuilder
        [void] $h.Append('<!doctype html><html><head><meta charset="utf-8"><title>iPhone Transfer - compare</title><style>')
        [void] $h.Append('body{font-family:Segoe UI,Arial,sans-serif;margin:32px;color:#0f172a;background:#f8fafc}h1{font-size:24px;margin:0 0 4px}.sub{color:#64748b;margin-bottom:24px}')
        [void] $h.Append('table{border-collapse:collapse;width:100%;background:#fff;margin-bottom:24px}th,td{text-align:left;padding:7px 10px;border-bottom:1px solid #e2e8f0;font-size:13px}th{background:#f1f5f9}')
        [void] $h.Append('.ok{color:#15803d}.away{color:#1d4ed8}.no{color:#b45309;font-weight:600}td.num{text-align:right}details{background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:8px 12px;margin-bottom:10px}summary{cursor:pointer;font-weight:600}</style></head><body>')
        [void] $h.Append('<h1>Compare</h1><div class="sub">' + (ConvertTo-Html ('{0} - {1} compared with {2}. Same name and same size counts as already there; the check proves the content.' -f (Get-Date).ToString('yyyy-MM-dd HH:mm'), $script:Source.Label, $script:Dest)) + '</div>')
        [void] $h.Append('<table><tr><th>Folder</th><th>Files</th><th>Already on the PC</th><th>of these in another folder</th><th>Still to copy</th></tr>')
        foreach ($f in $folders) {
            [void] $h.Append(('<tr><td>{0}</td><td class="num">{1}</td><td class="num">{2}</td><td class="num">{3}</td><td class="num">{4} ({5})</td></tr>' -f (ConvertTo-Html $f.Name), $f.Files, $f.Present, $f.Elsewhere, $f.Missing, (Format-Bytes $f.MissingBytes)))
        }
        [void] $h.Append('</table>')
        foreach ($f in $folders) {
            [void] $h.Append('<details><summary>' + (ConvertTo-Html $f.Name) + (' - {0} files, {1} still to copy' -f $f.Files, $f.Missing) + '</summary><table><tr><th>File</th><th>Size</th><th>Date</th><th>Result</th><th>Found at</th></tr>')
            foreach ($r in ($rows | Where-Object { $_.Folder -eq $f.Name })) {
                $cls = 'ok'
                if ($r.Status -like 'not*') { $cls = 'no' } elseif ($r.Status -like '*another*') { $cls = 'away' }
                [void] $h.Append(('<tr><td>{0}</td><td class="num">{1}</td><td>{2}</td><td class="{3}">{4}</td><td>{5}</td></tr>' -f (ConvertTo-Html $r.Name), ([int64] $r.Size).ToString('N0', $script:Invariant), $r.Date, $cls, (ConvertTo-Html $r.Status), (ConvertTo-Html $r.Where)))
            }
            [void] $h.Append('</table></details>')
        }
        [void] $h.Append('</body></html>')
        $report = Join-Path $meta "compare-$stamp.html"
        [System.IO.File]::WriteAllText($report, $h.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { Write-Log "could not save the compare report: $(Get-ErrorText $_)" }
    Write-Log ("compare: {0} folders, report {1}" -f $folders.Count, $report)
    Send-Event 'CompareDone' @{ Report = $report; Folders = @($folders) }
}

# ---------------------------------------------------------------------------
# delete command
# ---------------------------------------------------------------------------

function Invoke-Delete {
    # Deletes files from the source - only in folders that passed the check, only files that
    # passed it, and only after confirming once more that each copy is still on the PC.
    param([string[]] $Names)
    Assert-NoOverlap
    $allowUndo = ($script:Source.Kind -eq 'Folder')   # an ordinary folder can use the Recycle Bin; a phone cannot
    if ($sync.DemoMode) { $allowUndo = $false }       # the tutorial's made-up photos are not worth a Recycle Bin
    $files = [int64] 0; $bytes = [int64] 0
    foreach ($name in $Names) {
        $v = $script:Verified[$name]
        if ($v -and $v.Deletable -gt 0) { $files += $v.Deletable; foreach ($r in $v.Files.Values) { $bytes += $r.Size } }
    }
    Reset-Progress -Phase 'Delete' -FilesTotal $files -BytesTotal $bytes -Step 'Deleting from the iPhone'

    New-Item -ItemType Directory -Force -Path (Get-MetaDirectory) | Out-Null
    $logPath = Join-Path (Get-MetaDirectory) 'deleted-from-source.csv'
    $isNew = -not (Test-Path -LiteralPath $logPath)
    $writer = New-Object System.IO.StreamWriter($logPath, $true, (New-Object System.Text.UTF8Encoding($false)))
    $writer.AutoFlush = $true
    if ($isNew) { $writer.WriteLine('timestamp,source,folder,name,size_bytes,pc_copy,sha256,result') }

    $totalDeleted = 0; $totalDeletedBytes = [int64] 0; $totalKept = 0; $totalFailed = 0
    try {
        foreach ($name in $Names) {
            Assert-NotCancelled
            $v = $script:Verified[$name]
            if (-not $v -or $v.Deletable -le 0) {
                Write-Log "delete: refused for $name - none of its files passed the check"
                Send-Event 'FolderDeleted' @{ Name = $name; Deleted = 0; DeletedBytes = [int64] 0; Kept = 0; Failed = 0; Refused = $true; Remaining = -1 }
                continue
            }
            $deleted = 0; $deletedBytes = [int64] 0; $kept = 0; $failedHere = 0
            $P.CurrentFolder = $name

            $pass = 0
            $again = $true
            while ($again -and $pass -lt 6) {
            $pass++
            $again = $false
            $kept = 0
            # A fresh listing: anything added since the check is left alone.
            $items = New-Object System.Collections.ArrayList
            $top = $null
            while ($null -eq $top) {
                try { $top = Get-TopFolderItem $name }
                catch {
                    if ($script:Source.Kind -eq 'Device' -and -not (Test-SourceAvailable)) {
                        if (-not (Wait-ForDevice)) { throw (New-Object System.OperationCanceledException) }
                    }
                    else { throw }
                }
            }
            $stack = New-Object System.Collections.Stack
            $stack.Push(@($top.GetFolder, $name))
            while ($stack.Count -gt 0) {
                $pair = $stack.Pop()
                foreach ($item in $pair[0].Items()) {
                    if ($item.IsFolder) { $stack.Push(@($item.GetFolder, (Join-Path $pair[1] $item.Name))); continue }
                    [void] $items.Add(@($item, $pair[1]))
                }
            }

            # Photos to leave alone completely: those with a file that did not pass the check, and
            # those with a file that appeared or changed since (it is not in the checked list).
            $blocked = @{}
            if ($v.Blocked) { foreach ($k in $v.Blocked.Keys) { $blocked[$k] = $true } }
            $nameOf = @{}
            foreach ($pair in $items) {
                $n = Get-RealName $pair[0]
                $nameOf[[string] $pair[0].Path] = $n
                if (-not $v.Files.ContainsKey(($pair[1] + '|' + $n).ToLowerInvariant())) { $blocked[(Get-AssetKey $pair[1] $n)] = $true }
            }

            foreach ($pair in $items) {
                Assert-NotCancelled
                $item = $pair[0]; $rel = $pair[1]
                $fileName = $nameOf[[string] $item.Path]
                if (-not $fileName) { $fileName = Get-RealName $item }
                if ($blocked.ContainsKey((Get-AssetKey $rel $fileName))) { $kept++; continue }   # part of a photo that is not fully on the PC
                $record = $v.Files[($rel + '|' + $fileName).ToLowerInvariant()]
                Set-Current -Name $fileName -Folder $name -Size $record.Size
                if ($null -eq $record) { $kept++; continue }                  # new since the check
                $sizeNow = Get-ItemBytes $item
                if ($sizeNow -ne $record.Size) { $kept++; Write-Log "delete: kept $rel\$fileName - its size changed since the check"; continue }
                $modNow = Get-ItemTimeUtc $item 'System.DateModified'
                if ($record.Mod -and (-not $modNow -or [math]::Abs(($modNow - $record.Mod).TotalSeconds) -gt 2)) { $kept++; Write-Log "delete: kept $rel\$fileName - its date changed since the check"; continue }
                if ($record.Dest -and (Test-BadCopy -Key $(($rel + '|' + $fileName).ToLowerInvariant()) -Path $record.Dest)) { $kept++; Write-Log "delete: kept $rel\$fileName - its copy on the PC failed a later check"; continue }
                $copy = New-Object System.IO.FileInfo($record.Dest)
                if (-not $copy.Exists -or $copy.Length -ne $record.Size) { $kept++; Write-Log "delete: kept $rel\$fileName - the copy on the PC is missing or changed"; continue }
                if ($item.IsFileSystem -and [IPhoneTransferApp.Native]::IsSameFile($item.Path, $record.Dest)) { $kept++; Write-Log "delete: kept $rel\$fileName - its 'copy' is the file itself"; continue }

                # Last proof, where it is cheap: read the source file once more and compare it with
                # the checked fingerprint. Every file of an ordinary folder, and small phone files
                # (edit files, screenshots) whose content can change without the size changing.
                if ($record.Sha -and ($item.IsFileSystem -or $record.Size -le 512KB)) {
                    $same = $false
                    try { $same = ((Read-SourceStream -Entry @{ Item = $item }).Sha -eq $record.Sha) }
                    catch { if (Test-Cancelled $_) { throw } }
                    if (-not $same) { $kept++; Write-Log "delete: kept $rel\$fileName - it no longer matches the checked fingerprint"; continue }
                }

                $result = 'deleted'
                try { [IPhoneTransferApp.Native]::DeleteItem($item, $allowUndo) }
                catch {
                    $result = 'failed: ' + (Get-ErrorText $_)
                    if ($script:Source.Kind -eq 'Device' -and -not (Test-SourceAvailable)) {
                        # The phone dropped out. Wait for it, then read the folder again: the old
                        # handles are no good any more. This file is tried again in the next pass.
                        Write-Log "delete: the source dropped out at $rel\$fileName - waiting, then reading the folder again"
                        if (-not (Wait-ForDevice)) { throw (New-Object System.OperationCanceledException) }
                        Reset-DeviceConnection
                        $again = $true
                        break
                    }
                }
                $writer.WriteLine(((@((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $script:Source.Label, $rel, $fileName, $record.Size, $record.Dest, $record.Sha, $result) | ForEach-Object { ConvertTo-CsvField $_ }) -join ','))
                if ($result -eq 'deleted') { $deleted++; $deletedBytes += $record.Size }
                else { $failedHere++; Write-Log "delete of $rel\$fileName $result" }
                $P.FilesDone = [int64] $P.FilesDone + 1
                $P.BytesDone = [int64] $P.BytesDone + $record.Size
                Update-Progress -Force
            }
            }   # passes

            $remaining = -1
            try { $remaining = (Read-TopFolder $name).Count } catch { }
            $script:Verified.Remove($name)
            $totalDeleted += $deleted; $totalDeletedBytes += $deletedBytes; $totalKept += $kept; $totalFailed += $failedHere
            Write-Log ("delete {0}: {1} deleted ({2}), {3} kept, {4} failed, {5} left in the folder" -f $name, $deleted, (Format-Bytes $deletedBytes), $kept, $failedHere, $remaining)
            Send-Event 'FolderDeleted' @{ Name = $name; Deleted = $deleted; DeletedBytes = $deletedBytes; Kept = $kept; Failed = $failedHere; Refused = $false; Remaining = $remaining }
        }
    }
    finally { $writer.Close() }
    Send-Event 'DeleteDone' @{ Deleted = $totalDeleted; DeletedBytes = $totalDeletedBytes; Kept = $totalKept; Failed = $totalFailed }
}

# ---------------------------------------------------------------------------
# the command loop
# ---------------------------------------------------------------------------

function Invoke-EngineCommand {
    param($Command)
    switch ($Command.Name) {
        'SetSource' {
            if ($Command.Kind -eq 'Folder') {
                $path = (Resolve-Path -LiteralPath $Command.Path).ProviderPath.TrimEnd('\')
                $label = $path
                $names = @(Get-ChildItem -LiteralPath $path -Directory -Force | Where-Object { -not $_.Name.StartsWith('.') } | ForEach-Object { $_.Name } | Sort-Object)
                $looseFiles = @(Get-ChildItem -LiteralPath $path -File -Force -ErrorAction SilentlyContinue).Count
                $parent = Split-Path -Parent $path
                if ($names.Count -eq 0 -and $looseFiles -gt 0 -and $parent) {
                    # The chosen folder holds the photos itself (one month folder, an SD card's
                    # 100APPLE): treat it as the single folder to copy, kept under its own name.
                    $names = @(Split-Path -Leaf $path)
                    $path = $parent
                    $looseFiles = 0
                }
                $script:Source = @{ Kind = 'Folder'; Path = $path; Label = $label }
                $capacity = [IPhoneTransferApp.Native]::GetTotalBytes($path)
                if ($looseFiles -gt 0) { Write-Log "source: $looseFiles files directly in $path are not part of any folder and are left out" }
            }
            else {
                $state = Get-DeviceState
                if ($state.State -ne 'Ready') { throw 'The iPhone is not ready - unlock it and tap Trust.' }
                $script:Source = @{ Kind = 'Device'; Device = $state.Device; Storage = $state.Storage; Label = ('{0}\{1}' -f $state.Device, $state.Storage) }
                $names = $state.Folders
                $looseFiles = 0
                $capacity = $state.Capacity
            }
            $script:Folders = @{}
            $script:Verified = @{}
            Write-Log "source: $($script:Source.Label) ($($names.Count) folders)"
            Send-Event 'FolderList' @{ Names = [string[]] $names; Label = $script:Source.Label; Kind = $script:Source.Kind; Capacity = $capacity; LooseFiles = $looseFiles }
        }
        'SetDestination' { Set-Destination $Command.Path }
        'Scan'           { Invoke-Scan -Names $Command.Folders }
        'Copy'           { Invoke-Copy -Names $Command.Folders }
        'Verify'         { Invoke-Verify -Names $Command.Folders -Full ([bool] $Command.Full) }
        'Compare'        { Invoke-Compare -Names $Command.Folders }
        'Delete'         { Invoke-Delete -Names $Command.Folders }
        default          { throw "Unknown command $($Command.Name)" }
    }
}

function Start-Engine {
    try {
        if ($sync.LogPath) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sync.LogPath) | Out-Null
            $script:Log = New-Object System.IO.StreamWriter($sync.LogPath, $true, (New-Object System.Text.UTF8Encoding($false)))
            $script:Log.AutoFlush = $true
        }
        Write-Log 'engine started'
        Send-Event 'EngineReady'
        $lastPoll = [DateTime]::MinValue
        while (-not $sync.Quit) {
            $line = $null
            while ($sync.UiLog.TryDequeue([ref] $line)) { Write-Log "window: $line" }

            if ($sync.NewDest -and -not $sync.Busy) { Use-PendingDestination }

            $command = $null
            if ($sync.Commands.TryDequeue([ref] $command)) {
                $sync.Cancel = $false
                $sync.Pause = $false
                $sync.Busy = $true
                Write-Log ("command: {0} {1}" -f $command.Name, (@($command.Folders) -join ','))
                try { Invoke-EngineCommand $command }
                catch {
                    if (Test-Cancelled $_) {
                        Write-Log "command $($command.Name) stopped by the user"
                        Send-Event 'Cancelled' @{ Command = $command.Name }
                    }
                    else {
                        $text = Get-ErrorText $_
                        Write-Log "command $($command.Name) failed: $text`r`n$($_.ScriptStackTrace)"
                        Send-Event 'Error' @{ Command = $command.Name; Message = $text }
                    }
                }
                finally {
                    $sync.Busy = $false
                    $P.Phase = ''
                    Close-Manifest
                }
                $lastPoll = [DateTime]::MinValue
                continue
            }

            if ($sync.Watch -and ([DateTime]::UtcNow - $lastPoll).TotalSeconds -ge 2.5) {
                $lastPoll = [DateTime]::UtcNow
                Update-DeviceWatch
            }
            Start-Sleep -Milliseconds 150
        }
    }
    catch {
        Write-Log "engine stopped unexpectedly: $(Get-ErrorText $_)`r`n$($_.ScriptStackTrace)"
        Send-Event 'EngineCrashed' @{ Message = (Get-ErrorText $_) }
    }
    finally {
        try { [IPhoneTransferApp.Native]::KeepAwake($false) } catch { }
        Close-Manifest
        Write-Log 'engine stopped'
        if ($script:Log) { try { $script:Log.Close() } catch { } }
    }
}
