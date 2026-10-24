<#
.SYNOPSIS
    Copies iPhone media files (.MOV, .JPG, .HEIC, .PNG, .MP4 by default) to a folder on the PC.

.DESCRIPTION
    An iPhone connected by cable appears as an MTP device: it has no drive letter,
    so cp / robocopy / Get-ChildItem cannot read it. This script talks to the same
    Windows shell interface Explorer uses, so it can walk the device directly.

    The source may be a device path ("This PC\Apple iPhone\Internal Storage\202406_a")
    or an ordinary folder ("E:\DCIM") - both work.

.EXAMPLE
    .\Copy-IPhoneMedia.ps1 "This PC\Apple iPhone\Internal Storage\202406_a" "D:\Photos"

.EXAMPLE
    .\Copy-IPhoneMedia.ps1 "This PC\Apple iPhone\Internal Storage" "D:\Photos" -Folders "2024*"

.EXAMPLE
    .\Copy-IPhoneMedia.ps1 "This PC\Apple iPhone\Internal Storage" "D:\Photos" -DryRun
#>

[CmdletBinding()]
param(
    # Leave Source and Destination out to be asked for them step by step.
    [Parameter(Position = 0)]
    [string] $Source = '',

    [Parameter(Position = 1)]
    [string] $Destination = '',

    # File types to copy.
    [string[]] $Extensions = @('.MOV', '.JPG', '.HEIC', '.PNG', '.MP4'),

    # Which first-level sub-folders to enter, e.g. "2024*". Default: all of them.
    [string] $Folders = '*',

    # Put every file straight into the destination instead of recreating 202406_a\...
    [switch] $Flat,

    # Re-copy files that exist with a different size (default: keep both as name_1.ext).
    [switch] $Overwrite,

    # List what would be copied without copying anything.
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

$NO_PROGRESS_DIALOG = 4
$YES_TO_ALL         = 16
$THIS_PC            = 17
$COPY_FLAGS         = $NO_PROGRESS_DIALOG -bor $YES_TO_ALL
$COPY_TIMEOUT_SEC   = 600   # a single 4K video can take a while over USB

$Shell = New-Object -ComObject Shell.Application

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

function Resolve-DeviceFolder {
    param([string] $Path)

    $parts = @($Path -split '[\\/]+' | Where-Object { $_ -ne '' })
    if ($parts.Count -gt 0 -and @('this pc', 'computer', 'my computer') -contains $parts[0].ToLower()) {
        if ($parts.Count -gt 1) { $parts = $parts[1..($parts.Count - 1)] } else { $parts = @() }
    }

    $folder = $Shell.NameSpace($THIS_PC)
    $walked = 'This PC'

    foreach ($part in $parts) {
        $next = $null
        foreach ($item in $folder.Items()) {
            if ($item.IsFolder -and $item.Name -eq $part) { $next = $item.GetFolder; break }
        }
        if ($null -eq $next) {
            $available = ($folder.Items() | Where-Object { $_.IsFolder } | ForEach-Object { $_.Name }) -join ', '
            throw "'$part' not found under $walked.`nAvailable: $available`nIs the phone unlocked and 'Trust This Computer' accepted?"
        }
        $folder = $next
        $walked = "$walked\$part"
    }
    return $folder
}

function Get-MediaItems {
    param($Folder, [string] $Relative = '', [bool] $Top = $true)

    $found = @()
    foreach ($item in $Folder.Items()) {
        if ($item.IsFolder) {
            if ($Top -and $item.Name -notlike $Folders) { continue }
            if ($Relative) { $childRelative = Join-Path $Relative $item.Name }
            else           { $childRelative = $item.Name }

            # Reading a folder off a phone takes a moment, so say which one we are on
            # rather than sitting silent until every folder has been read.
            if ($Top) { Write-Host ("  {0,-12} " -f $item.Name) -NoNewline }

            $fromChild = @(Get-MediaItems -Folder $item.GetFolder -Relative $childRelative -Top $false)

            if ($Top) { Write-Host "$($fromChild.Count) file(s)" }

            # A folder that matched the pattern but holds nothing is worth calling out:
            # on a phone using iCloud those photos live in the cloud, not on the device.
            if ($Top -and $fromChild.Count -eq 0) { $script:EmptyMatches += $item.Name }

            $found += $fromChild
        }
        else {
            $extension = [System.IO.Path]::GetExtension($item.Name).ToLower()
            if ($Wanted -contains $extension) {
                $found += [pscustomobject]@{ Relative = $Relative; Item = $item; Folder = $Folder }
            }
        }
    }
    return $found
}

function Get-ItemSize {
    param($Item)
    try { return [int64] $Item.Size } catch { return 0 }   # MTP always reports 0
}

function Get-SizeLabel {
    # A device reports no byte count, but the shell still shows a rounded size
    # ("989 KB") in its details column, which is good enough to print.
    param($Folder, $Item, [int64] $ExactSize)

    if ($ExactSize -gt 0) { return Format-Size $ExactSize }

    if ($null -eq $script:SizeColumn) {
        $script:SizeColumn = -1
        foreach ($column in 0..40) {
            if ($Folder.GetDetailsOf($null, $column) -eq 'Size') { $script:SizeColumn = $column; break }
        }
    }
    if ($script:SizeColumn -ge 0) { return $Folder.GetDetailsOf($Item, $script:SizeColumn) }
    return ''
}

function Get-FreeName {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $Path }

    $directory = Split-Path -Path $Path -Parent
    $base      = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $extension = [System.IO.Path]::GetExtension($Path)

    $counter = 1
    while ($true) {
        $candidate = Join-Path $directory "${base}_$counter$extension"
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $counter++
    }
}

