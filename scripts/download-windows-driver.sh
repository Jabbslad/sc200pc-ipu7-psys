#!/usr/bin/env bash
set -euo pipefail

readonly DRIVER_URL="https://downloadcenter.samsung.com/content/DR/202604/20260423085022390/BASW-A4296A0P_1063.ZIP"
readonly ARCHIVE_NAME="BASW-A4296A0P_1063.ZIP"
readonly EXPECTED_SHA256="8cdd2949b578befd9f4f0498b20f9e10e38c60314ded3e2b8fd6adb99e5dc0bb"

usage() {
    cat <<EOF
Usage: $(basename "$0") [DESTINATION]

Download and extract the Samsung OEM Windows camera package for local analysis.
DESTINATION defaults to <repository>/downloads/windows-driver.
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

if (( $# > 1 )); then
    usage >&2
    exit 2
fi

for command in curl sha256sum unzip; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Error: required command not found: $command" >&2
        exit 1
    fi
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
destination=${1:-"$repo_root/downloads/windows-driver"}
archive_path="$destination/$ARCHIVE_NAME"
extract_dir="$destination/extracted"
marker_name=".source-sha256"

tmp_archive=""
tmp_extract=""
cleanup() {
    [[ -z $tmp_archive ]] || rm -f -- "$tmp_archive"
    [[ -z $tmp_extract ]] || rm -rf -- "$tmp_extract"
}
trap cleanup EXIT

mkdir -p -- "$destination"

verify_archive() {
    local path=$1
    local actual_sha256
    actual_sha256=$(sha256sum "$path" | awk '{print $1}')
    if [[ $actual_sha256 != "$EXPECTED_SHA256" ]]; then
        echo "Error: checksum mismatch for $path" >&2
        echo "Expected: $EXPECTED_SHA256" >&2
        echo "Actual:   $actual_sha256" >&2
        return 1
    fi

    unzip -tq "$path" >/dev/null
}

if [[ -f $archive_path ]]; then
    echo "Using cached archive: $archive_path"
    verify_archive "$archive_path"
else
    tmp_archive=$(mktemp "$destination/.${ARCHIVE_NAME}.part.XXXXXX")
    echo "Downloading $DRIVER_URL"
    curl --fail --location --retry 3 --show-error \
        --proto '=https' --tlsv1.2 \
        --output "$tmp_archive" "$DRIVER_URL"
    verify_archive "$tmp_archive"
    mv -- "$tmp_archive" "$archive_path"
    tmp_archive=""
fi

echo "Verified SHA-256: $EXPECTED_SHA256"

if [[ -d $extract_dir ]]; then
    if [[ -f $extract_dir/$marker_name ]] &&
       [[ $(<"$extract_dir/$marker_name") == "$EXPECTED_SHA256" ]]; then
        echo "Using existing extraction: $extract_dir"
    else
        echo "Error: $extract_dir exists but was not created from the expected archive." >&2
        echo "Remove it manually after preserving any analysis work, then run this script again." >&2
        exit 1
    fi
else
    tmp_extract=$(mktemp -d "$destination/.extracted.XXXXXX")
    echo "Extracting to $extract_dir"
    unzip -q "$archive_path" -d "$tmp_extract"
    printf '%s\n' "$EXPECTED_SHA256" > "$tmp_extract/$marker_name"
    mv -- "$tmp_extract" "$extract_dir"
    tmp_extract=""
fi

cat <<EOF

Windows driver package is ready for local analysis:
  Archive:  $archive_path
  Extracted: $extract_dir

Review the OEM license in the extracted camera directory before using the files.
Do not redistribute the downloaded package unless you have permission to do so.
EOF
