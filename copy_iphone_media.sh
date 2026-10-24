#!/usr/bin/env bash
#
# copy_iphone_media.sh - copy photos and videos (.MOV, .JPG, .HEIC, .PNG, .MP4 by default)
# from a source folder to a destination folder: safely, resumably, with live progress.
#
# Bash companion of Copy-IPhoneMedia.ps1, with the same phases and guarantees:
#   SOURCE -> SCAN (live progress, scan report) -> DESTINATION (writable? free space?)
#   -> PLAN (already there? name taken?) -> COPY (staging + size/SHA-256 verification +
#   atomic move; retries; one bad file never stops the run; Ctrl+C cleans up) -> SUMMARY.
#
# NOTE: this only works when the source is a real filesystem path - a mounted
# drive, an SD card, or a folder already copied off the phone. A cabled iPhone
# shows up as an MTP device ("This PC\Apple iPhone\Internal Storage"), which
# has no filesystem path; use Copy-IPhoneMedia.ps1 for that.
#
# Needs bash 4.2 or newer (macOS ships 3.2: "brew install bash"). Everything else is
# plain coreutils/findutils, GNU or BSD flavour: find, stat, df, dd, tee, mv, touch,
# sort, and sha256sum or shasum (or openssl). Nothing else; pv is not used.
#
# Usage:
#   ./copy_iphone_media.sh SOURCE [DESTINATION] [options]
#
#   DESTINATION defaults to ~/Pictures/iPhone (you are asked when running interactively).
#
#   -e "mov jpg heic"   extensions to copy (default: mov jpg heic png mp4; '*' = everything)
#   -f "2024*"          which sub-folders to enter (default: all; repeat -f for more patterns)
#   -F                  flat: no sub-folders in the destination
#   -o                  overwrite a same-named file of a different size (default: keep both, as name_1.ext)
#   -n                  dry run: scan, plan and list what would be copied; copy nothing
#   -s                  scan only: print and save the scan report, then stop
#   -H                  record the SHA-256 of every copied file in the manifest
#   -V                  skip the re-read verification of each staged copy (the size is always checked)
#   -r N                retries per file after a failure (default: 3)
#   -y                  no questions (and refuse, instead of asking, when free space is short)
#   -L DIR              put the log, manifest and scan report in DIR
#                       (default: DESTINATION/.iphone-transfer; staging always stays in DESTINATION)
#   -h                  this help
#
# Examples:
#   ./copy_iphone_media.sh /mnt/e/DCIM ~/Photos/iphone -f "2024*"
#   ./copy_iphone_media.sh /Volumes/SDCARD/DCIM -s
#
# Files under DESTINATION/.iphone-transfer/ (or -L DIR):
#   transfer-<stamp>.log   everything printed, plus details
#   manifest.csv           one row per file attempt, appended across runs
#   scan-<stamp>.txt       the scan report
#   staging/               partial files while copying; empty after a clean run
#
# Exit codes: 0 all good, 1 fatal (bad arguments, source missing, destination unusable),
#             2 some files failed (listed in the summary), 3 interrupted (Ctrl+C).
#
# Environment: IPHONE_TRANSFER_BLOCK_SIZE=<bytes> sets the dd block size (default 4 MiB);
#              the tests use a tiny value to slow copies down.

set -euo pipefail

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
    echo "copy_iphone_media.sh needs bash 4.2 or newer (this is bash $BASH_VERSION)" >&2
    exit 1
fi

# --- settings (defaults; options override them) ------------------------------

extensions="mov jpg heic png mp4"
folder_patterns=()          # -f, repeatable; empty means every folder
flat=false
overwrite=false
dry_run=false
scan_only=false
record_hash=false
verify=true
retries=3
assume_yes=false
log_dir_opt=""

PHOTO_EXTS="jpg jpeg heic heif png gif tif tiff dng webp bmp cr2 nef arw raw"
VIDEO_EXTS="mov mp4 m4v avi 3gp mkv mts"
BLOCK_SIZE=${IPHONE_TRANSFER_BLOCK_SIZE:-4194304}   # dd block size in bytes
POLL_INTERVAL=0.25          # seconds between per-file progress refreshes (never more than ~5/s)
RATE_WINDOW_MS=5000         # sliding window for the throughput figure
BIG_FILE=4194304            # files at least this big get a live per-file progress line
SPACE_MARGIN=67108864       # 64 MB of free space kept in reserve
RECONNECT_WAIT=120          # seconds to wait for a vanished source folder to come back
LABEL_WIDTH=48              # width of the folder/name column in per-file lines

# --- arguments ---------------------------------------------------------------

usage() {
    sed -n '3,/^set -euo pipefail/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit "${1:-0}"
}

positional=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e) [[ $# -ge 2 ]] || usage 1; extensions="$2";         shift 2 ;;
        -f) [[ $# -ge 2 ]] || usage 1; folder_patterns+=("$2"); shift 2 ;;
        -F) flat=true;        shift ;;
        -o) overwrite=true;   shift ;;
        -n) dry_run=true;     shift ;;
        -s) scan_only=true;   shift ;;
        -H) record_hash=true; shift ;;
        -V) verify=false;     shift ;;
        -r) [[ $# -ge 2 ]] || usage 1; retries="$2";            shift 2 ;;
        -y) assume_yes=true;  shift ;;
        -L) [[ $# -ge 2 ]] || usage 1; log_dir_opt="$2";        shift 2 ;;
        -h|--help) usage 0 ;;
        --) shift; while [[ $# -gt 0 ]]; do positional+=("$1"); shift; done ;;
        -*) echo "Unknown option: $1" >&2; usage 1 ;;
        *)  positional+=("$1"); shift ;;
    esac
done

