#!/bin/bash
set -euo pipefail

if [[ $# -ne 10 ]]; then
  echo "usage: verify-release-assets.sh APP ARCHIVE APPCAST CHECKSUM MANIFEST TAG COMMIT VERSION BUILD TEAM_ID" >&2
  exit 64
fi

app=$1
archive=$2
appcast=$3
checksum_file=$4
manifest=$5
tag=$6
commit=$7
version=$8
build=$9
team_identifier=${10}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

fail() {
  echo "Release validation failed: $*" >&2
  exit 1
}

for required_file in "$app/Contents/Info.plist" "$archive" "$appcast" "$checksum_file" "$manifest"; do
  [[ -e "$required_file" ]] || fail "missing $required_file"
done

Scripts/validate-update-config.sh "$app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$app"
[[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] || fail "Sparkle.framework is missing"

plist_buddy=/usr/libexec/PlistBuddy
[[ "$("$plist_buddy" -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]] ||
  fail "bundle display version does not match the tag"
[[ "$("$plist_buddy" -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" == "$build" ]] ||
  fail "bundle build does not match the tagged commit"

actual_team=$(
  codesign --display --verbose=4 "$app" 2>&1 |
    sed -n 's/^TeamIdentifier=//p'
)
[[ "$actual_team" == "$team_identifier" ]] || fail "unexpected Developer ID team"

checksum_directory=$(dirname "$checksum_file")
checksum_name=$(basename "$checksum_file")
(cd "$checksum_directory" && shasum -a 256 --check "$checksum_name")
expected_checksum_names=$(
  printf '%s\n' "$(basename "$archive")" "$(basename "$appcast")" "$(basename "$manifest")" |
    sort
)
actual_checksum_names=$(awk '{print $2}' "$checksum_file" | sed 's/^\*//' | sort)
[[ "$actual_checksum_names" == "$expected_checksum_names" ]] ||
  fail "checksum file must cover exactly the archive, appcast, and manifest"

ditto -x -k "$archive" "$work_dir/extracted"
[[ -d "$work_dir/extracted/Islet.app" ]] || fail "archive does not contain Islet.app"
if find "$work_dir/extracted" -mindepth 1 -maxdepth 1 \
  ! -name Islet.app ! -name __MACOSX -print -quit | grep -q .; then
  fail "archive contains unexpected top-level files"
fi
codesign --verify --deep --strict --verbose=2 "$work_dir/extracted/Islet.app"
cmp "$app/Contents/Info.plist" "$work_dir/extracted/Islet.app/Contents/Info.plist"

xmllint --noout "$appcast"
item_count=$(xmllint --xpath 'count(/rss/channel/item)' "$appcast")
[[ "$item_count" == "1" ]] || fail "appcast must contain exactly one release"

appcast_build=$(
  xmllint --xpath 'string(/rss/channel/item/*[local-name()="version"])' "$appcast"
)
appcast_version=$(
  xmllint --xpath 'string(/rss/channel/item/*[local-name()="shortVersionString"])' "$appcast"
)
enclosure_url=$(xmllint --xpath 'string(/rss/channel/item/enclosure/@url)' "$appcast")
enclosure_length=$(xmllint --xpath 'string(/rss/channel/item/enclosure/@length)' "$appcast")
enclosure_signature=$(
  xmllint --xpath 'string(/rss/channel/item/enclosure/@*[local-name()="edSignature"])' "$appcast"
)
release_notes=$(xmllint --xpath 'string(/rss/channel/item/description)' "$appcast")
appcast_channel=$(
  xmllint --xpath 'string(/rss/channel/item/*[local-name()="channel"])' "$appcast"
)

archive_name=$(basename "$archive")
expected_url="https://github.com/C-Nucifora/islet/releases/download/$tag/$archive_name"
archive_size=$(stat -f %z "$archive")
[[ "$appcast_build" == "$build" ]] || fail "appcast build does not match the app"
[[ "$appcast_version" == "$version" ]] || fail "appcast display version does not match the tag"
[[ "$enclosure_url" == "$expected_url" ]] || fail "appcast archive URL is not tag-immutable"
[[ "$enclosure_length" == "$archive_size" ]] || fail "appcast archive length is wrong"
[[ -n "$release_notes" ]] || fail "appcast has no embedded release notes"
[[ -z "$appcast_channel" ]] || fail "stable appcast entries must use Sparkle's default channel"
[[ -n "$enclosure_signature" ]] || fail "appcast archive has no EdDSA signature"
if ! printf '%s' "$enclosure_signature" | base64 --decode > "$work_dir/signature" 2>/dev/null; then
  fail "appcast archive signature is not valid base64"
fi
[[ "$(wc -c < "$work_dir/signature" | tr -d ' ')" == "64" ]] ||
  fail "appcast archive signature must decode to 64 bytes"
grep -q '<!-- sparkle-signatures:' "$appcast" || fail "appcast feed is not signed"

archive_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
appcast_sha=$(shasum -a 256 "$appcast" | awk '{print $1}')
archive_size_json=$(stat -f %z "$archive")
appcast_size_json=$(stat -f %z "$appcast")

jq -e \
  --arg tag "$tag" \
  --arg commit "$commit" \
  --arg version "$version" \
  --arg build "$build" \
  --arg team_identifier "$team_identifier" \
  --arg archive_name "$archive_name" \
  --arg archive_sha "$archive_sha" \
  --argjson archive_size "$archive_size_json" \
  --arg appcast_sha "$appcast_sha" \
  --argjson appcast_size "$appcast_size_json" \
  '.schemaVersion == 1
    and .repository == "C-Nucifora/islet"
    and .tag == $tag
    and .commit == $commit
    and .version == $version
    and .build == $build
    and .bundleIdentifier == "dev.islet"
    and .developerIDTeamIdentifier == $team_identifier
    and .channel == "stable"
    and .artifacts.archive.name == $archive_name
    and .artifacts.archive.sha256 == $archive_sha
    and .artifacts.archive.size == $archive_size
    and .artifacts.appcast.name == "appcast.xml"
    and .artifacts.appcast.sha256 == $appcast_sha
    and .artifacts.appcast.size == $appcast_size' \
  "$manifest" >/dev/null || fail "release manifest does not match the exact artifacts"