function Find-ExistingCopy {
    # Is this file already here, either under its own name or as a name_1 /
    # name_2 sibling from an earlier run? Needs a real byte count to tell.
    param([string] $Path, [int64] $Size)

    if ($Size -le 0) { return $null }

    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) { return $null }

    $base    = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $pattern = '^' + [regex]::Escape($base) + '(_\d+)?$'

    $siblings = Get-ChildItem -LiteralPath $directory -File -Filter "$base*" -ErrorAction SilentlyContinue
    foreach ($candidate in $siblings) {
        if ($candidate.BaseName -match $pattern -and $candidate.Length -eq $Size) {
            return $candidate.FullName
        }
    }
    return $null
}

function Wait-ForFile {
    # CopyHere is asynchronous. The shell holds the file open until it has finished
    # writing, so ask for it exclusively - the moment we get the handle, it is done.
    param([string] $Path, [int] $TimeoutSeconds = 600)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            try {
                $stream = [System.IO.File]::Open($Path, 'Open', 'Write', 'None')
                $stream.Close()
                return $true
            }
            catch { }   # still being written to
        }
        Start-Sleep -Milliseconds 25
    }
    return $false
}

function Format-Size {
    param([double] $Bytes)
    foreach ($unit in 'B', 'KB', 'MB', 'GB') {
        if ($Bytes -lt 1024) { return ('{0:N1} {1}' -f $Bytes, $unit) }
        $Bytes = $Bytes / 1024
    }
    return ('{0:N1} TB' -f $Bytes)
}

# ---------------------------------------------------------------------------
# asking the user, when the script is started without arguments
# ---------------------------------------------------------------------------

