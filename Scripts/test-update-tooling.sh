#!/bin/bash
set -euo pipefail

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
plist="$work_dir/Info.plist"
plist_buddy=/usr/libexec/PlistBuddy
valid_public_key="11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="

plutil -create xml1 "$plist"
"$plist_buddy" -c 'Add :CFBundleIdentifier string dev.islet' "$plist"
"$plist_buddy" -c \
  'Add :SUFeedURL string https://github.com/C-Nucifora/islet/releases/latest/download/appcast.xml' \
  "$plist"
"$plist_buddy" -c "Add :SUPublicEDKey string $valid_public_key" "$plist"
"$plist_buddy" -c 'Add :SURequireSignedFeed bool true' "$plist"
"$plist_buddy" -c 'Add :SUVerifyUpdateBeforeExtraction bool true' "$plist"
"$plist_buddy" -c 'Add :SUSignedFeedFailureExpirationInterval integer 0' "$plist"
"$plist_buddy" -c 'Add :SUAutomaticallyUpdate bool false' "$plist"
"$plist_buddy" -c 'Add :SUShowReleaseNotes bool true' "$plist"
"$plist_buddy" -c 'Add :IsletUpdateChannel string stable' "$plist"
Scripts/validate-update-config.sh "$plist"

"$plist_buddy" -c 'Set :SUFeedURL http://example.com/appcast.xml' "$plist"
if Scripts/validate-update-config.sh "$plist" >/dev/null 2>&1; then
  echo "The validator accepted an insecure feed." >&2
  exit 1
fi
"$plist_buddy" -c \
  'Set :SUFeedURL https://github.com/C-Nucifora/islet/releases/latest/download/appcast.xml' \
  "$plist"

"$plist_buddy" -c 'Set :SUFeedURL https://updates.example.com/islet/appcast.xml' "$plist"
if Scripts/validate-update-config.sh "$plist" >/dev/null 2>&1; then
  echo "The validator accepted an unexpected HTTPS feed." >&2
  exit 1
fi
"$plist_buddy" -c \
  'Set :SUFeedURL https://github.com/C-Nucifora/islet/releases/latest/download/appcast.xml' \
  "$plist"

"$plist_buddy" -c 'Set :SUPublicEDKey CONFIGURATION_REQUIRED' "$plist"
if Scripts/validate-update-config.sh "$plist" >/dev/null 2>&1; then
  echo "The validator accepted an unconfigured public key." >&2
  exit 1
fi
"$plist_buddy" -c "Set :SUPublicEDKey $valid_public_key" "$plist"

"$plist_buddy" -c 'Set :SURequireSignedFeed false' "$plist"
if Scripts/validate-update-config.sh "$plist" >/dev/null 2>&1; then
  echo "The validator accepted an unsigned feed." >&2
  exit 1
fi
"$plist_buddy" -c 'Set :SURequireSignedFeed true' "$plist"

"$plist_buddy" -c 'Set :SUVerifyUpdateBeforeExtraction false' "$plist"
if Scripts/validate-update-config.sh "$plist" >/dev/null 2>&1; then
  echo "The validator accepted verification after extraction." >&2
  exit 1
fi
"$plist_buddy" -c 'Set :SUVerifyUpdateBeforeExtraction true' "$plist"

"$plist_buddy" -c 'Set :SUSignedFeedFailureExpirationInterval 1' "$plist"
if Scripts/validate-update-config.sh "$plist" >/dev/null 2>&1; then
  echo "The validator accepted an expiring signed-feed failure." >&2
  exit 1
fi
"$plist_buddy" -c 'Set :SUSignedFeedFailureExpirationInterval 0' "$plist"

"$plist_buddy" -c 'Set :SUAutomaticallyUpdate true' "$plist"
if Scripts/validate-update-config.sh "$plist" >/dev/null 2>&1; then
  echo "The validator accepted automatic installation by default." >&2
  exit 1
fi
"$plist_buddy" -c 'Set :SUAutomaticallyUpdate false' "$plist"

"$plist_buddy" -c 'Set :SUShowReleaseNotes false' "$plist"
if Scripts/validate-update-config.sh "$plist" >/dev/null 2>&1; then
  echo "The validator accepted hidden release notes." >&2
  exit 1
fi
"$plist_buddy" -c 'Set :SUShowReleaseNotes true' "$plist"

"$plist_buddy" -c 'Add :SUEnableAutomaticChecks bool true' "$plist"
if Scripts/validate-update-config.sh "$plist" >/dev/null 2>&1; then
  echo "The validator accepted forced automatic checks." >&2
  exit 1
fi

grep -Fq 'exactVersion: 2.9.6' project.yml
grep -Fq 'SURequireSignedFeed: true' project.yml
grep -Fq 'SUVerifyUpdateBeforeExtraction: true' project.yml
grep -Fq 'SUSignedFeedFailureExpirationInterval: 0' project.yml
if grep -Fq 'SUEnableAutomaticChecks:' project.yml; then
  echo "project.yml must leave automatic checks to Sparkle's permission prompt." >&2
  exit 1
fi
grep -Eq \
  '^ISLET_UPDATE_PUBLIC_ED_KEY = (CONFIGURATION_REQUIRED|[A-Za-z0-9+/]{43}=)$' \
  Config/Update.xcconfig

if [[ -n "${ISLET_GENERATED_INFO_PLIST:-}" ]]; then
  Scripts/validate-update-config.sh "$ISLET_GENERATED_INFO_PLIST"
fi
grep -Fq 'SPARKLE_ED25519_PRIVATE_KEY' .github/workflows/release.yml
grep -Fq -- '--ed-key-file -' .github/workflows/release.yml
grep -Fq -- '--draft' .github/workflows/release.yml
grep -Fq 'repos/$GITHUB_REPOSITORY/immutable-releases' .github/workflows/release.yml
grep -Fq 'actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6' \
  .github/workflows/release.yml
grep -Fq 'release-manifest.json' .github/workflows/release.yml
grep -Fq 'signedFeedFailureExpirationKey' Islet/Support/AppUpdateController.swift
grep -Fq 'clearFeedURLFromUserDefaults()' Islet/Support/AppUpdateController.swift
grep -Fq 'feedURLString(for updater: SPUUpdater)' Islet/Support/AppUpdateController.swift
grep -Fq 'Curve25519.Signing.PrivateKey' .github/workflows/release.yml
grep -Fq 'refs/tags/v*' .github/workflows/release.yml
grep -Fq 'git cat-file -t "$GITHUB_REF_NAME"' .github/workflows/release.yml
