# Releasing Islet

Islet uses Sparkle 2.9.6 for in-app updates. The Swift package is pinned to an exact version in
`project.yml` and to an exact revision in `Package.resolved`. A release contains a notarized app
archive, a signed `appcast.xml`, a manifest, and `SHA256SUMS`. The release workflow derives the app
version from the tag and the build number from the exact tagged commit.

The workflow intentionally stops before publication unless every release prerequisite below is
present. This repository does not contain an update-signing private key.

Before tagging a release, validate the bundled Pulse Shortcuts starter kit. The importability check
uses the macOS Shortcuts parser and does not add anything to your library:

```sh
Scripts/validate-pulse-shortcuts.sh --verify-importability
```

## Update behavior and trust boundary

`SPUStandardUpdaterController` provides Sparkle's standard release-notes, download-progress,
installation, and relaunch interface. Islet adds a Settings page that shows the current version,
stable channel, last check, and current update state. It also provides a manual Check for Updates
button.

The app does not set `SUEnableAutomaticChecks`. Sparkle therefore asks the user for permission on
the second launch instead of silently enabling network checks. The Settings toggle changes the
same Sparkle preference only after direct user input. `SUAutomaticallyUpdate` remains false, so
downloaded updates are not installed without Sparkle's user-facing install and relaunch flow.

Every distributable build must contain all of these settings:

- An HTTPS `SUFeedURL` without credentials.
- A 32-byte Ed25519 public key in `SUPublicEDKey`.
- `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` set to true, with
  `SUSignedFeedFailureExpirationInterval` set to zero so invalid feed signatures never age out.
- `SUAutomaticallyUpdate` set to false and `SUEnableAutomaticChecks` absent.
- The stable channel and visible release notes.

`Config/Update.xcconfig` initially contains `CONFIGURATION_REQUIRED` instead of a public key. The
app refuses to start the updater with that sentinel or any incomplete trust configuration. The
release workflow also rejects it. A bad feed signature or archive signature is surfaced as a
normal Sparkle failure; the update is not installed.

## Hard external prerequisites

Complete every item before creating the first release tag:

1. Resolve issue #108. Add the maintainer-approved license at the repository root and set a
   nonempty `NSHumanReadableCopyright` in `project.yml`. The workflow rejects a release without
   both.
2. Use one stable Developer ID Application identity for `dev.islet`. Record its 10-character Apple
   team identifier as the repository variable `DEVELOPER_ID_TEAM_ID`.
3. Create and protect a GitHub environment named `release`. Required reviewers are recommended.
4. Enable immutable releases in the repository's Settings, under Releases. This must be enabled
   before the first release. The workflow verifies the setting through GitHub's official REST
   endpoint before it builds.
5. Add a repository ruleset for tags matching `v*`. Restrict tag creation to release managers and
   block tag updates and deletion.
6. Generate the Sparkle signing key, commit only its public half, and store its private half as an
   environment secret as described below.
7. Add all Developer ID, notary, update-signing, and repository-settings secrets listed below.

Do not create a tag until these conditions are met. Do not move or reuse any release tag, even if
its workflow fails. Fix the problem and use a new patch version.

## Generate the Sparkle signing key once

Use the `generate_keys` binary from the pinned Sparkle artifact after resolving packages. Choose a
dedicated account name so Islet's key is not confused with another product's key:

```sh
sparkle_tools=DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
"$sparkle_tools/generate_keys" --account C-Nucifora-islet
"$sparkle_tools/generate_keys" --account C-Nucifora-islet -p
```

Replace `CONFIGURATION_REQUIRED` in `Config/Update.xcconfig` with the printed public key without
adding quotes. Review and commit that public key. It is expected to be public.

Export the private seed to a protected location outside the repository. Sparkle documents the
exported file as equivalent to the password for its Keychain item, so limit its permissions and
keep a recoverable offline backup:

```sh
umask 077
secure_key_file=/path/outside/the/repository/islet-sparkle-ed25519.key
"$sparkle_tools/generate_keys" --account C-Nucifora-islet -x "$secure_key_file"
gh secret set --env release SPARKLE_ED25519_PRIVATE_KEY < "$secure_key_file"
```

Never put that file, its contents, or a generated private key in Git, build logs, repository
variables, workflow YAML, release assets, or an app bundle. The release workflow supplies the
secret to Sparkle on standard input with `--ed-key-file -`, so it never appears in a process
argument.

## Release environment configuration

Add these secrets to the protected `release` environment:

- `DEVELOPER_ID_APPLICATION_P12`: Base64 of the Developer ID Application certificate and private
  key exported as PKCS#12.
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`: The PKCS#12 export password.
- `APP_STORE_CONNECT_KEY_ID`: The key ID for an App Store Connect API key that can notarize apps.
- `APP_STORE_CONNECT_ISSUER_ID`: The API key issuer ID.
- `APP_STORE_CONNECT_PRIVATE_KEY`: The complete contents of the API key's `.p8` file.
- `SPARKLE_ED25519_PRIVATE_KEY`: The exact private seed exported by Sparkle's `generate_keys` tool.
- `RELEASE_SETTINGS_TOKEN`: A fine-grained token with repository Administration read permission.
  It is used only to prove that immutable releases are enabled before publication.

Store the Apple team identifier as the repository variable `DEVELOPER_ID_TEAM_ID`, not as a
secret. The workflow checks that the signed app's TeamIdentifier matches it. The repository token
cannot enable release immutability; an owner must make that decision in repository settings.

## Local validation

Generate the project once, install the checked-in package resolution, and use signing-disabled
builds for local tests:

```sh
xcodegen generate
resolved_dir=Islet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$resolved_dir"
install -m 0644 Package.resolved "$resolved_dir/Package.resolved"
xcodebuild \
  -resolvePackageDependencies \
  -project Islet.xcodeproj \
  -scheme Islet \
  -derivedDataPath DerivedData \
  -onlyUsePackageVersionsFromResolvedFile \
  -packageAuthorizationProvider netrc
