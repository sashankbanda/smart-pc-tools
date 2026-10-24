#!/usr/bin/env bash
#
# Copy iPhone media files (.MOV, .JPG, .HEIC, .PNG, .MP4 by default) from a source folder
# to a destination folder.
#
# NOTE: this only works when the source is a real filesystem path - a mounted
# drive, an SD card, or a folder already copied off the phone. A cabled iPhone
# shows up as an MTP device ("This PC\Apple iPhone\Internal Storage"), which
# has no filesystem path; use Copy-IPhoneMedia.ps1 for that.
#
# Usage:
#   ./copy_iphone_media.sh SOURCE DESTINATION [options]
#
#   -e "mov jpg heic"   extensions to copy (default: mov jpg heic png mp4)
#   -f "2024*"          which sub-folders to enter (default: all)
#   -F                  flat: no sub-folders in the destination
#   -n                  dry run
#
# Example:
#   ./copy_iphone_media.sh /mnt/e/DCIM ~/Photos/iphone -f "2024*"

set -euo pipefail

extensions="mov jpg heic png mp4"
folders="*"
flat=false
dry_run=false

usage() {
    sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# --- arguments -------------------------------------------------------------

positional=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e) extensions="$2"; shift 2 ;;
        -f) folders="$2";    shift 2 ;;
        -F) flat=true;       shift ;;
        -n) dry_run=true;    shift ;;
        -h|--help) usage 0 ;;
        -*) echo "Unknown option: $1" >&2; usage 1 ;;
        *)  positional+=("$1"); shift ;;
    esac
done

if [[ ${#positional[@]} -ne 2 ]]; then
    usage 1
fi

source_dir="${positional[0]%/}"
dest_dir="${positional[1]%/}"

if [[ ! -d "$source_dir" ]]; then
    echo "Source directory not found: $source_dir" >&2
    exit 1
fi

# --- find the files --------------------------------------------------------

# Build the -iname predicates for `find`: ( -iname '*.mov' -o -iname '*.jpg' ... )
name_filter=()
for extension in $extensions; do
    extension="${extension#.}"
    if [[ ${#name_filter[@]} -gt 0 ]]; then
        name_filter+=(-o)
    fi
    name_filter+=(-iname "*.${extension}")
done

# Files directly in the source, plus everything under matching sub-folders.
search_dirs=("$source_dir")
while IFS= read -r -d '' directory; do
    search_dirs+=("$directory")
done < <(find "$source_dir" -mindepth 1 -maxdepth 1 -type d -name "$folders" -print0 | sort -z)

files=()
while IFS= read -r -d '' file; do
    files+=("$file")
done < <(
    {
        find "$source_dir" -maxdepth 1 -type f \( "${name_filter[@]}" \) -print0
        for directory in "${search_dirs[@]:1}"; do
            find "$directory" -type f \( "${name_filter[@]}" \) -print0
        done
    } | sort -z
)

if [[ ${#files[@]} -eq 0 ]]; then
    echo "No $extensions files found in $source_dir"
    exit 0
fi

total=${#files[@]}
echo "Found $total file(s)"
echo

# --- copy ------------------------------------------------------------------

copied=0
skipped=0
failed=0
index=0

for file in "${files[@]}"; do
    index=$((index + 1))
    relative="${file#"$source_dir"/}"

    if $flat; then
        target="$dest_dir/$(basename "$file")"
    else
        target="$dest_dir/$relative"
    fi

    if [[ -f "$target" ]] && [[ "$(stat -c %s "$file")" == "$(stat -c %s "$target")" ]]; then
        echo "[$index/$total] skip (already there) $(basename "$file")"
        skipped=$((skipped + 1))
        continue
    fi

    size=$(du -h "$file" | cut -f1)
    echo "[$index/$total] $(basename "$file") -> $target ($size)"

    if $dry_run; then
        continue
    fi

    mkdir -p "$(dirname "$target")"
    if cp -p "$file" "$target"; then
        copied=$((copied + 1))
    else
        echo "    failed to copy"
        failed=$((failed + 1))
    fi
done

echo
if $dry_run; then
    echo "Dry run: $((total - skipped)) file(s) would be copied, $skipped skipped"
else
    echo "Copied $copied file(s), skipped $skipped, failed $failed"
fi
