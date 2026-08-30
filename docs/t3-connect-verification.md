# T3 Connect verification

This record separates checks that need no T3 credentials from acceptance work that needs a real
T3 Connect account and environment. A command or checklist item is not evidence by itself. Record
the commit, date, result, and any skipped coverage when the check is run.

## Verification status

| Check | Status | Evidence |
|---|---|---|
| Pinned upstream contract review | Complete | `pingdotgg/t3code@2daff8c25adf701fddd062ae93b94cc57d420ec2` |
| No-credential production smoke | Passed on 2026-08-31 | Hosted page returned 200; relay inventory without authorization returned 401 |
| Local arm64 CI validation | Passed on 2026-08-31 | Source `42c0611b8e29cf5caed76e9b63a00af19627b207`: 985 passed, 0 failed, 1 expected Accessibility skip; provenance, generated plist, package pinning, arm64 slices, and static analysis passed |
| GitHub Intel validation | Pending | Required `Build and test (x86_64)` pull-request check |
| Credentialed real-account acceptance | Not run | Requires a human's T3 account, linked environment, and active agent |

Do not change the last row to passed unless a human completed every applicable credentialed step
and recorded the tested commit. Mocked requests and production reachability do not replace that
test.

## Pinned upstream contract

Islet implements the contract at
[`pingdotgg/t3code@2daff8c25adf701fddd062ae93b94cc57d420ec2`](https://github.com/pingdotgg/t3code/tree/2daff8c25adf701fddd062ae93b94cc57d420ec2).
Use immutable links during review:

- [`.env.example`](https://github.com/pingdotgg/t3code/blob/2daff8c25adf701fddd062ae93b94cc57d420ec2/.env.example)
  identifies the production Clerk client and relay URL as public configuration.
- [`connectAuth.ts`](https://github.com/pingdotgg/t3code/blob/2daff8c25adf701fddd062ae93b94cc57d420ec2/packages/shared/src/connectAuth.ts)
  defines the hosted authorization URL, scopes, and loopback callback shape.
- [`publicConfig.ts`](https://github.com/pingdotgg/t3code/blob/2daff8c25adf701fddd062ae93b94cc57d420ec2/apps/server/src/cloud/publicConfig.ts)
  derives the Clerk token endpoint and fixes loopback port 34338.
- [`CliTokenManager.ts`](https://github.com/pingdotgg/t3code/blob/2daff8c25adf701fddd062ae93b94cc57d420ec2/apps/server/src/cloud/CliTokenManager.ts)
  supplies the authorization-code and refresh exchange forms.
- [`environment-auth.md`](https://github.com/pingdotgg/t3code/blob/2daff8c25adf701fddd062ae93b94cc57d420ec2/docs/internals/environment-auth.md)
  records the environment token exchange, DPoP session method, and scope model.
- [`relay.ts`](https://github.com/pingdotgg/t3code/blob/2daff8c25adf701fddd062ae93b94cc57d420ec2/packages/contracts/src/relay.ts)
  defines the relay client identifier, exchange grant type, and environment-connect scope.

The production constants under review are:

| Purpose | Expected value |
|---|---|
| Hosted authorization page | `https://app.t3.codes/connect` |
| Clerk OAuth token endpoint | `https://clerk.t3.codes/oauth/token` |
| Public CLI OAuth client ID | `hzxSgY2cH10sDU2r` |
| Registered loopback callback | `http://127.0.0.1:34338/callback` |
| OAuth scopes | `openid profile email` |
| Relay origin | `https://relay.t3.codes` |
| Relay public client ID | `t3-web` |
| Environment scope | `orchestration:read` |

## No-credential production smoke

These checks send no token, proof, cookie, authorization code, or account data. They establish only
that the hosted route is reachable and the relay rejects an unauthenticated inventory request.
They do not validate a real OAuth or environment authorization flow.

```sh
hosted_result=$(
  curl --silent --show-error --location --max-time 15 \
    --output /dev/null --write-out '%{http_code} %{url_effective}' \
    https://app.t3.codes/connect
)
test "$hosted_result" = "200 https://app.t3.codes/connect"

relay_status=$(
  curl --silent --show-error --max-time 15 \
    --output /dev/null --write-out '%{http_code}' \
    https://relay.t3.codes/v1/environments
)
test "$relay_status" = "401"
```

Observed on 2026-08-31:

```text
hosted: 200 https://app.t3.codes/connect
relay without Authorization: 401
```

## Persisted-secret boundary

T3 Connect may add only these generic-password items under Keychain service `dev.islet`:

| Account | Contents | Removal |
|---|---|---|
| `t3-connect-oauth-v1` | Versioned OAuth grant with access token, refresh token, expiry, grant ID, and optional display identity; during interrupted cleanup, it may instead contain the exact non-secret marker `{"type":"t3-connect-sign-out-pending","version":1}` | T3 Connect sign-out |
| `t3-connect-dpop-p256-v1` | P-256 private signing key | T3 Connect sign-out |

Both items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. The existing
`read-only-environment-tokens-v1` item belongs to manual pairing. T3 Connect link, relink, failure,
and sign-out must not rewrite or delete it. Sign-out writes the pending-cleanup marker before
deleting the proof key, then removes the marker. If the process stops partway through, startup
treats the marker as signed out and retries cleanup before another account can be linked.

The following values must remain transient:

- OAuth state, PKCE verifier, and authorization code
- OIDC ID token
- relay DPoP access token
- relay-issued environment bootstrap credential
- environment DPoP access token
- DPoP proofs, `jti` values, and access-token hashes

Reviewers can check item existence without printing secret values:

```sh
security find-generic-password -s dev.islet -a t3-connect-oauth-v1 >/dev/null
security find-generic-password -s dev.islet -a t3-connect-dpop-p256-v1 >/dev/null
security find-generic-password -s dev.islet -a read-only-environment-tokens-v1 >/dev/null
```

Never add `-w` to those commands or paste Keychain values into test output, an issue, or a pull
request.

## Local arm64 CI validation

Run this block from a clean checkout of the final pull-request commit on Apple silicon. It mirrors
the repository's arm64 GitHub job, apart from `xcbeautify`, which changes only log presentation.
The workflow uses `macos-26`, Xcode 26.6, and XcodeGen 2.46.0.

```sh
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer

xcodebuild -version
swift --version
xcodegen --version

Scripts/verify-mediaremote-adapter.sh
Scripts/rebuild-mediaremote-adapter.sh
Scripts/verify-mediaremote-adapter.sh \
  Vendor/mediaremote-adapter-build/MediaRemoteAdapter.framework
diff --brief --recursive --no-dereference \
  Vendor/MediaRemoteAdapter.framework \
  Vendor/mediaremote-adapter-build/MediaRemoteAdapter.framework
cmp Islet/Resources/mediaremote-adapter.pl \
  Vendor/mediaremote-adapter-build/mediaremote-adapter.pl
cmp Vendor/MediaRemoteAdapter-LICENSE \
  Vendor/mediaremote-adapter-build/LICENSE

xcrun swift-format lint --strict --recursive Islet IsletTests Tools
xcrun swiftc -typecheck Tools/islet-pulse.swift
jq empty Integrations/Pulse/providers.json Integrations/Pulse/pulse-command.schema.json
sh -n Integrations/Pulse/examples/github-actions.sh Scripts/*.sh

xcodegen generate
ISLET_RESOLVED_DIR="$PWD/Islet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$ISLET_RESOLVED_DIR"
install -m 0644 Package.resolved "$ISLET_RESOLVED_DIR/Package.resolved"
git diff --exit-code -- Islet/Info.plist

xcodebuild -resolvePackageDependencies \
  -project Islet.xcodeproj \
  -scheme Islet \
  -derivedDataPath "$PWD/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile
cmp Package.resolved "$ISLET_RESOLVED_DIR/Package.resolved"

xcodebuild -quiet \
  -project Islet.xcodeproj \
  -scheme Islet \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/DerivedData" \
  -disableAutomaticPackageResolution \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  test

app="$PWD/DerivedData/Build/Products/Debug/Islet.app"
framework="$app/Contents/Frameworks/MediaRemoteAdapter.framework/MediaRemoteAdapter"
lipo "$app/Contents/MacOS/Islet" -verify_arch arm64
lipo "$framework" -verify_arch arm64

xcodebuild -quiet \
  -project Islet.xcodeproj \
  -scheme Islet \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$PWD/DerivedData" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  analyze

git diff --check
```

XcodeGen recreates the ignored `Islet.xcodeproj`, but it also regenerates the tracked
`Islet/Info.plist`. The explicit diff check catches project metadata drift. The workspace copy of
`Package.resolved` is ignored, so seed it from the tracked root file before resolution and compare
the two files afterward. Keep the same DerivedData path for package resolution, tests, and static
analysis.

After the test command, inspect the newest result bundle rather than relying on quiet console
output:

```sh
RESULT_BUNDLE=$(
  find DerivedData/Logs/Test -maxdepth 1 -type d -name '*.xcresult' -print \
    | sort \
    | tail -1
)
xcrun xcresulttool get test-results summary \
  --path "$RESULT_BUNDLE" --compact \
  | jq '{result, passedTests, failedTests, skippedTests, totalTestCount}'
xcrun xcresulttool get test-results tests \
  --path "$RESULT_BUNDLE" --compact \
  | jq -r '.. | objects | select(.nodeType? == "Test Case" and .result? == "Skipped") | .nodeIdentifier'
```

The final local run must report zero failures. On a host without Accessibility access, the one
known skip is `LiveActivityAXReaderIntegrationTests/testReadsTheLiveMenuBar()`. Investigate any
failure, additional skip, generated plist change, package mismatch, provenance mismatch, or wrong
binary architecture before opening the pull request.

After committing the documentation and any final fixes, check the complete branch rather than only
the clean working tree:

```sh
git diff --check origin/main...HEAD
git status --short
```

The final status should be empty apart from ignored generated artifacts.

## GitHub Intel validation

The required `Build and test (x86_64)` GitHub job provides the Intel result. It resolves the pinned
packages, runs the complete suite with `ARCHS=x86_64` and `ONLY_ACTIVE_ARCH=NO`, and verifies the
application and embedded MediaRemoteAdapter products with `lipo`. Do not describe local arm64
coverage as full CI parity; record the pull-request check result separately.

## Credentialed manual acceptance

Status: not run as of 2026-08-31.

Use a real T3 Connect account with at least one relay-managed environment. Prepare a verified local
T3 process, an active agent, and a manual pairing before starting. To test source precedence, pair
one environment that has the same logical environment ID as a linked environment. Record the
tested Islet commit, T3 Code version, tester, date, and environment types without recording account
identifiers or credentials.

- [ ] Start Islet with T3 monitoring enabled. Confirm the verified local row and existing manual
  rows work while signed out.
- [ ] Choose `Link T3 Connect account`. Confirm Islet starts the callback listener before opening
  `https://app.t3.codes/connect`, the callback completes, and the account is not shown as linked
  until the first relay inventory succeeds.
- [ ] Confirm every expected linked environment appears with a cloud source and no manual enable or
  delete controls. Confirm an active agent reaches the notch while Islet remains read-only.
- [ ] Confirm unrelated local, linked, and manual environments coexist. For a duplicated logical
  environment, confirm Islet publishes one row, prefers a connected verified local source, then
  fails over to T3 Connect and manual pairing as the preferred sources become unavailable.
- [ ] Relaunch Islet and confirm it loads the saved account identity even when T3 monitoring is
  disabled. An immediate relaunch tests persistence only. To test refresh, leave Islet running or
  relaunch after the account access token enters its five-minute refresh window, then confirm
  inventory and monitoring continue without another browser sign-in.
- [ ] Temporarily deny only `relay.t3.codes` with the tester's network filter. Confirm the last good
  cloud inventory remains visible with an unavailable state and local and manual polling continue.
  Restore access, choose `Reconnect now`, and confirm inventory recovers.
- [ ] Start a relink, then cancel it or make the first inventory fail. Confirm the previously usable
  account and cloud inventory remain intact.
- [ ] Choose Sign Out and confirm the dialog says local and manually paired machines remain. Confirm
  cloud rows disappear, do not return from suspended work, and the local and manual rows still
  monitor agents.
- [ ] Confirm `t3-connect-oauth-v1` and `t3-connect-dpop-p256-v1` are absent after sign-out. Confirm
  `read-only-environment-tokens-v1` and its manual pairing still work.

## Pull-request evidence

Record these facts in the pull request:

- final commit and the pinned upstream T3 commit
- Xcode, Swift, and XcodeGen versions
- full XCTest passed, failed, and skipped counts, including the known skip name
- successful strict format, tool typecheck, JSON parse, shell parse, XcodeGen, package lock, and
  static-analysis checks
- no-credential hosted-page and relay-rejection results with their date
- persisted-secret boundary and exact `orchestration:read` environment scope
- credentialed acceptance result, or the explicit statement that it was not run because it needs a
  human's T3 account and environment
