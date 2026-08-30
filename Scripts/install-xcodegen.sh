#!/bin/bash
set -euo pipefail

version="2.46.0"
checksum="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
install_prefix=${1:-"$PWD/.build-tools"}
archive_url="https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$install_prefix"
curl --fail --location --retry 3 --silent --show-error \
  "$archive_url" --output "$work_dir/xcodegen.zip"

printf '%s  %s\n' "$checksum" "$work_dir/xcodegen.zip" | shasum -a 256 --check
unzip -q "$work_dir/xcodegen.zip" -d "$work_dir/unpacked"
cp -R "$work_dir/unpacked/xcodegen/bin" "$install_prefix/"
cp -R "$work_dir/unpacked/xcodegen/share" "$install_prefix/"

"$install_prefix/bin/xcodegen" --version