if (( ${#positional[@]} < 1 || ${#positional[@]} > 2 )); then
    usage 1
fi
if ! [[ $retries =~ ^[0-9]+$ ]]; then
    echo "-r needs a whole number, got: $retries" >&2
    exit 1
fi
if ! [[ $BLOCK_SIZE =~ ^[1-9][0-9]*$ ]]; then
    echo "IPHONE_TRANSFER_BLOCK_SIZE must be a positive number of bytes" >&2
    exit 1
fi
if (( ${#folder_patterns[@]} == 0 )); then
    folder_patterns=("*")
fi

source_arg=${positional[0]%/}
[[ -z $source_arg ]] && source_arg=/
dest_arg=""
if (( ${#positional[@]} == 2 )); then
    dest_arg=${positional[1]%/}
    [[ -z $dest_arg ]] && dest_arg=/
fi

# Extension sets: wanted (from -e), and photo/video for the scan report.
declare -A WANT_EXT=() PHOTO_EXT=() VIDEO_EXT=()
ALL_EXTS=false
read -r -a ext_words <<< "${extensions//,/ }"
for e in ${ext_words[@]+"${ext_words[@]}"}; do
    e=${e#.}
    e=${e,,}
    [[ -z $e ]] && continue
    if [[ $e == '*' ]]; then ALL_EXTS=true; else WANT_EXT[$e]=1; fi
done
read -r -a kind_words <<< "$PHOTO_EXTS"
for e in "${kind_words[@]}"; do PHOTO_EXT[$e]=1; done
read -r -a kind_words <<< "$VIDEO_EXTS"
for e in "${kind_words[@]}"; do VIDEO_EXT[$e]=1; done
unset e ext_words kind_words

# --- output: everything said also goes to the log (once it exists) -----------

LOG_FILE=""
LOG_BUFFER=()

log() {                             # log file only
    if [[ -n $LOG_FILE ]]; then
        printf '%s\n' "$*" >> "$LOG_FILE"
    else
        LOG_BUFFER+=("$*")
    fi
    return 0
}

say() {                             # console and log
    printf '%s\n' "$*"
    log "$*"
    return 0
}

die() {                             # fatal: message, exit 1 (the EXIT trap cleans up)
    printf 'error: %s\n' "$*" >&2
    log "error: $*"
    exit 1
}

open_log() {                        # $1 log file; flushes what was said before the log existed
    local line
    LOG_FILE=$1
    {
        for line in ${LOG_BUFFER[@]+"${LOG_BUFFER[@]}"}; do
            printf '%s\n' "$line"
        done
    } >> "$LOG_FILE"
    LOG_BUFFER=()
    return 0
}

phase() {                           # section banner
    local pad
    printf -v pad '%*s' $(( 70 - ${#1} )) ''
    say ""
    say "--- $1 ${pad// /-}"
    return 0
}

IS_TTY=false
if [[ -t 1 || ${IPHONE_TRANSFER_TTY:-0} == 1 ]]; then IS_TTY=true; fi   # the variable is for tests
TERM_WIDTH=""
if [[ -t 1 ]]; then TERM_WIDTH=$(tput cols 2>/dev/null) || TERM_WIDTH=""; fi
[[ $TERM_WIDTH =~ ^[0-9]+$ ]] && (( TERM_WIDTH >= 40 )) || TERM_WIDTH=${COLUMNS:-100}
[[ $TERM_WIDTH =~ ^[0-9]+$ ]] && (( TERM_WIDTH >= 40 )) || TERM_WIDTH=100
INTERACTIVE=false
if [[ -t 0 ]] && ! $assume_yes; then INTERACTIVE=true; fi

clear_progress() {                  # wipe the \r progress line (tty only)
    if $IS_TTY; then printf '\r%*s\r' "$((TERM_WIDTH - 1))" ''; fi
    return 0
}

set_title() {                       # console window title (tty only)
    if $IS_TTY && [[ ${TERM:-dumb} != dumb ]]; then printf '\033]0;%s\007' "$1"; fi
    return 0
}

ask_yes_no() {                      # $1 question  $2 default (y|n); true when the answer is yes
    local prompt answer
    if [[ $2 == y ]]; then prompt="$1 [Y/n] "; else prompt="$1 [y/N] "; fi
    read -r -p "$prompt" answer || answer=""
    log "$prompt$answer"
    (( INTERRUPTED )) && return 1
    [[ -z $answer ]] && answer=$2
    [[ ${answer,,} == y* ]]
}

# --- formatting helpers (no sub-processes: they are used from progress loops) -

hs() {                              # bytes -> "12.3 MB"; sets HS
    local b=$1 unit div t
    if (( b < 0 )); then HS="?"; return 0; fi
    if (( b >= 1073741824 )); then unit=GB; div=1073741824
    elif (( b >= 1048576 )); then unit=MB; div=1048576
    elif (( b >= 1024 )); then unit=KB; div=1024
    else HS="$b B"; return 0
    fi
    t=$(( b * 10 / div ))
    HS="$(( t / 10 )).$(( t % 10 )) $unit"
    return 0
}

hs2() {                             # bytes A, B -> "2.6/20.0 MB" (same unit) or "900.0 KB/20.0 MB"; sets HS2
    hs "$1"; local a=$HS
    hs "$2"
    if [[ ${a##* } == "${HS##* }" ]]; then HS2="${a% *}/$HS"; else HS2="$a/$HS"; fi
    return 0
}

fmt_hms() {                         # seconds -> "m:ss" or "h:mm:ss"; sets HMS
    local s=$1
    (( s < 0 )) && s=0
    if (( s >= 3600 )); then
        printf -v HMS '%d:%02d:%02d' $(( s / 3600 )) $(( s % 3600 / 60 )) $(( s % 60 ))
    else
        printf -v HMS '%d:%02d' $(( s / 60 )) $(( s % 60 ))
    fi
    return 0
}

fmt_ms() {                          # milliseconds -> "0.3 s" / "1:05"; sets MS_TXT
    local ms=$1
    if (( ms < 60000 )); then
        printf -v MS_TXT '%d.%d s' $(( ms / 1000 )) $(( ms % 1000 / 100 ))
    else
        fmt_hms $(( ms / 1000 ))
        MS_TXT=$HMS
    fi
    return 0
}

fmt_date() {                        # epoch seconds -> "2024-01-31"; sets DATE_TXT
    printf -v DATE_TXT '%(%Y-%m-%d)T' "$1"
    return 0
}

csvq() {                            # CSV-quote a field; sets CSV
    local s=${1//\"/\"\"}
    CSV="\"$s\""
    return 0
}

NOW_MS=0
tick() {                            # sets NOW_MS (milliseconds; sub-second only on bash 5+)
    if [[ -n ${EPOCHREALTIME-} ]]; then
        local t=${EPOCHREALTIME//[!0-9]/}
        NOW_MS=$(( 10#$t / 1000 ))
    else
        NOW_MS=$(( $(date +%s) * 1000 ))
    fi
    return 0
}

# --- platform detection: GNU vs BSD tools -------------------------------------

TAB=$'\t'
NL=$'\n'
STAT_GNU=false
FIND_PRINTF=false
HASH_CMD=()
HASH_LAST_FIELD=false
DD_QUIET=()
HASHING=false

detect_tools() {
    if stat -c %s / >/dev/null 2>&1; then STAT_GNU=true; fi
    if find / -maxdepth 0 -printf '' >/dev/null 2>&1; then FIND_PRINTF=true; fi
    if command -v sha256sum >/dev/null 2>&1; then
        HASH_CMD=(sha256sum)
    elif command -v shasum >/dev/null 2>&1; then
        HASH_CMD=(shasum -a 256)
    elif command -v openssl >/dev/null 2>&1; then
        HASH_CMD=(openssl dgst -sha256)
        HASH_LAST_FIELD=true
    fi
    if dd if=/dev/null of=/dev/null bs=1 status=none >/dev/null 2>&1; then DD_QUIET=(status=none); fi
    if (( ${#HASH_CMD[@]} > 0 )); then
        if $record_hash || $verify; then HASHING=true; fi
    else
        if $record_hash || $verify; then
            say "warning: no sha256sum, shasum or openssl found - copies are verified by size only"
        fi
        record_hash=false
        verify=false
    fi
    return 0
}

file_size() {                       # size in bytes of $1
    if $STAT_GNU; then stat -c %s -- "$1"; else stat -f %z -- "$1"; fi
}

df_info() {                         # $1 dir; sets DF_TOTAL / DF_AVAIL in bytes (empty when unknown)
    local line fs blocks used avail
    DF_TOTAL=""
    DF_AVAIL=""
    line=$(df -kP "$1" 2>/dev/null | tail -n 1) || return 0
    read -r fs blocks used avail _ <<< "$line" || return 0
    if [[ $blocks =~ ^[0-9]+$ && $avail =~ ^[0-9]+$ ]]; then
        DF_TOTAL=$(( blocks * 1024 ))
        DF_AVAIL=$(( avail * 1024 ))
    fi
    return 0
}

# list_files DIR [MAXDEPTH]: every regular file below DIR as NUL-terminated records
# "size<TAB>mtime<TAB>relative path", sorted by path. Any file name is safe except,
# on BSD tools, names containing a newline (those are skipped there).
list_files() {
    local dir=$1 depth=${2:-}
    local depth_args=()
    [[ -n $depth ]] && depth_args=(-maxdepth "$depth")
    if $FIND_PRINTF; then
        find "$dir" ${depth_args[@]+"${depth_args[@]}"} -type f -printf "%s${TAB}%T@${TAB}%P\\0" 2>>"$FIND_ERRORS" \
            | LC_ALL=C sort -z -t "$TAB" -k 3
    else
        find "$dir" ${depth_args[@]+"${depth_args[@]}"} -type f ! -name "*${NL}*" -print0 2>>"$FIND_ERRORS" \
            | xargs -0 stat -f "%z${TAB}%m${TAB}%N" 2>>"$FIND_ERRORS" \
            | LC_ALL=C sort -t "$TAB" -k 3 \
            | tr '\n' '\0'
    fi
}

# --- runtime state -------------------------------------------------------------

printf -v STAMP '%(%Y%m%d-%H%M%S)T' -1
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/iphone-transfer.XXXXXX")
FIND_ERRORS="$TMP_DIR/find.err"
SAMPLES_FILE="$TMP_DIR/samples"

INTERRUPTED=0
DISK_FULL=0
SOURCE_GONE=0
COPY_PID=""
POLL_PID=""
CURRENT_STAGED=""
START_MS=0
COPY_START_MS=0
LAST_DRAW_MS=0
SOURCE_DIR=""
DEST_DIR=""
WORK_DIR=""
STAGING_DIR=""
LOG_DIR=""
MANIFEST_FILE=""
SCAN_FILE=""
SCAN_REPORT=""
SRC_DF_TOTAL=""
SRC_DF_AVAIL=""

# --- signals and cleanup -------------------------------------------------------

stop_poller() {
    [[ -n $POLL_PID ]] || return 0
    { kill "$POLL_PID" && wait "$POLL_PID"; } 2>/dev/null || true
    POLL_PID=""
    return 0
}

on_signal() {                       # Ctrl+C / kill: stop the transfer in flight; the main loop cleans up
    trap '' INT TERM HUP
    INTERRUPTED=1
    if [[ -n $COPY_PID ]]; then kill -TERM "$COPY_PID" 2>/dev/null || true; fi
    if [[ -n $POLL_PID ]]; then kill -TERM "$POLL_PID" 2>/dev/null || true; fi
    return 0
}

on_exit() {                         # always: no partial file left in staging, no temp files
    stop_poller
    if [[ -n $COPY_PID ]]; then
        kill -TERM "$COPY_PID" 2>/dev/null || true
        wait "$COPY_PID" 2>/dev/null || true
    fi
    if [[ -n $CURRENT_STAGED && -e $CURRENT_STAGED ]]; then
        rm -f -- "$CURRENT_STAGED"
    fi
    if [[ -n $TMP_DIR ]]; then rm -rf -- "$TMP_DIR"; fi
    return 0
}

trap on_signal INT TERM HUP
trap on_exit EXIT

# --- SOURCE --------------------------------------------------------------------

phase_source() {
    phase "SOURCE"
    [[ -d $source_arg ]] || die "source folder not found: $source_arg"
    SOURCE_DIR=$(cd -- "$source_arg" && pwd -P) || die "cannot enter the source folder: $source_arg"
    say "Source: $SOURCE_DIR"
    df_info "$SOURCE_DIR"
    SRC_DF_TOTAL=$DF_TOTAL
    SRC_DF_AVAIL=$DF_AVAIL
    if [[ -n $SRC_DF_TOTAL ]]; then
        hs "$SRC_DF_TOTAL"; local total=$HS
        hs "$SRC_DF_AVAIL"
        say "Volume: $total, $HS free"
    fi
    say "Wanted: ${extensions}   folders: ${folder_patterns[*]}"
    return 0
}

# --- SCAN: walk the source, collect every file, print the report ----------------

F_PATH=()                           # one entry per file found
F_FOLDER=()                         # folder relative to the source ("" for files in the root)
F_NAME=()                           # file name with extension
F_EXT=()                            # lower-case extension without the dot ("" if none)
F_SIZE=()
F_MTIME=()
F_WANTED=()                         # 1 when the extension filter accepts it
F_TOP=()                            # index of the top-level folder (0 = source root)

TOP_NAME=()                         # top-level folders; index 0 is the source root itself
TOP_PATH=()
TOP_DEPTH=()
TOP_FILES=() TOP_PHOTOS=() TOP_VIDEOS=() TOP_OTHER=() TOP_BYTES=() TOP_MIN=() TOP_MAX=()
TOP_COUNT=0
declare -A EXT_COUNT=() EXT_BYTES=()
SCAN_FILES=0 SCAN_BYTES=0 SCAN_MIN=0 SCAN_MAX=0
WANTED_FILES=0 WANTED_BYTES=0 UNWANTED_FILES=0 UNWANTED_BYTES=0

folder_matches() {                  # does top-level folder $1 match one of the -f patterns? (case-insensitive)
    local name=${1,,} p
    for p in "${folder_patterns[@]}"; do
        [[ $name == ${p,,} ]] && return 0
    done
    return 1
}

discover_top_folders() {
    local d name
    TOP_NAME=("")
    TOP_PATH=("$SOURCE_DIR")
    TOP_DEPTH=(1)
    : > "$FIND_ERRORS"
    while IFS= read -r -d '' d; do
        name=${d##*/}
        [[ $name == .iphone-transfer ]] && continue
        folder_matches "$name" || continue
        TOP_NAME+=("$name")
        TOP_PATH+=("$d")
        TOP_DEPTH+=("")
    done < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>>"$FIND_ERRORS" | LC_ALL=C sort -z)
    TOP_COUNT=$(( ${#TOP_NAME[@]} - 1 ))
    return 0
}

scan_progress() {                   # $1 folders done  $2 current folder  [$3 force]
    $IS_TTY || return 0
    tick
    if [[ ${3:-} != force ]] && (( NOW_MS - LAST_DRAW_MS < 200 )); then return 0; fi
    local line
    hs "$SCAN_BYTES"
    printf -v line 'scanning  folders %d/%d  files %d  %s  %s' "$1" "$TOP_COUNT" "$SCAN_FILES" "$HS" "$2"
    printf '\r%-*s' "$((TERM_WIDTH - 1))" "${line:0:TERM_WIDTH-1}"
    LAST_DRAW_MS=$NOW_MS
    return 0
}

scan_dir() {                        # $1 top-level index: read every file below it into the F_ arrays
    local t=$1 dir=${TOP_PATH[$1]} base=${TOP_NAME[$1]} depth=${TOP_DEPTH[$1]}
    local size mtime rel name ext folder kind wanted key line
    TOP_FILES[t]=0; TOP_PHOTOS[t]=0; TOP_VIDEOS[t]=0; TOP_OTHER[t]=0; TOP_BYTES[t]=0; TOP_MIN[t]=0; TOP_MAX[t]=0
    : > "$FIND_ERRORS"
    while IFS=$'\t' read -r -d '' size mtime rel; do
        rel=${rel#"$dir/"}
        mtime=${mtime%%.*}
        [[ $mtime =~ ^-?[0-9]+$ ]] || mtime=0
        [[ $size =~ ^[0-9]+$ ]] || size=0
        name=${rel##*/}
        folder=$base
        if [[ $rel == */* ]]; then folder="${base:+$base/}${rel%/*}"; fi
        ext=""
        if [[ $name == ?*.* ]]; then ext=${name##*.}; ext=${ext,,}; fi
        wanted=0
        if $ALL_EXTS; then wanted=1
        elif [[ -n $ext && -n ${WANT_EXT[$ext]+x} ]]; then wanted=1
        fi
        kind=other
        if [[ -n $ext && -n ${PHOTO_EXT[$ext]+x} ]]; then kind=photo
        elif [[ -n $ext && -n ${VIDEO_EXT[$ext]+x} ]]; then kind=video
        fi

        F_PATH+=("$dir/$rel"); F_FOLDER+=("$folder"); F_NAME+=("$name"); F_EXT+=("$ext")
        F_SIZE+=("$size"); F_MTIME+=("$mtime"); F_WANTED+=("$wanted"); F_TOP+=("$t")

        TOP_FILES[t]=$(( TOP_FILES[t] + 1 ))
        TOP_BYTES[t]=$(( TOP_BYTES[t] + size ))
        case $kind in
            photo) TOP_PHOTOS[t]=$(( TOP_PHOTOS[t] + 1 )) ;;
            video) TOP_VIDEOS[t]=$(( TOP_VIDEOS[t] + 1 )) ;;
            *)     TOP_OTHER[t]=$(( TOP_OTHER[t] + 1 )) ;;
        esac
        if (( TOP_FILES[t] == 1 )); then
            TOP_MIN[t]=$mtime; TOP_MAX[t]=$mtime
        else
            if (( mtime < TOP_MIN[t] )); then TOP_MIN[t]=$mtime; fi
            if (( mtime > TOP_MAX[t] )); then TOP_MAX[t]=$mtime; fi
        fi
        key=${ext:-"(none)"}
        EXT_COUNT[$key]=$(( ${EXT_COUNT[$key]:-0} + 1 ))
        EXT_BYTES[$key]=$(( ${EXT_BYTES[$key]:-0} + size ))
        if (( SCAN_FILES == 0 )); then
            SCAN_MIN=$mtime; SCAN_MAX=$mtime
        else
            if (( mtime < SCAN_MIN )); then SCAN_MIN=$mtime; fi
            if (( mtime > SCAN_MAX )); then SCAN_MAX=$mtime; fi
        fi
        SCAN_FILES=$(( SCAN_FILES + 1 ))
        SCAN_BYTES=$(( SCAN_BYTES + size ))
        if (( wanted )); then
            WANTED_FILES=$(( WANTED_FILES + 1 )); WANTED_BYTES=$(( WANTED_BYTES + size ))
        else
            UNWANTED_FILES=$(( UNWANTED_FILES + 1 )); UNWANTED_BYTES=$(( UNWANTED_BYTES + size ))
        fi
        scan_progress "$t" "${base:-.}"
    done < <(list_files "$dir" "$depth")
    if [[ -s $FIND_ERRORS ]]; then
        clear_progress
        say "warning: problems while reading ${base:-$dir}:"
        while IFS= read -r line; do say "    $line"; done < "$FIND_ERRORS"
    fi
    return 0
}

render_scan_report() {              # prints the report (captured into SCAN_REPORT)
    local w=12 t n name key filter now from to total_h
    for (( t = 1; t < ${#TOP_NAME[@]}; t++ )); do
        n=${#TOP_NAME[$t]}
        if (( n > w )); then w=$n; fi
    done
    if (( w > 40 )); then w=40; fi
    printf -v now '%(%Y-%m-%d %H:%M:%S)T' -1
    printf 'SCAN REPORT  %s\n' "$now"
    printf 'Source   %s\n' "$SOURCE_DIR"
    if [[ -n $SRC_DF_TOTAL ]]; then
        hs "$SRC_DF_TOTAL"; total_h=$HS
        hs "$SRC_DF_AVAIL"
        printf 'Volume   %s total, %s free\n' "$total_h" "$HS"
    fi
    printf 'Filter   extensions: %s   folders: %s\n' "$extensions" "${folder_patterns[*]}"
    printf '\n%-*s %7s %7s %7s %7s %11s  %s\n' "$w" "Folder" "Files" "Photos" "Videos" "Other" "Size" "Modified (oldest .. newest)"
    for (( t = 0; t < ${#TOP_NAME[@]}; t++ )); do
        if (( t == 0 && TOP_FILES[0] == 0 )); then continue; fi
        name=${TOP_NAME[$t]}
        [[ -z $name ]] && name="(root files)"
        hs "${TOP_BYTES[$t]}"
        from="-"; to="-"
        if (( TOP_FILES[t] > 0 )); then
            fmt_date "${TOP_MIN[$t]}"; from=$DATE_TXT
            fmt_date "${TOP_MAX[$t]}"; to=$DATE_TXT
        fi
        printf '%-*s %7d %7d %7d %7d %11s  %s .. %s\n' "$w" "$name" "${TOP_FILES[$t]}" "${TOP_PHOTOS[$t]}" \
            "${TOP_VIDEOS[$t]}" "${TOP_OTHER[$t]}" "$HS" "$from" "$to"
    done
    local photos=0 videos=0 other=0
    for (( t = 0; t < ${#TOP_NAME[@]}; t++ )); do
        photos=$(( photos + TOP_PHOTOS[t] )); videos=$(( videos + TOP_VIDEOS[t] )); other=$(( other + TOP_OTHER[t] ))
    done
    hs "$SCAN_BYTES"
    from="-"; to="-"
    if (( SCAN_FILES > 0 )); then
        fmt_date "$SCAN_MIN"; from=$DATE_TXT
        fmt_date "$SCAN_MAX"; to=$DATE_TXT
    fi
    printf '%-*s %7d %7d %7d %7d %11s  %s .. %s\n' "$w" "TOTAL" "$SCAN_FILES" "$photos" "$videos" "$other" "$HS" "$from" "$to"
    printf '\n%-12s %7s %11s  %s\n' "Extension" "Files" "Size" "Filter"
    if (( ${#EXT_COUNT[@]} > 0 )); then
        while IFS= read -r key; do
            filter="skipped (not in -e)"
            if $ALL_EXTS || [[ -n ${WANT_EXT[$key]+x} ]]; then filter="wanted"; fi
            hs "${EXT_BYTES[$key]}"
            if [[ $key == "(none)" ]]; then name=$key; else name=".$key"; fi
            printf '%-12s %7d %11s  %s\n' "$name" "${EXT_COUNT[$key]}" "$HS" "$filter"
        done < <(printf '%s\n' "${!EXT_COUNT[@]}" | LC_ALL=C sort)
    fi
    hs "$WANTED_BYTES"; total_h=$HS
    hs "$UNWANTED_BYTES"
    printf '\nWanted: %d file(s), %s.   Skipped by type: %d file(s), %s.\n' "$WANTED_FILES" "$total_h" "$UNWANTED_FILES" "$HS"
    return 0
}

phase_scan() {
    local t start
    phase "SCAN"
    discover_top_folders
    say "Scanning $TOP_COUNT folder(s) under $SOURCE_DIR ..."
    tick; start=$NOW_MS
    for (( t = 0; t < ${#TOP_NAME[@]}; t++ )); do
        if (( INTERRUPTED )); then break; fi
        scan_dir "$t"
        if ! $IS_TTY && (( t > 0 )); then
            hs "${TOP_BYTES[$t]}"
            printf '  %-24s %6d file(s)  %s\n' "${TOP_NAME[$t]}" "${TOP_FILES[$t]}" "$HS"
        fi
        scan_progress "$t" "${TOP_NAME[$t]:-.}" force
    done
    clear_progress
    tick
    hs "$SCAN_BYTES"
    say "Scanned $SCAN_FILES file(s), $HS, in $(( (NOW_MS - start) / 1000 )) s"
    if (( INTERRUPTED )); then return 0; fi
    SCAN_REPORT=$(render_scan_report)
    say ""
    say "$SCAN_REPORT"
    return 0
}

# --- DESTINATION ---------------------------------------------------------------

setup_files() {                     # log, scan report; needs LOG_DIR
    local probe="$LOG_DIR/.write-test-$$"
    if ! { : > "$probe"; } 2>/dev/null; then die "cannot write to $LOG_DIR"; fi
    rm -f -- "$probe"
    open_log "$LOG_DIR/transfer-$STAMP.log"
    MANIFEST_FILE="$LOG_DIR/manifest.csv"
    SCAN_FILE="$LOG_DIR/scan-$STAMP.txt"
    printf '%s\n' "$SCAN_REPORT" > "$SCAN_FILE"
    say "Scan report: $SCAN_FILE"
    say "Log:         $LOG_FILE"
    return 0
}

phase_destination() {
    local default answer probe
    phase "DESTINATION"
    if [[ -z $dest_arg ]]; then
        default="$HOME/Pictures/iPhone"
        if $INTERACTIVE; then
            read -r -p "Copy to [$default]: " answer || answer=""
            log "Copy to [$default]: $answer"
            if (( INTERRUPTED )); then return 0; fi
            dest_arg=${answer:-$default}
        else
            dest_arg=$default
            say "No destination given - using $default"
        fi
    fi
    dest_arg=${dest_arg/#\~/$HOME}
    mkdir -p -- "$dest_arg" 2>/dev/null || die "cannot create the destination folder: $dest_arg"
    DEST_DIR=$(cd -- "$dest_arg" && pwd -P) || die "cannot enter the destination folder: $dest_arg"
    if [[ $DEST_DIR == "$SOURCE_DIR" ]]; then die "source and destination are the same folder"; fi
    if [[ $DEST_DIR == "$SOURCE_DIR"/* ]]; then
        rmdir -- "$DEST_DIR" 2>/dev/null || true    # undo the mkdir above if it created an empty folder
        die "the destination must not be inside the source"
    fi
    if [[ $SOURCE_DIR == "$DEST_DIR"/* ]]; then say "warning: the source is inside the destination"; fi

    WORK_DIR="$DEST_DIR/.iphone-transfer"
    STAGING_DIR="$WORK_DIR/staging"
    LOG_DIR=$WORK_DIR
    [[ -n $log_dir_opt ]] && LOG_DIR=${log_dir_opt/#\~/$HOME}
    mkdir -p -- "$STAGING_DIR" "$LOG_DIR" 2>/dev/null || die "cannot create $STAGING_DIR or $LOG_DIR"
    LOG_DIR=$(cd -- "$LOG_DIR" && pwd -P) || die "cannot enter $LOG_DIR"
    probe="$STAGING_DIR/.write-test-$$"
    if ! { : > "$probe"; } 2>/dev/null; then die "the destination is not writable: $DEST_DIR"; fi
    rm -f -- "$probe"
    say "Destination: $DEST_DIR"
    setup_files
    df_info "$DEST_DIR"
    if [[ -n $DF_TOTAL ]]; then
        hs "$DF_TOTAL"; local total=$HS
        hs "$DF_AVAIL"
        say "Free space:  $HS of $total"
    fi
    return 0
}

# --- PLAN: compare the scan with what the destination already has ---------------

declare -A DEST_SIZE=() DEST_LISTED=() PLAN_SIZE=()
P_IDX=()                            # index into the F_ arrays
P_ACTION=()                         # copy | rename | replace
P_DIR=()                            # destination folder
P_NAME=()                           # destination name decided at plan time (re-checked when moving)
PLAN_COUNT=0 PLAN_BYTES=0
THERE_COUNT=0 THERE_BYTES=0
RENAME_COUNT=0 REPLACE_COUNT=0

load_dest_listing() {               # cache name -> size of the files directly in destination folder $1
    [[ -n ${DEST_LISTED[$1]+x} ]] && return 0
    DEST_LISTED[$1]=1
    [[ -d $1 ]] || return 0
    local size mtime rel
    : > "$FIND_ERRORS"
    while IFS=$'\t' read -r -d '' size mtime rel; do
        rel=${rel#"$1/"}
        DEST_SIZE["$1/$rel"]=$size
    done < <(list_files "$1" 1)
    return 0
}

existing_size() {                   # $1 dir  $2 name  $3 cached|live; sets E_SIZE ("" = no such file)
    local key="$1/$2"
    E_SIZE=""
    if [[ $3 == cached ]]; then
        E_SIZE=${PLAN_SIZE["$key"]-}
        [[ -z $E_SIZE ]] && E_SIZE=${DEST_SIZE["$key"]-}
    elif [[ -e $key ]]; then
        E_SIZE=$(file_size "$key" 2>/dev/null) || E_SIZE=""
        [[ -z $E_SIZE ]] && E_SIZE=-1
    fi
    return 0
}

# resolve_target DIR NAME SIZE cached|live: what to do with a file at DIR/NAME.
#   there   - a file of the same size exists as NAME or NAME_n: nothing to do
#   copy    - the name is free
#   rename  - a different file holds the name: use the first free NAME_n (R_NAME)
#   replace - same, but -o was given: overwrite NAME
resolve_target() {
    local dir=$1 name=$2 size=$3 mode=$4 stem ext cand n=0
    if [[ $name == ?*.* ]]; then stem=${name%.*}; ext=".${name##*.}"; else stem=$name; ext=""; fi
    cand=$name
    while :; do
        existing_size "$dir" "$cand" "$mode"
        [[ -z $E_SIZE ]] && break
        if [[ $E_SIZE == "$size" ]]; then R_ACTION=there; R_NAME=$cand; return 0; fi
        n=$(( n + 1 ))
        cand="${stem}_${n}${ext}"
    done
    if (( n == 0 )); then R_ACTION=copy; R_NAME=$name
    elif $overwrite; then R_ACTION=replace; R_NAME=$name
    else R_ACTION=rename; R_NAME=$cand
    fi
    return 0
}

label_of() {                        # $1 file index; sets LABEL ("folder/name")
    LABEL=${F_NAME[$1]}
    [[ -n ${F_FOLDER[$1]} ]] && LABEL="${F_FOLDER[$1]}/${F_NAME[$1]}"
    return 0
}

phase_plan() {
    local i p dir rel note there_h plan_h
    phase "PLAN"
    for (( i = 0; i < ${#F_PATH[@]}; i++ )); do
        (( F_WANTED[i] )) || continue
        dir=$DEST_DIR
        if ! $flat && [[ -n ${F_FOLDER[$i]} ]]; then dir="$DEST_DIR/${F_FOLDER[$i]}"; fi
        load_dest_listing "$dir"
        resolve_target "$dir" "${F_NAME[$i]}" "${F_SIZE[$i]}" cached
        if [[ $R_ACTION == there ]]; then
            THERE_COUNT=$(( THERE_COUNT + 1 )); THERE_BYTES=$(( THERE_BYTES + F_SIZE[i] ))
            continue
        fi
        P_IDX+=("$i"); P_ACTION+=("$R_ACTION"); P_DIR+=("$dir"); P_NAME+=("$R_NAME")
        PLAN_SIZE["$dir/$R_NAME"]=${F_SIZE[$i]}
        PLAN_COUNT=$(( PLAN_COUNT + 1 )); PLAN_BYTES=$(( PLAN_BYTES + F_SIZE[i] ))
        case $R_ACTION in
            rename)  RENAME_COUNT=$(( RENAME_COUNT + 1 )) ;;
            replace) REPLACE_COUNT=$(( REPLACE_COUNT + 1 )) ;;
        esac
    done
    hs "$PLAN_BYTES"; plan_h=$HS
    hs "$THERE_BYTES"; there_h=$HS
    hs "$UNWANTED_BYTES"
    say "To copy:          $PLAN_COUNT file(s), $plan_h"
    say "Already there:    $THERE_COUNT file(s), $there_h"
    say "Skipped by type:  $UNWANTED_FILES file(s), $HS"
    if (( RENAME_COUNT > 0 )); then
        say "  $RENAME_COUNT of them will be saved as name_1.ext: a different file with that name is already there"
    fi
    if (( REPLACE_COUNT > 0 )); then
        say "  $REPLACE_COUNT of them will replace a different file with the same name (-o)"
    fi
    if $dry_run && (( PLAN_COUNT > 0 )); then
        say ""
        for (( p = 0; p < PLAN_COUNT; p++ )); do
            i=${P_IDX[$p]}
            label_of "$i"
            rel=${P_DIR[$p]#"$DEST_DIR"}
            rel=${rel#/}
            note=""
            case ${P_ACTION[$p]} in
                rename)  note="   (name taken, saved as ${P_NAME[$p]})" ;;
                replace) note="   (replaces the existing file)" ;;
            esac
            hs "${F_SIZE[$i]}"
            say "$(printf '[%*d/%d] %-*s %10s  -> %s%s' "${#PLAN_COUNT}" "$((p + 1))" "$PLAN_COUNT" "$LABEL_WIDTH" "$LABEL" "$HS" "${rel:+$rel/}${P_NAME[$p]}" "$note")"
        done
    fi
    return 0
}

check_free_space() {
    local need free_h
    (( PLAN_BYTES > 0 )) || return 0
    df_info "$DEST_DIR"
    if [[ -z $DF_AVAIL ]]; then say "Free space: unknown - continuing"; return 0; fi
    need=$(( PLAN_BYTES + SPACE_MARGIN ))
    hs "$DF_AVAIL"; free_h=$HS
    hs "$PLAN_BYTES"
    if (( DF_AVAIL >= need )); then
        say "Free space: $free_h, needed $HS - ok"
        return 0
    fi
    say "Not enough free space: $free_h free, $HS to copy (plus a 64 MB reserve)"
    if $INTERACTIVE && ask_yes_no "Continue anyway?" n; then
        say "Continuing on request"
        return 0
    fi
    die "not enough free space in $DEST_DIR"
}

# --- COPY ----------------------------------------------------------------------

FILENO=0
ATTEMPTED=0
COPIED_COUNT=0 COPIED_BYTES=0
FAILED_COUNT=0 FAILED_BYTES=0
LATE_THERE_COUNT=0 LATE_THERE_BYTES=0
PENDING_COUNT=0 PENDING_BYTES=0
PROGRESS_BYTES=0                    # bytes of the plan dealt with (copied, failed or found there)
FAILED_LIST=()

add_sample() {                      # $1 ms  $2 copied bytes; keeps the last 40 samples
    local lines=() l
    if [[ -s $SAMPLES_FILE ]]; then
        while IFS= read -r l; do lines+=("$l"); done < "$SAMPLES_FILE"
    fi
    lines+=("$1 $2")
    if (( ${#lines[@]} > 60 )); then lines=("${lines[@]: -40}"); fi
    printf '%s\n' "${lines[@]}" > "$SAMPLES_FILE"
    return 0
}

compute_rate() {                    # $1 copied bytes now; sets RATE (bytes/s) from the sliding window
    local t b first_t="" first_b="" el
    RATE=0
    if [[ -s $SAMPLES_FILE ]]; then
        while read -r t b; do
            [[ $t =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]] || continue
            if (( NOW_MS - t > RATE_WINDOW_MS )); then continue; fi
            if [[ -z $first_t ]]; then first_t=$t; first_b=$b; fi
        done < "$SAMPLES_FILE"
        if [[ -n $first_t ]] && (( NOW_MS - first_t >= 1000 && $1 >= first_b )); then
            RATE=$(( ($1 - first_b) * 1000 / (NOW_MS - first_t) ))
            return 0
        fi
    fi
    el=$(( NOW_MS - COPY_START_MS ))
    if (( el >= 1000 )); then RATE=$(( $1 * 1000 / el )); fi
    return 0
}

draw_progress() {                   # $1 file number  $2 label  $3 bytes of this file so far ("" = n/a)  $4 its size
    local cur=${3:-} size=${4:-0} name=${2##*/} progress copied pct10=0 eta el head tail avail line
    tick
    progress=$(( PROGRESS_BYTES + ${cur:-0} ))
    copied=$(( COPIED_BYTES + ${cur:-0} ))
    if (( PLAN_BYTES > 0 )); then pct10=$(( progress * 1000 / PLAN_BYTES )); fi
    compute_rate "$copied"
    fmt_hms $(( (NOW_MS - COPY_START_MS) / 1000 )); el=$HMS
    eta="--:--"
    if (( RATE > 0 )); then fmt_hms $(( (PLAN_BYTES - progress) / RATE )); eta=$HMS; fi
    hs2 "$progress" "$PLAN_BYTES"
    hs "$RATE"
    printf -v head '[%d/%d] %d.%d%% %s %s/s %s ETA %s | ' "$1" "$PLAN_COUNT" $(( pct10 / 10 )) $(( pct10 % 10 )) \
        "$HS2" "$HS" "$el" "$eta"
    tail=""
    if [[ -n $cur ]] && (( size > 0 )); then
        hs2 "$cur" "$size"
        printf -v tail ' %d%% (%s)' $(( cur * 100 / size )) "$HS2"
    fi
    # the file name gets whatever width is left; on a narrow terminal the per-file bytes go first
    avail=$(( TERM_WIDTH - 1 - ${#head} - ${#tail} ))
    if (( avail < 12 )); then tail=""; avail=$(( TERM_WIDTH - 1 - ${#head} )); fi
    if (( avail < 1 )); then avail=1; fi
    line="$head${name:0:avail}$tail"
    printf '\r%-*s' "$((TERM_WIDTH - 1))" "${line:0:TERM_WIDTH-1}"
    set_title "iPhone transfer $(( pct10 / 10 ))%"
    LAST_DRAW_MS=$NOW_MS
    return 0
}

start_poller() {                    # $1 staged file  $2 its size  $3 label: live per-file progress while dd runs
    (
        trap 'exit 0' TERM
        exec 2>/dev/null
        while :; do
            cur=0
            if [[ -e $1 ]]; then cur=$(file_size "$1") || cur=0; fi
            tick
            add_sample "$NOW_MS" "$(( COPIED_BYTES + cur ))"
            draw_progress "$FILENO" "$3" "$cur" "$2"
            sleep "$POLL_INTERVAL"
        done
    ) &
    POLL_PID=$!
    return 0
}

# The byte-moving jobs. Each runs in the background so a trap can stop it at once;
# inside, the TERM trap kills the pipeline so no process keeps writing to staging.
copy_stream_hashed() {              # $1 src  $2 staged  $3 errfile  $4 hashfile
    trap 'kill $(jobs -p) 2>/dev/null; wait 2>/dev/null; exit 130' TERM
    dd if="$1" bs="$BLOCK_SIZE" ${DD_QUIET[@]+"${DD_QUIET[@]}"} 2>>"$3" \
        | tee -- "$2" 2>>"$3" \
        | "${HASH_CMD[@]}" > "$4" 2>>"$3" &
    wait $!
}

copy_stream_plain() {               # $1 src  $2 staged  $3 errfile
    trap 'kill $(jobs -p) 2>/dev/null; wait 2>/dev/null; exit 130' TERM
    dd if="$1" of="$2" bs="$BLOCK_SIZE" ${DD_QUIET[@]+"${DD_QUIET[@]}"} 2>>"$3" &
    wait $!
}

hash_stream() {                     # $1 file  $2 hashfile  $3 errfile
    trap 'kill $(jobs -p) 2>/dev/null; wait 2>/dev/null; exit 130' TERM
    "${HASH_CMD[@]}" < "$1" > "$2" 2>>"$3" &
    wait $!
}

run_job() {                         # run "$@" as a killable background job and wait; sets JOB_RC
    "$@" &
    COPY_PID=$!
    JOB_RC=0
    wait "$COPY_PID" || JOB_RC=$?
    if (( INTERRUPTED )); then wait "$COPY_PID" 2>/dev/null || true; fi
    COPY_PID=""
    return 0
}

read_hash() {                       # $1 hashfile; sets HASH_OUT ("" when unusable)
    local line=""
    HASH_OUT=""
    [[ -s $1 ]] || return 0
    IFS= read -r line < "$1" || true
    if $HASH_LAST_FIELD; then HASH_OUT=${line##* }; else HASH_OUT=${line%% *}; fi
    [[ $HASH_OUT =~ ^[0-9a-fA-F]{64}$ ]] || HASH_OUT=""
    return 0
}

first_error_line() {                # $1 errfile; sets ERR_LINE to the first real error line
    local l
    ERR_LINE=""
    [[ -s $1 ]] || return 0
    while IFS= read -r l || [[ -n $l ]]; do
        [[ $l == *"records in"* || $l == *"records out"* || $l == *"bytes transferred"* ]] && continue
        if [[ -n $l ]]; then ERR_LINE=$l; return 0; fi
    done < "$1"
    return 0
}

source_available() {                # true when the source folder is reachable (waits once for it to come back)
    local waited=0
    if [[ -d $SOURCE_DIR ]]; then SOURCE_GONE=0; return 0; fi
    (( SOURCE_GONE )) && return 1
    say "    source folder is not reachable - waiting up to ${RECONNECT_WAIT}s for it to come back"
    while (( waited < RECONNECT_WAIT )); do
        sleep 2 & wait $! || true
        (( INTERRUPTED )) && return 1
        waited=$(( waited + 2 ))
        if [[ -d $SOURCE_DIR ]]; then say "    source is back"; return 0; fi
    done
    SOURCE_GONE=1
    say "    source did not come back - the remaining files will fail quickly"
    return 1
}

# copy_one PLAN-INDEX LABEL: stage, verify, move. True on success.
# Sets C_STATUS (copied|renamed|there|failed) C_FINAL C_HASH C_ERROR C_ATTEMPTS C_MS.
copy_one() {
    local p=$1 label=$2 i src name size dir staged errfile hashfile line
    local attempt max_attempts err hash hash2 got_size delay final start_ms
    i=${P_IDX[$p]}; src=${F_PATH[$i]}; name=${F_NAME[$i]}; size=${F_SIZE[$i]}; dir=${P_DIR[$p]}
    staged="$STAGING_DIR/$name.part"
    errfile="$TMP_DIR/copy.err"
    hashfile="$TMP_DIR/copy.hash"
    max_attempts=$(( retries + 1 ))
    C_STATUS=failed; C_FINAL=""; C_HASH=""; C_ERROR=""; C_ATTEMPTS=0; C_MS=0; C_NOTE=""
    tick; start_ms=$NOW_MS

    for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
        C_ATTEMPTS=$attempt
        if (( INTERRUPTED )); then break; fi
        if ! source_available; then C_ERROR="source folder not reachable"; break; fi
        err=""; hash=""
        if [[ -e $staged ]]; then rm -f -- "$staged"; fi
        : > "$errfile"
        : > "$hashfile"
        CURRENT_STAGED=$staged

        # a. stream into staging (hash computed on the way when verifying or recording it)
        if $IS_TTY && (( size >= BIG_FILE )); then start_poller "$staged" "$size" "$label"; fi
        if $HASHING; then
            run_job copy_stream_hashed "$src" "$staged" "$errfile" "$hashfile"
        else
            run_job copy_stream_plain "$src" "$staged" "$errfile"
        fi
        stop_poller
        if (( INTERRUPTED )); then break; fi

        # b. verify: exit status, byte count against the scan, hash of a re-read
        if (( JOB_RC != 0 )); then
            first_error_line "$errfile"
            err=${ERR_LINE:-"copy failed (exit code $JOB_RC)"}
        else
            got_size=$(file_size "$staged" 2>/dev/null) || got_size=-1
            if [[ $got_size != "$size" ]]; then
                err="size mismatch: expected $size bytes, got $got_size"
            elif $HASHING; then
                read_hash "$hashfile"; hash=$HASH_OUT
                if [[ -z $hash ]]; then
                    err="could not compute the SHA-256 while copying"
                elif $verify; then
                    if $IS_TTY && (( size >= BIG_FILE )); then
                        line="[$FILENO/$PLAN_COUNT] verifying ${label##*/} ..."
                        printf '\r%-*s' "$((TERM_WIDTH - 1))" "${line:0:TERM_WIDTH-1}"
                    fi
                    : > "$hashfile"
                    run_job hash_stream "$staged" "$hashfile" "$errfile"
                    if (( INTERRUPTED )); then break; fi
                    read_hash "$hashfile"; hash2=$HASH_OUT
                    if (( JOB_RC != 0 )) || [[ -z $hash2 ]]; then
                        err="could not re-read the staged copy"
                    elif [[ $hash2 != "$hash" ]]; then
                        err="verification failed: the staged copy does not match what was read"
                    fi
                fi
            fi
        fi

        # c + d. keep the timestamp, decide the final name now, move atomically
        if [[ -z $err ]]; then
            touch -r "$src" -- "$staged" 2>/dev/null || log "    note: could not preserve the modified time of $label"
            resolve_target "$dir" "$name" "$size" live
            if [[ $R_ACTION == there ]]; then         # an identical file appeared meanwhile
                rm -f -- "$staged"; CURRENT_STAGED=""
                C_STATUS=there; C_FINAL="$dir/$R_NAME"
                tick; C_MS=$(( NOW_MS - start_ms ))
                return 0
            fi
            final="$dir/$R_NAME"
            if [[ ! -d $dir ]] && ! mkdir -p -- "$dir" 2>>"$errfile"; then
                err="could not create the folder $dir"
            elif ! mv -f -- "$staged" "$final" 2>>"$errfile"; then
                first_error_line "$errfile"
                err="could not move the staged copy into place: ${ERR_LINE:-unknown error}"
            else
                CURRENT_STAGED=""
                C_FINAL=$final
                C_NOTE=$R_ACTION
                if $record_hash; then C_HASH=$hash; fi
                if [[ $R_ACTION == rename ]]; then C_STATUS=renamed; else C_STATUS=copied; fi
                tick; C_MS=$(( NOW_MS - start_ms ))
                return 0
            fi
        fi

        # failure: drop the partial file, maybe retry with backoff
        C_ERROR=$err
        if [[ -e $staged ]]; then rm -f -- "$staged"; fi
        CURRENT_STAGED=""
        if [[ $err == *"No space left"* ]]; then DISK_FULL=1; break; fi
        if (( attempt < max_attempts )); then
            delay=$(( 1 << (attempt - 1) ))
            if (( delay > 10 )); then delay=10; fi
            say "    attempt $attempt/$max_attempts failed: $err - retrying in ${delay}s"
            sleep "$delay" & wait $! || true
        fi
    done
    if [[ -e $staged ]]; then rm -f -- "$staged"; fi
    CURRENT_STAGED=""
    [[ -z $C_ERROR ]] && C_ERROR="interrupted"
    tick; C_MS=$(( NOW_MS - start_ms ))
    return 1
}

file_line() {                       # $1 label  $2 size  $3 status text  [$4 duration text]
    local label=$1 text
    if (( ${#label} > LABEL_WIDTH )); then label="...${label: -$(( LABEL_WIDTH - 3 ))}"; fi
    hs "$2"
    printf -v text '[%*d/%d] %-*s %10s  %s' "${#PLAN_COUNT}" "$FILENO" "$PLAN_COUNT" "$LABEL_WIDTH" "$label" "$HS" "$3"
    if [[ -n ${4:-} ]]; then text+="  ($4)"; fi
    clear_progress
    say "$text"
    return 0
}

manifest_row() {                    # status folder name size dest sha ms attempts error
    local ts f n d e secs
    printf -v ts '%(%Y-%m-%dT%H:%M:%S)T' -1
    printf -v secs '%d.%d' $(( $7 / 1000 )) $(( $7 % 1000 / 100 ))
    csvq "$2"; f=$CSV
    csvq "$3"; n=$CSV
    csvq "$5"; d=$CSV
    csvq "$9"; e=$CSV
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$ts" "$1" "$f" "$n" "$4" "$d" "$6" "$secs" "$8" "$e" >> "$MANIFEST_FILE"
    return 0
}

phase_copy() {
    local n=0 f p i size dir what how
    phase "COPY"
    for f in "$STAGING_DIR"/*.part; do
        [[ -e $f ]] || continue
        rm -f -- "$f" && n=$(( n + 1 ))
    done
    if (( n > 0 )); then say "Removed $n leftover partial file(s) from an earlier run in $STAGING_DIR"; fi
    if [[ ! -e $MANIFEST_FILE ]]; then
        printf '%s\n' "timestamp,status,source_folder,file_name,size_bytes,destination_path,sha256,seconds,attempts,error" > "$MANIFEST_FILE"
    fi
    how="size check"
    if $HASHING && $verify; then how="size check + SHA-256 re-read"; fi
    if $record_hash; then how="$how, SHA-256 recorded in the manifest"; fi
    hs "$PLAN_BYTES"
    say "Copying $PLAN_COUNT file(s), $HS, to $DEST_DIR"
    say "Verification: $how.  Retries per file: $retries.  Staging: $STAGING_DIR"
    say ""
    tick; COPY_START_MS=$NOW_MS
    : > "$SAMPLES_FILE"
    add_sample "$NOW_MS" 0

    for (( p = 0; p < PLAN_COUNT; p++ )); do
        if (( INTERRUPTED || DISK_FULL )); then break; fi
        i=${P_IDX[$p]}
        FILENO=$(( p + 1 ))
        ATTEMPTED=$FILENO
        size=${F_SIZE[$i]}
        dir=${P_DIR[$p]}
        label_of "$i"

        # already there now? (a parallel run, or an earlier file of this run with the same name)
        resolve_target "$dir" "${F_NAME[$i]}" "$size" live
        if [[ $R_ACTION == there ]]; then
            LATE_THERE_COUNT=$(( LATE_THERE_COUNT + 1 )); LATE_THERE_BYTES=$(( LATE_THERE_BYTES + size ))
            PROGRESS_BYTES=$(( PROGRESS_BYTES + size ))
            file_line "$LABEL" "$size" "already there"
            manifest_row skipped "${F_FOLDER[$i]}" "${F_NAME[$i]}" "$size" "$dir/$R_NAME" "" 0 0 ""
        elif copy_one "$p" "$LABEL"; then
            PROGRESS_BYTES=$(( PROGRESS_BYTES + size ))
            fmt_ms "$C_MS"
            if [[ $C_STATUS == there ]]; then
                LATE_THERE_COUNT=$(( LATE_THERE_COUNT + 1 )); LATE_THERE_BYTES=$(( LATE_THERE_BYTES + size ))
                file_line "$LABEL" "$size" "already there" "$MS_TXT"
                manifest_row skipped "${F_FOLDER[$i]}" "${F_NAME[$i]}" "$size" "$C_FINAL" "" "$C_MS" "$C_ATTEMPTS" ""
            else
                COPIED_COUNT=$(( COPIED_COUNT + 1 )); COPIED_BYTES=$(( COPIED_BYTES + size ))
                what="copied"
                case $C_NOTE in
                    rename)  what="copied as ${C_FINAL##*/}" ;;
                    replace) what="copied (replaced the old file)" ;;
                esac
                if (( C_ATTEMPTS > 1 )); then what="$what after $C_ATTEMPTS attempts"; fi
                file_line "$LABEL" "$size" "$what" "$MS_TXT"
                manifest_row "$C_STATUS" "${F_FOLDER[$i]}" "${F_NAME[$i]}" "$size" "$C_FINAL" "$C_HASH" "$C_MS" "$C_ATTEMPTS" ""
            fi
        else
            if (( INTERRUPTED )); then ATTEMPTED=$p; break; fi      # this file stays pending
            FAILED_COUNT=$(( FAILED_COUNT + 1 )); FAILED_BYTES=$(( FAILED_BYTES + size ))
            PROGRESS_BYTES=$(( PROGRESS_BYTES + size ))
            FAILED_LIST+=("$LABEL - $C_ERROR")
            fmt_ms "$C_MS"
            file_line "$LABEL" "$size" "FAILED: $C_ERROR" "$MS_TXT"
            manifest_row failed "${F_FOLDER[$i]}" "${F_NAME[$i]}" "$size" "$dir/${P_NAME[$p]}" "" "$C_MS" "$C_ATTEMPTS" "$C_ERROR"
        fi

        tick
        add_sample "$NOW_MS" "$COPIED_BYTES"
        if $IS_TTY && (( p + 1 < PLAN_COUNT )) && (( NOW_MS - LAST_DRAW_MS >= 200 )); then
            label_of "${P_IDX[$((p + 1))]}"
            draw_progress "$(( p + 2 ))" "$LABEL" "" 0
        fi
    done
    clear_progress

    for (( p = ATTEMPTED; p < PLAN_COUNT; p++ )); do
        PENDING_COUNT=$(( PENDING_COUNT + 1 )); PENDING_BYTES=$(( PENDING_BYTES + F_SIZE[P_IDX[p]] ))
    done
    if (( DISK_FULL )); then say ""; say "The destination is full - copying stopped."; fi
    return 0
}

# --- SUMMARY -------------------------------------------------------------------

phase_summary() {
    local copy_ms avg=0 x
    phase "SUMMARY"
    tick
    copy_ms=$(( NOW_MS - COPY_START_MS ))
    hs "$COPIED_BYTES";                           say "Copied         $COPIED_COUNT file(s), $HS"
    hs $(( THERE_BYTES + LATE_THERE_BYTES ));     say "Already there  $(( THERE_COUNT + LATE_THERE_COUNT )) file(s), $HS"
    hs "$FAILED_BYTES";                           say "Failed         $FAILED_COUNT file(s), $HS"
    if (( PENDING_COUNT > 0 )); then
        hs "$PENDING_BYTES";                      say "Pending        $PENDING_COUNT file(s), $HS (not attempted)"
    fi
    if (( copy_ms > 0 )); then avg=$(( COPIED_BYTES * 1000 / copy_ms )); fi
    fmt_hms $(( (NOW_MS - START_MS) / 1000 ))
    hs "$avg"
    say "Elapsed        $HMS (copying: $(( copy_ms / 1000 )) s), average $HS/s"
    if (( FAILED_COUNT > 0 )); then
        say ""
        say "Failed files:"
        for x in "${FAILED_LIST[@]}"; do say "  $x"; done
    fi
    say ""
    say "Log:      $LOG_FILE"
    say "Manifest: $MANIFEST_FILE"
    if (( INTERRUPTED )); then
        say ""
        say "Interrupted. Re-run the same command to continue: complete files are skipped."
    fi
    set_title "iPhone transfer done"
    return 0
}

# --- main ----------------------------------------------------------------------

main() {
    local now
    tick; START_MS=$NOW_MS
    printf -v now '%(%Y-%m-%d %H:%M:%S)T' -1
    say "iPhone media transfer (bash) - $now"
    detect_tools

    phase_source
    phase_scan
    if (( INTERRUPTED )); then say "Interrupted during the scan - nothing was copied."; exit 3; fi

    if $scan_only; then
        if [[ -n $log_dir_opt ]]; then LOG_DIR=${log_dir_opt/#\~/$HOME}
        elif [[ -n $dest_arg ]]; then LOG_DIR="${dest_arg/#\~/$HOME}/.iphone-transfer"
        else LOG_DIR="${TMPDIR:-/tmp}/iphone-transfer"
        fi
        mkdir -p -- "$LOG_DIR" 2>/dev/null || die "cannot create $LOG_DIR"
        LOG_DIR=$(cd -- "$LOG_DIR" && pwd -P) || die "cannot enter $LOG_DIR"
        say ""
        setup_files
        exit 0
    fi

    phase_destination
    if (( INTERRUPTED )); then say "Interrupted - nothing was copied."; exit 3; fi
    phase_plan
    if $dry_run; then
        say ""
        say "Dry run - nothing was copied."
        exit 0
    fi
    if (( PLAN_COUNT == 0 )); then
        say ""
        say "Nothing to copy - every wanted file is already in $DEST_DIR"
        exit 0
    fi
    check_free_space
    if $INTERACTIVE; then
        hs "$PLAN_BYTES"
        if ! ask_yes_no "Start copying $PLAN_COUNT file(s), $HS, to $DEST_DIR?" y; then
            say "Nothing copied."
            exit 0
        fi
    fi

    phase_copy
    phase_summary
    if (( INTERRUPTED )); then exit 3; fi
    if (( FAILED_COUNT > 0 || DISK_FULL )); then exit 2; fi
    exit 0
}

main
