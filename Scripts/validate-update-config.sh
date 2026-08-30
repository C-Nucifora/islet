#!/bin/bash
set -euo pipefail

plist=${1:?usage: validate-update-config.sh INFO_PLIST [EXPECTED_BUNDLE_IDENTIFIER]}
expected_bundle_identifier=${2:-dev.islet}
expected_feed="https://github.com/C-Nucifora/islet/releases/latest/download/appcast.xml"
plist_buddy=/usr/libexec/PlistBuddy
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

fail() {
  echo "Invalid update configuration: $*" >&2
  exit 1
}

read_value() {
  "$plist_buddy" -c "Print :$1" "$plist" 2>/dev/null || fail "missing $1"
}

[[ -f "$plist" ]] || fail "Info.plist does not exist: $plist"

bundle_identifier=$(read_value CFBundleIdentifier)
[[ "$bundle_identifier" == "$expected_bundle_identifier" ]] ||
  fail "CFBundleIdentifier must be $expected_bundle_identifier"

feed_url=$(read_value SUFeedURL)
[[ "$feed_url" == "$expected_feed" ]] || fail "SUFeedURL must be the stable HTTPS release feed"
[[ "$feed_url" != *"@"* ]] || fail "SUFeedURL must not contain credentials"

public_key=$(read_value SUPublicEDKey)
[[ "$public_key" != "CONFIGURATION_REQUIRED" ]] || fail "SUPublicEDKey is not configured"
[[ "$public_key" != *[[:space:]]* ]] || fail "SUPublicEDKey contains whitespace"
if ! printf '%s' "$public_key" | base64 --decode > "$work_dir/public-key" 2>/dev/null; then
  fail "SUPublicEDKey is not valid base64"
fi
[[ "$(wc -c < "$work_dir/public-key" | tr -d ' ')" == "32" ]] ||
  fail "SUPublicEDKey must decode to 32 bytes"

[[ "$(read_value SURequireSignedFeed)" == "true" ]] || fail "signed feeds are required"
[[ "$(read_value SUVerifyUpdateBeforeExtraction)" == "true" ]] ||
  fail "archives must be verified before extraction"
[[ "$(read_value SUSignedFeedFailureExpirationInterval)" == "0" ]] ||
  fail "signed feed failures must never expire"
[[ "$(read_value SUAutomaticallyUpdate)" == "false" ]] ||
  fail "automatic installation must be disabled by default"
[[ "$(read_value SUShowReleaseNotes)" == "true" ]] || fail "release notes must be shown"
[[ "$(read_value IsletUpdateChannel)" == "stable" ]] || fail "unsupported update channel"

if "$plist_buddy" -c "Print :SUEnableAutomaticChecks" "$plist" >/dev/null 2>&1; then
  fail "SUEnableAutomaticChecks must be absent so Sparkle asks the user for permission"
fi
