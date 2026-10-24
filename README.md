# iPhone Media Transfer

A PowerShell script that copies photos and videos off a cabled iPhone into a folder on your PC.

No iTunes sync, no cloud upload, no third-party transfer tool. Files are copied byte-for-byte — nothing is re-encoded, and original capture dates are preserved.

## Features

- Copies `.MOV`, `.JPG`, `.HEIC`, `.PNG` and `.MP4` — photos, videos and screenshots (any extensions you like)
- Pick which month folders to pull with a wildcard, e.g. `2026*`
- Keeps the phone's folder structure, or flattens it
- **Resumable** — already-copied files are skipped, so an interrupted transfer picks up where it stopped
- Never silently overwrites: a same-named but different file is saved alongside as `IMG_1234_1.JPG`
- `-DryRun` shows exactly what would be copied before anything is written
- Around 25 MB/s over USB (roughly 900 MB per minute)

## Requirements

### 1. Apple drivers — install this first

**➡️ [Apple Devices (Microsoft Store)](https://apps.microsoft.com/detail/9np83lwlpz9k?hl=en-US&gl=BG)**

This is Apple's official Windows app, and it is the only prerequisite you actually have to install.

**Why you need it:** Windows cannot talk to an iPhone on its own. Plug a phone into a fresh Windows install and you get a charging cable and nothing else — no drive, no folders, nothing in File Explorer. Installing Apple Devices adds the *Apple Mobile Device Support* drivers, which is what makes your iPhone appear under **This PC** with its photo folders visible. The script reads those folders, so without the drivers it has nothing to work with.

**You do not have to open the app, create an Apple account, or sign into anything.** Installing it is enough — the drivers register themselves. If you already have iTunes or Apple Devices installed, you are ready to go.

### 2. Windows

Windows 10 or 11 with PowerShell, which is preinstalled. Nothing else to set up.

> [!IMPORTANT]
> A connected iPhone is an MTP device: it has no drive letter and exists only inside Windows Explorer's namespace. WSL never sees the USB device, so `cp`, `rsync` and `find` have nothing to open. The included `copy_iphone_media.sh` is a bash equivalent, but it only works on ordinary folders (a mounted drive, an SD card, an already-imported folder) — never on the phone itself.

### 3. The phone, unlocked and trusted

Connect the cable, unlock the screen, and tap **Trust This Computer** when the phone asks. A locked or untrusted phone shows up as empty.

## Installation

Clone the repo, or just download `Copy-IPhoneMedia.ps1` — it is a single self-contained file with no dependencies.

```bash
git clone https://github.com/kyuchukovv/iphone-media-transfer.git
```

> [!NOTE]
> If you download the file directly, check the saved filename. Some browsers strip hyphens and save it as `CopyIPhoneMedia.ps1`. Use whatever name is actually on disk, or rename it back.

## Finding your phone's path

Open File Explorer and look under **This PC**. Your iPhone appears as a device, and the path looks like this:

```
This PC\Apple iPhone\Internal Storage\202607_a
```

Folders are named by year and month, so `202607_a` is July 2026. Pass either a single month folder or `Internal Storage` itself with a `-Folders` filter.

## Quick start — no command line

**Double-click `run.cmd`.** It finds your iPhone, shows what is on it, and asks where to put the files. Nothing to type but answers.

```text
--- Copy media off an iPhone ---

Found device: Apple iPhone

Folders found (43) - a phone names them by year and month:
  201709_a   201711_a   202007_a   202303_a   202308_a
  202309_a   202311_a   202312_a   202401_a   202402_a
  ...

Which folders (* for all, or a pattern like 2026*) [*]: 2026*
Copy them to [C:\Users\you\Pictures\iPhone]:
File types to copy [.MOV,.JPG,.HEIC,.PNG,.MP4]:

  from   This PC\Apple iPhone\Internal Storage   (folders: 2026*)
  to     C:\Users\you\Pictures\iPhone
  types  .MOV, .JPG, .HEIC, .PNG, .MP4

Start copying? (y/n) [y]:
```

Press Enter to accept any suggestion in brackets. Answer `n` at the end and nothing is written.

If the phone is not found, the script lists what it can see and lets you look again with `r` once you have unlocked the phone and tapped Trust — no need to start over.

## Usage from the command line

Everything can also be passed as arguments, which skips all the questions — useful for repeat or scheduled runs.

Open a normal PowerShell window (no administrator rights needed) and `cd` to the folder holding the script.

**Copy one month:**

```powershell
powershell -ExecutionPolicy Bypass -File Copy-IPhoneMedia.ps1 "This PC\Apple iPhone\Internal Storage\202607_a" "D:\Photos"
```

**Copy everything from 2026, keeping the month folders:**

```powershell
powershell -ExecutionPolicy Bypass -File Copy-IPhoneMedia.ps1 "This PC\Apple iPhone\Internal Storage" "D:\Photos" -Folders "2026*"
```

**Preview first, copy nothing:**

```powershell
powershell -ExecutionPolicy Bypass -File Copy-IPhoneMedia.ps1 "This PC\Apple iPhone\Internal Storage" "D:\Photos" -Folders "2026*" -DryRun
```

**Videos only, all into one folder:**

```powershell
powershell -ExecutionPolicy Bypass -File Copy-IPhoneMedia.ps1 "This PC\Apple iPhone\Internal Storage" "D:\Videos" -Extensions .MOV -Flat
```

**Example output:**
```
Copied 1158 file(s) (11.6 GB), skipped 457, failed 0
```
> [!NOTE]
> **Why `-ExecutionPolicy Bypass`?** Windows refuses to run unsigned `.ps1` files by default. This flag lifts that for the single command you are running and changes nothing system-wide.

## Options

| Option | Description | Default |
| --- | --- | --- |
| `-Extensions` | File types to copy | `.MOV, .JPG, .HEIC, .PNG, .MP4` |
| `-Folders` | Wildcard for which sub-folders to enter | `*` (all) |
| `-Flat` | Put every file directly in the destination, no sub-folders | off |
| `-Overwrite` | Replace a same-named file instead of keeping both | off |
| `-DryRun` | List what would be copied without copying | off |

## Things worth knowing

**A folder that reports no files usually just needs another run.** The phone often lists a month folder as empty on first access and fills it in on a later read. This is a quirk of how iPhones expose storage over USB, not a failure. Run the script again — copied files are skipped, so a re-run only costs the ones that were missed.

If a folder stays empty across several runs, those photos genuinely are not on the device. That is iCloud's **Optimize iPhone Storage** keeping originals in the cloud. Switch to *Settings → Photos → Download and Keep Originals* and let the phone sync before copying.

**Two files per edited photo.** `IMG_1234.JPG` is the untouched original and `IMG_E1234.JPG` is your edited version. Both get copied, so you keep the original — which is why the file count is higher than the number of photos in your camera roll.

**Screenshots are PNG.** iPhone screenshots are saved as `.PNG`, not `.JPG`, and some clips save as `.MP4` rather than `.MOV` — both are included by default so nothing is quietly left behind.

**`.AAE` files are skipped on purpose.** These sit next to edited photos and contain only the edit instructions (crop, filter, adjustments). They are useless outside Apple's Photos app, and the edited image itself already comes across as `IMG_E1234.JPG`, so there is nothing to lose by ignoring them.

**Quality is never reduced.** The script performs a binary copy and has no decoder in the path. If you want to be certain your HEIC files stay HEIC, check *Settings → Photos → Transfer to Mac or PC* is set to **Keep Originals**; on *Automatic* the phone itself converts to JPEG during transfer, before the script ever sees the file.

## Troubleshooting

| Message or symptom | Cause and fix |
| --- | --- |
| `'Apple iPhone' not found under This PC` | Drivers not installed, phone locked, or Trust not accepted. The script prints the device names it did find so you can compare. |
| `The argument ... does not exist` | Wrong filename — check whether your browser saved it as `CopyIPhoneMedia.ps1`. |
| `... cannot be loaded because running scripts is disabled` | You left off `-ExecutionPolicy Bypass`. |
| Folder is found but no files listed | Normal on a first read. Run it again — see above. |
| Files arrive as `.JPG` when you expected `.HEIC` | Phone is converting on transfer. Set *Transfer to Mac or PC* to **Keep Originals**. |
| Transfer is slow | Use a USB 3 port and Apple's own cable; cheap cables often negotiate USB 2 speeds. |