Scripts/test-update-tooling.sh
```

CI additionally runs strict recursive `swift-format`, actionlint, shell syntax checks, both
architecture test jobs, and static analysis. A release reruns CI before accessing any signing
secret.

## Publish a release

Start from an up-to-date, clean `main` checkout. Confirm CI is green and the exact commit contains
the intended public update key, license, and copyright. Then create and push an annotated tag:

```sh
git switch main
git pull --ff-only
git tag -a v1.2.3 -m "Islet 1.2.3"
git push origin v1.2.3
```

The workflow performs these gates in order:

1. It proves the event SHA is an annotated tag at the current `origin/main` commit and no release
   already uses the tag.
2. It verifies the license, copyright, immutable-release setting, protected tag ruleset, matching
   update keypair, exact feed, package lock, and expected Developer ID team.
3. It builds a universal app, signs Sparkle's nested XPC services and helpers in Sparkle's required
   order, signs the remaining frameworks and app, and verifies the final signature.
4. It submits that app to Apple's notary service, staples the ticket, runs Gatekeeper assessment,
   and packages that exact app with `ditto` so framework symlinks are preserved.
5. It generates release notes for the exact tag, signs the archive and feed with Sparkle, verifies
   both signatures, and generates the manifest and checksums from the final bytes.
6. It verifies the archive contents, versions, immutable tag URLs, signatures, checksums, manifest,
   bundle identifier, and signing team before uploading anything.
7. It creates GitHub artifact attestations and verifies them against the release workflow, source
   ref, and tagged source digest.
8. It creates a draft release, compares every uploaded asset's GitHub digest and size with the
   validated local file, rechecks the remote tag, and only then publishes the release.
9. It confirms the published release is immutable.

Published assets are `Islet-VERSION.zip`, `appcast.xml`, `release-manifest.json`, and `SHA256SUMS`.
The stable feed URL uses GitHub's latest-release redirect, while every appcast enclosure points to
the archive under its exact version tag.

## Required two-version acceptance run

The workflow is not a substitute for an update from one real release to the next. Before calling
the feature complete, perform this run on a test Mac with disposable test data:

1. Install release A at `/Applications/Islet.app`. Do not rename the bundle or move it during the
   test.
2. Open Settings diagnostics and record the executable path, bundle identifier, Developer ID team,
   designated requirement, signing authorities, and launch-at-login status. Record the current
   Accessibility, Calendar, Reminders, and any other granted privacy permissions in System
   Settings.
3. Complete Sparkle's automatic-check permission prompt or leave it disabled and use Check for
   Updates. Confirm Settings reports release A's version, stable channel, and last check.
4. Publish release B from a later protected tag. In release A, perform a manual check and verify the
   release notes, progress, ready-to-install prompt, and relaunch behavior.
5. After relaunch, prove the running executable is still
   `/Applications/Islet.app/Contents/MacOS/Islet`, the bundle identifier is still `dev.islet`, and
   the Developer ID team and designated requirement are compatible with release A. Confirm Settings
   reports release B and the last check date.
6. Confirm the launch-at-login item remains enabled or still awaits the same approval without a
   needless unregister/register cycle. Restart or log in again and prove the registered app starts.
7. Recheck every privacy permission and exercise the protected features. Record any macOS prompt or
   lost grant instead of claiming preservation from identifiers alone.
8. On an isolated test feed with throwaway keys and builds, alter the signed feed and archive after
   signing. Confirm each case fails cleanly and installs nothing. Never tamper with a published
   stable release or reuse the production signing key for this negative test.

Sparkle updates the existing application in place. Islet also keeps the stable bundle identifier
and requires the same Developer ID team, while launch-at-login synchronization avoids replacing an
enabled or pending registration. These controls reduce needless identity churn, but only the
two-version run can establish the observed TCC and login-item behavior on the target macOS version.

## What this repository change does not prove

Adding the code and workflow does not by itself prove that Apple notarized an app, Gatekeeper
accepted it, a first release was published, a two-version update succeeded, or TCC grants survived.
Those claims require the protected secrets, repository-owner settings, real release artifacts, and
the acceptance run above.

## Official references

- [Sparkle 2.9.6 release](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6)
- [Sparkle setup and security configuration](https://sparkle-project.org/documentation/)
- [Sparkle user settings and automatic-check guidance](https://sparkle-project.org/documentation/customization/)
- [Sparkle publishing and `generate_appcast`](https://sparkle-project.org/documentation/publishing/)
- [Sparkle manual code signing order](https://sparkle-project.org/documentation/sandboxing/)
- [Apple Code Signing Guide: designated requirements and updates](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
- [Apple notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [GitHub immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
- [GitHub REST endpoint for checking immutable releases](https://docs.github.com/en/rest/repos/repos#check-if-immutable-releases-are-enabled-for-a-repository)
- [GitHub artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)
- [GitHub repository rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository)