function Read-Answer {
    param([string] $Question, [string] $Default)

    if ($Default) { $answer = Read-Host "$Question [$Default]" }
    else          { $answer = Read-Host $Question }

    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Write-InColumns {
    param([string[]] $Items, [int] $PerRow = 5)

    $width = 2 + ($Items | Measure-Object -Property Length -Maximum).Maximum

    for ($i = 0; $i -lt $Items.Count; $i += $PerRow) {
        $row = $Items[$i..([math]::Min($i + $PerRow - 1, $Items.Count - 1))]
        Write-Host ('  ' + (($row | ForEach-Object { $_.PadRight($width) }) -join '')).TrimEnd()
    }
}

function Select-Device {
    # Pick the phone out of This PC, or let the user choose if we cannot spot it.
    while ($true) {
        $thisPc  = $Shell.NameSpace($THIS_PC)
        $entries = @($thisPc.Items() | Where-Object { $_.IsFolder })
        $phone   = $entries | Where-Object { $_.Name -match 'iPhone|iPad|Apple' } | Select-Object -First 1

        if ($phone) {
            Write-Host "Found device: $($phone.Name)"
            return $phone
        }

        Write-Host 'No iPhone found. Check that it is plugged in and unlocked, and that'
        Write-Host 'you tapped "Trust This Computer" on the phone itself.'
        Write-Host ''
        Write-Host 'Everything currently under This PC:'
        for ($i = 0; $i -lt $entries.Count; $i++) {
            Write-Host "  [$($i + 1)] $($entries[$i].Name)"
        }
        Write-Host ''

        $answer = Read-Answer 'Enter a number, r to look again, or q to quit' 'r'
        if ($answer -match '^q') { Write-Host 'Nothing copied.'; exit }
        if ($answer -match '^r') { Write-Host ''; continue }

        $number = 0
        if ([int]::TryParse($answer, [ref] $number) -and
            $number -ge 1 -and $number -le $entries.Count) {
            return $entries[$number - 1]
        }

        Write-Host "'$answer' is not one of the choices."
        Write-Host ''
    }
}

function Start-Interactive {
    Write-Host ''
    Write-Host '--- Copy media off an iPhone ---'
    Write-Host ''

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

    if ($inside.Count -gt 0) {
        $names = @($inside | ForEach-Object { $_.Name } | Sort-Object)
        Write-Host ''
        Write-Host "Folders found ($($names.Count)) - a phone names them by year and month:"
        Write-InColumns -Items $names
        Write-Host ''
        $script:Folders = Read-Answer 'Which folders (* for all, or a pattern like 2026*)' '*'
    }

    Write-Host ''
    $suggested = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'iPhone'
    $script:Destination = Read-Answer 'Copy them to' $suggested

    $answer = Read-Answer 'File types to copy' ($Extensions -join ',')
    $script:Extensions = @($answer -split '[,\s]+' | Where-Object { $_ })

    $script:Source = "This PC\$path"

    Write-Host ''
    Write-Host "  from   This PC\$path   (folders: $script:Folders)"
    Write-Host "  to     $script:Destination"
    Write-Host "  types  $($script:Extensions -join ', ')"
    Write-Host ''

    if ((Read-Answer 'Start copying? (y/n)' 'y') -notmatch '^y') {
        Write-Host 'Nothing copied.'
        exit
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

if (-not $Source -or -not $Destination) { Start-Interactive }

# Worked out here rather than at the top, because the questions above can change it.
$Wanted = $Extensions | ForEach-Object {
    if ($_.StartsWith('.')) { $_.ToLower() } else { '.' + $_.ToLower() }
}

$Destination = (New-Item -ItemType Directory -Force -Path $Destination).FullName

if (Test-Path -LiteralPath $Source -PathType Container) {
    $sourceFolder = $Shell.NameSpace((Resolve-Path -LiteralPath $Source).Path)
}
else {
    Write-Host "Opening device: $Source"
    $sourceFolder = Resolve-DeviceFolder -Path $Source
}

Write-Host 'Reading file list (this can take a moment on a device)...'
$script:EmptyMatches = @()
$files = @(Get-MediaItems -Folder $sourceFolder)

if ($EmptyMatches.Count -gt 0) {
    Write-Host ''
    Write-Host "Note: $($EmptyMatches.Count) folder(s) matched '$Folders' but listed no files:"
    Write-Host "      $($EmptyMatches -join ', ')"
    Write-Host '      The phone often reports a folder as empty on first access and fills it in'
    Write-Host '      on a later read, so run the script again - already-copied files are skipped.'
    Write-Host '      Only if they stay empty across runs are those photos genuinely off the device'
    Write-Host '      (in iCloud - see Settings > Photos > Download and Keep Originals).'
}

if ($files.Count -eq 0) {
    Write-Host ''
    Write-Host "No $($Extensions -join ', ') files found in $Source"
    return
}

Write-Host ''
Write-Host "Found $($files.Count) file(s)`n"

$copied      = 0
$copiedBytes = 0
$skipped     = 0
$failed      = 0
$index       = 0

foreach ($entry in $files) {
    $index++
    $item = $entry.Item
    $size = Get-ItemSize -Item $item

    if ($Flat -or -not $entry.Relative) { $targetDirectory = $Destination }
    else { $targetDirectory = Join-Path $Destination $entry.Relative }

    $landing = Join-Path $targetDirectory $item.Name
    $useTemp = $false

    $existing = Find-ExistingCopy -Path $landing -Size $size
    if ($existing) {
        Write-Host "[$index/$($files.Count)] skip (already there) $($item.Name)"
        $skipped++
        continue
    }

    if (Test-Path -LiteralPath $landing) {
        # A device gives no byte count, so there the name alone has to decide.
        if ($size -eq 0) {
            Write-Host "[$index/$($files.Count)] skip (already there) $($item.Name)"
            $skipped++
            continue
        }
        # Same name, different file: keep both unless -Overwrite was passed.
        if (-not $Overwrite) { $useTemp = $true }
    }

    $sizeLabel = Get-SizeLabel -Folder $entry.Folder -Item $item -ExactSize $size
    if ($sizeLabel) { $label = " ($sizeLabel)" } else { $label = '' }
    Write-Host "[$index/$($files.Count)] $($item.Name) -> $landing$label"

    if ($DryRun) { continue }

    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null

    # The shell always copies under the original name, so when we need a different
    # one we copy into a staging folder first and rename on the way out.
    if ($useTemp) {
        $stagingDirectory = Join-Path $targetDirectory '.copy-staging'
        New-Item -ItemType Directory -Force -Path $stagingDirectory | Out-Null
        $arrival = Join-Path $stagingDirectory $item.Name
        $target  = $stagingDirectory
    }
    else {
        $arrival = $landing
        $target  = $targetDirectory
    }

    $targetNamespace = $Shell.NameSpace($target)
    if ($null -eq $targetNamespace) {
        Write-Host "    failed: cannot open destination $target"
        $failed++
        continue
    }

    $targetNamespace.CopyHere($item, $COPY_FLAGS)

    if (-not (Wait-ForFile -Path $arrival -TimeoutSeconds $COPY_TIMEOUT_SEC)) {
        Write-Host '    failed: file never arrived (timed out)'
        $failed++
        continue
    }

    if ($useTemp) {
        $finalPath = Get-FreeName -Path $landing
        Move-Item -LiteralPath $arrival -Destination $finalPath
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
        Write-Host "    saved as $(Split-Path $finalPath -Leaf)"
    }
    else {
        $finalPath = $landing
    }

    $copied++
    $copiedBytes += (Get-Item -LiteralPath $finalPath).Length
}

Write-Host ''
if ($DryRun) {
    Write-Host "Dry run: $($files.Count - $skipped) file(s) would be copied, $skipped skipped"
}
else {
    Write-Host "Copied $copied file(s) ($(Format-Size $copiedBytes)), skipped $skipped, failed $failed"
}
