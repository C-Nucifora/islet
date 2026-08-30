#!/bin/bash
set -euo pipefail

version="1.7.12"
install_prefix=${1:-"$PWD/.build-tools"}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

case "$(uname -m)" in
  arm64)
    architecture="arm64"
    checksum="aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f"
    ;;
  x86_64)
    architecture="amd64"
    checksum="5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644"
    ;;
  *)
    echo "Unsupported actionlint architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

archive_name="actionlint_${version}_darwin_${architecture}.tar.gz"
archive_url="https://github.com/rhysd/actionlint/releases/download/v${version}/${archive_name}"
archive="$work_dir/$archive_name"

curl --fail --location --retry 3 --silent --show-error "$archive_url" --output "$archive"
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 --check
tar -xzf "$archive" -C "$work_dir" actionlint
mkdir -p "$install_prefix/bin"
install -m 0755 "$work_dir/actionlint" "$install_prefix/bin/actionlint"
"$install_prefix/bin/actionlint" -version
