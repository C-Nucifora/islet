#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
catalog="${ISLET_LOCALIZATION_CATALOG:-$repo_root/Islet/Resources/Localizable.xcstrings}"
derived_data="$(mktemp -d /tmp/islet-localization-derived.XXXXXX)"
catalog_copy="$derived_data/Localizable.xcstrings"

cleanup() {
  rm -rf "$derived_data"
}
trap cleanup EXIT

cp "$catalog" "$catalog_copy"

xcodebuild \
  -project "$repo_root/Islet.xcodeproj" \
  -scheme Islet \
  -configuration Debug \
  -derivedDataPath "$derived_data" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  SWIFT_EMIT_LOC_STRINGS=YES \
  build >/dev/null

stringsdata=()
while IFS= read -r -d '' file; do
  stringsdata+=("$file")
done < <(find "$derived_data/Build/Intermediates.noindex/Islet.build" -name '*.stringsdata' -print0)

if [[ ${#stringsdata[@]} -eq 0 ]]; then
  echo "No compiler localization records were produced." >&2
  exit 1
fi

xcrun xcstringstool sync "$catalog_copy" \
  --stringsdata "${stringsdata[@]}"

stale_keys="$({
  jq -r '.strings | to_entries[] | select(.value.extractionState == "stale") | .key' \
    "$catalog_copy"
} || true)"

if [[ -n "$stale_keys" ]]; then
  echo "Catalog drift detected. Keys no longer present in compiler extraction:" >&2
  echo "$stale_keys" >&2
  exit 1
fi

missing_pseudo="$({
  jq -r '.strings | to_entries[] | select(.value.localizations["en-XA"] == null) | .key' \
    "$catalog_copy"
} || true)"

if [[ -n "$missing_pseudo" ]]; then
  echo "Catalog drift detected. Extracted keys without en-XA coverage:" >&2
  echo "$missing_pseudo" >&2
  exit 1
fi

echo "Localization catalog matches compiler extraction and every extracted key has en-XA coverage."
