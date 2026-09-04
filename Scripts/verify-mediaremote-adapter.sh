#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
manifest="$repo_root/Vendor/MediaRemoteAdapter.provenance.json"
framework=${1:-"$repo_root/Vendor/MediaRemoteAdapter.framework"}
expected_plist="$repo_root/Vendor/MediaRemoteAdapter.expected-Info.plist"
expected_exports="$repo_root/Vendor/MediaRemoteAdapter.expected-exports.txt"
binary="$framework/MediaRemoteAdapter"
plist="$framework/Resources/Info.plist"
code_resources="$framework/Versions/A/_CodeSignature/CodeResources"
loader_patch="$repo_root/Vendor/MediaRemoteAdapter-loader.patch"
capabilities_patch="$repo_root/Vendor/MediaRemoteAdapter-capabilities.patch"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/islet-mediaremote-verify.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

read_manifest() {
  jq -er "$1" "$manifest"
}

verify_sha256() {
  local expected=$1
  local path=$2
  printf '%s  %s\n' "$expected" "$path" | shasum -a 256 --check
}

test -x "$binary"
plutil -lint "$plist"
cmp "$expected_plist" "$plist"

actual_architectures=$(lipo -archs "$binary" | xargs -n 1 | LC_ALL=C sort | xargs)
expected_architectures=$(jq -r '.artifacts.slices | keys[]' "$manifest" | LC_ALL=C sort | xargs)
if [[ "$actual_architectures" != "$expected_architectures" ]]; then
  printf 'Expected architectures "%s", found "%s".\n' \
    "$expected_architectures" "$actual_architectures" >&2
  exit 1
fi

verify_sha256 "$(read_manifest '.artifacts.binarySHA256')" "$binary"
verify_sha256 "$(read_manifest '.artifacts.exportedSymbolsSHA256')" "$expected_exports"
verify_sha256 "$(read_manifest '.artifacts.infoPlistSHA256')" "$plist"
verify_sha256 "$(read_manifest '.artifacts.codeResourcesSHA256')" "$code_resources"
verify_sha256 "$(read_manifest '.artifacts.loaderSHA256')" \
  "$repo_root/Islet/Resources/mediaremote-adapter.pl"
verify_sha256 "$(read_manifest '.artifacts.loaderPatchSHA256')" "$loader_patch"
verify_sha256 "$(read_manifest '.artifacts.capabilitiesPatchSHA256')" "$capabilities_patch"
verify_sha256 "$(read_manifest '.artifacts.licenseSHA256')" \
  "$repo_root/Vendor/MediaRemoteAdapter-LICENSE"

for stream_capability_line in \
  'diff --git a/src/adapter/stream.m b/src/adapter/stream.m' \
  '+            liveData[kMRASupportsSeeking] = @(supportsSeeking);' \
  '+      requestSupportedCommands();'; do
  if ! /usr/bin/grep -Fqx "$stream_capability_line" "$capabilities_patch"; then
    printf 'Expected seek-capability stream wiring in adapter patch: %s\n' \
      "$stream_capability_line" >&2
    exit 1
  fi
done

binary_strings="$work_dir/MediaRemoteAdapter.strings"
strings "$binary" > "$binary_strings"
for capability in isLive supportsSeeking kMRMediaRemoteNowPlayingInfoIsAlwaysLive \
  MRMediaRemoteGetSupportedCommands MRMediaRemoteCommandInfoGetCommand \
  MRMediaRemoteCommandInfoGetEnabled; do
  if ! /usr/bin/grep -Fqx "$capability" "$binary_strings"; then
    printf 'Expected capability marker "%s" in adapter binary.\n' "$capability" >&2
    exit 1
  fi
done

while IFS= read -r architecture; do
  slice="$work_dir/MediaRemoteAdapter-$architecture"
  exports="$work_dir/MediaRemoteAdapter-$architecture.exports"
  lipo "$binary" -thin "$architecture" -output "$slice"
  verify_sha256 "$(read_manifest ".artifacts.slices.\"$architecture\"")" "$slice"
  nm -gjU -arch "$architecture" "$binary" | LC_ALL=C sort > "$exports"
  cmp "$expected_exports" "$exports"
done < <(jq -r '.artifacts.slices | keys[]' "$manifest" | LC_ALL=C sort)

codesign --verify --strict --verbose=2 "$framework"
printf 'Verified %s\n' "$framework"
