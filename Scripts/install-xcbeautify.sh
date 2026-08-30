#!/bin/bash
set -euo pipefail

version="3.2.1"
checksum="87fdbe786f71d7b2ee28c5c1ca97087587292f2c5c6f9e721cf02db8b2a3c241"
install_prefix=${1:-"$PWD/.build-tools"}
archive_cache=${2:-}
archive_url="https://github.com/cpisciotta/xcbeautify/releases/download/$version/xcbeautify-$version-universal-apple-macosx.zip"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$install_prefix/bin"
if [[ -n "$archive_cache" ]]; then
  mkdir -p "$archive_cache"
  archive_path="$archive_cache/xcbeautify-$version-universal-apple-macosx.zip"
else
  archive_path="$work_dir/xcbeautify.zip"
fi

if [[ ! -f "$archive_path" ]]; then
  curl --fail --location --retry 3 --silent --show-error \
    "$archive_url" --output "$archive_path"
fi

printf '%s  %s\n' "$checksum" "$archive_path" | shasum -a 256 --check
unzip -q "$archive_path" -d "$work_dir/unpacked"
install -m 0755 "$work_dir/unpacked/release/xcbeautify" "$install_prefix/bin/xcbeautify"

"$install_prefix/bin/xcbeautify" --version
