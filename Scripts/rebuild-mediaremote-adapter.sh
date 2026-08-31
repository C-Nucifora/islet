#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
manifest="$repo_root/Vendor/MediaRemoteAdapter.provenance.json"
loader_patch="$repo_root/Vendor/MediaRemoteAdapter-loader.patch"
cache_dir=${MEDIAREMOTE_ADAPTER_DOWNLOAD_CACHE:-"$repo_root/Vendor/mediaremote-adapter-src"}
output_dir="$repo_root/Vendor/mediaremote-adapter-build"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/islet-mediaremote-adapter.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

read_manifest() {
  jq -er "$1" "$manifest"
}

verify_sha256() {
  local expected=$1
  local path=$2
  printf '%s  %s\n' "$expected" "$path" | shasum -a 256 --check
}

source_commit=$(read_manifest '.source.commit')
source_url=$(read_manifest '.source.archiveURL')
source_checksum=$(read_manifest '.source.archiveSHA256')
cmake_version=$(read_manifest '.toolchain.cmakeVersion')
cmake_url=$(read_manifest '.toolchain.cmakeArchiveURL')
cmake_checksum=$(read_manifest '.toolchain.cmakeArchiveSHA256')
xcode_version=$(read_manifest '.toolchain.xcodeVersion')
xcode_build=$(read_manifest '.toolchain.xcodeBuild')
sdk_version=$(read_manifest '.toolchain.macOSSDKVersion')
sdk_build=$(read_manifest '.toolchain.macOSSDKBuild')
clang_version=$(read_manifest '.toolchain.clangVersion')
make_version=$(read_manifest '.toolchain.makeVersion')
generator=$(read_manifest '.toolchain.generator')
deployment_target=$(read_manifest '.toolchain.deploymentTarget')
loader_patch_checksum=$(read_manifest '.artifacts.loaderPatchSHA256')

actual_xcode=$(xcodebuild -version)
expected_xcode=$(printf 'Xcode %s\nBuild version %s' "$xcode_version" "$xcode_build")
if [[ "$actual_xcode" != "$expected_xcode" ]]; then
  printf 'Expected %s, found:\n%s\n' "$expected_xcode" "$actual_xcode" >&2
  exit 1
fi

if [[ "$(xcrun --sdk macosx --show-sdk-version)" != "$sdk_version" ]] ||
  [[ "$(xcrun --sdk macosx --show-sdk-build-version)" != "$sdk_build" ]]; then
  printf 'Expected macOS SDK %s (%s).\n' "$sdk_version" "$sdk_build" >&2
  exit 1
fi

if [[ "$(xcrun clang --version | sed -n '1p')" != "$clang_version" ]]; then
  printf 'Expected compiler: %s\n' "$clang_version" >&2
  exit 1
fi

if [[ "$(/usr/bin/make --version | sed -n '1p')" != "$make_version" ]]; then
  printf 'Expected build tool: %s\n' "$make_version" >&2
  exit 1
fi

mkdir -p "$cache_dir"
source_archive="$cache_dir/mediaremote-adapter-$source_commit.tar.gz"
cmake_archive="$cache_dir/cmake-$cmake_version-macos-universal.tar.gz"

if [[ ! -f "$source_archive" ]]; then
  curl --fail --location --proto '=https' --proto-redir '=https' --retry 3 --silent --show-error \
    "$source_url" --output "$source_archive"
fi
verify_sha256 "$source_checksum" "$source_archive"

if [[ ! -f "$cmake_archive" ]]; then
  curl --fail --location --proto '=https' --proto-redir '=https' --retry 3 --silent --show-error \
    "$cmake_url" --output "$cmake_archive"
fi
verify_sha256 "$cmake_checksum" "$cmake_archive"

tar -xzf "$source_archive" -C "$work_dir"
tar -xzf "$cmake_archive" -C "$work_dir"
source_dir="$work_dir/mediaremote-adapter-$source_commit"
cmake_bin="$work_dir/cmake-$cmake_version-macos-universal/CMake.app/Contents/bin/cmake"

if [[ "$("$cmake_bin" --version | sed -n '1p')" != "cmake version $cmake_version" ]]; then
  printf 'Downloaded CMake did not report version %s.\n' "$cmake_version" >&2
  exit 1
fi

"$cmake_bin" -E remove_directory "$output_dir"
"$cmake_bin" -S "$source_dir" -B "$output_dir" -G "$generator" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target"
"$cmake_bin" --build "$output_dir" --parallel
install -m 0755 "$source_dir/bin/mediaremote-adapter.pl" \
  "$output_dir/mediaremote-adapter.pl"
verify_sha256 "$loader_patch_checksum" "$loader_patch"
/usr/bin/patch --batch --forward -F 0 --strip=1 --directory="$output_dir" \
  < "$loader_patch"
install -m 0644 "$source_dir/LICENSE" "$output_dir/LICENSE"

printf 'Built %s\n' "$output_dir/MediaRemoteAdapter.framework"
