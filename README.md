# Islet

Islet is a menu bar app that puts live activities and short system events around the MacBook
notch. It shows media, timers, calendar events, reminders, clipboard history, system metrics,
attached devices, file transfers, T3 Code agents, and local [Pulse](Integrations/Pulse/README.md)
providers. Macs without a hardware notch use the same top-edge panel.

## Requirements

- macOS 26 or later. The deployment target is defined in [`project.yml`](project.yml).
- Xcode 26.6 with its macOS 26 SDK. CI selects this exact Xcode release.
- Internet access to download XcodeGen and resolve packages. Direct and transitive Swift package
  versions are pinned in [`Package.resolved`](Package.resolved).
- XcodeGen 2.46.0. The repository installer downloads the pinned release and verifies its SHA-256.

CI builds and tests both Apple Silicon and Intel. Apple Silicon exposes an optional CPU energy
metric that is unavailable on Intel. The vendored MediaRemote adapter contains both slices.

## Build and test

Start from a clean checkout. These commands use the same project generation, resolved package,
destination, and signing flags as CI. The test selects the current Mac's architecture; CI runs the
same build once on arm64 and once on x86_64.

```sh
git clone https://github.com/C-Nucifora/islet.git
cd islet

build_tools="${TMPDIR:-/tmp}/islet-build-tools"
Scripts/install-xcodegen.sh "$build_tools"
export PATH="$build_tools/bin:$PATH"

Scripts/verify-mediaremote-adapter.sh
xcodegen generate
resolved_dir=Islet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$resolved_dir"
install -m 0644 Package.resolved "$resolved_dir/Package.resolved"
git diff --exit-code -- Islet/Info.plist

xcodebuild \
  -resolvePackageDependencies \
  -project Islet.xcodeproj \
  -scheme Islet \
  -derivedDataPath DerivedData \
  -onlyUsePackageVersionsFromResolvedFile
cmp Package.resolved "$resolved_dir/Package.resolved"

test_arch=$(uname -m)
xcodebuild \
  -project Islet.xcodeproj \
  -scheme Islet \
  -destination "platform=macOS,arch=$test_arch" \
  -derivedDataPath DerivedData \
  -disableAutomaticPackageResolution \
  ARCHS="$test_arch" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  test
```

The generated Xcode project is ignored. Change `project.yml`, then regenerate it instead of
editing `Islet.xcodeproj` by hand.

CI also checks Swift formatting, the Pulse schema and examples, static analysis, both supported
architectures, and a reproducible build of the vendored MediaRemote adapter. See the
[`CI` workflow](.github/workflows/ci.yml) for the complete command list and
[`Vendor/README.md`](Vendor/README.md) before changing the adapter or its checksums.

## Run a local build

Islet's macOS permission grants are tied to its code signature. Ad hoc builds get a new identity
after code changes, which makes macOS discard earlier grants. Create the repository's stable local
identity once:

```sh
Scripts/create-signing-certificate.sh
xcodegen generate
resolved_dir=Islet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$resolved_dir"
install -m 0644 Package.resolved "$resolved_dir/Package.resolved"
open Islet.xcodeproj
```

Run the `Islet` scheme from Xcode. The default local identity is `Islet Dev` and the bundle
identifier is `dev.islet`. To use another identity or bundle identifier, put the overrides in the
ignored `Config/Islet.local.xcconfig` file. After changing either value, grant the requested
permissions to the new app identity.

## Code map

| Area | Location | Responsibility |
| --- | --- | --- |
| App startup | [`Islet/App`](Islet/App) | Creates activities and event sources, then starts their lifecycle controllers. |
| Activities | [`Islet/Activities`](Islet/Activities) | One directory per live surface. Each activity implements [`NotchActivity`](Islet/Activities/NotchActivity.swift) and registers with [`ActivityCenter`](Islet/Activities/ActivityCenter.swift). |
| System events | [`Islet/Events`](Islet/Events) | Defines event delivery, coalescing, motion, and the source catalogue. Observers live in [`Islet/Events/Sources`](Islet/Events/Sources). |
| Window and layout | [`Islet/Core`](Islet/Core), [`Islet/UI`](Islet/UI) | Owns display selection, panel geometry, notch state, and shared views. |
| Settings | [`Islet/Settings`](Islet/Settings) | Contains the Settings UI, persistent Defaults keys, diagnostics, and settings import and export. |
| Pulse | [`Islet/Activities/Pulse`](Islet/Activities/Pulse), [`Integrations/Pulse`](Integrations/Pulse) | Implements the loopback server, provider rules, protocol schema, CLI, and examples. |
| Tests | [`IsletTests`](IsletTests) | Holds the unit tests. Tests use the `Islet` app as their host, while app startup skips hardware monitors under XCTest. |

To add an activity, create its directory under `Islet/Activities`, implement `NotchActivity`, add
its metadata to `ActivityCatalog`, and register it in `AppState` and `AppDelegate`. Activities with
observers must also be classified in `ActivityCatalog.lifecycleManagedIDs` or
`persistentLifecycleIDs` and wired into `AppDelegate.configureActivityLifecycles`. To add a system
event, implement `SystemEventSource` under `Islet/Events/Sources`, add it to `SourceCatalog`, and
register it in `AppState.eventSources`. Settings renders activity and source controls from those
catalogues.

## Permissions

Islet requests access when a feature needs it. Denying a permission leaves the rest of the app
running.

| Permission | Used for | Behavior without it |
| --- | --- | --- |
| Calendar | Today's agenda, countdowns, and meeting links | Calendar content stays empty. |
| Reminders | Reading incomplete reminders and completing or rescheduling them | Reminder content and actions are unavailable. |
| Accessibility | Reading media-key events for the HUD and app names for iPhone Live Activities | Those two features stay limited or inactive. |
| Location | Reading the current Wi-Fi network name | Wi-Fi events still appear without the network name. |
| Bluetooth | Connection events and supported Apple peripheral battery levels | Bluetooth-specific status is unavailable. |
| Local network | Connecting to an explicitly paired T3 Code service on another Mac | Remote LAN environments cannot be reached. Loopback Pulse does not need this grant. |

The capture-exclusion setting is not a permission. AppKit's legacy window-sharing flag does not
provide reliable capture protection on the supported macOS release. Islet may appear in
screenshots, recordings, and shared screens even when the setting is enabled.

## Private system dependencies

Several optional features use undocumented macOS interfaces:

- Now Playing reads through the vendored MediaRemoteAdapter and sends media commands through the
  private `MediaRemote.framework`.
- Brightness control loads the private `DisplayServices.framework` at runtime.
- Native fullscreen detection calls undocumented CoreGraphics WindowServer symbols, with a public
  window-list fallback.
- Apple Silicon CPU power sampling loads `libIOReport.dylib` at runtime.
- Battery details read undocumented AppleSmartBattery and IORegistry keys. Missing or changed keys
  remove only the affected metrics from the panel.
- Focus mode reads the private `~/Library/DoNotDisturb/DB/Assertions.json` schema. Missing,
  unreadable, or unrecognised data produces no Focus event and is reported in diagnostics.
- Screen lock and unlock use undocumented distributed-notification names. If those names change,
  lock events stop; the independent Caps Lock observer continues to work.

Runtime-loaded frameworks resolve symbols dynamically and fall back or disable the affected
feature when macOS no longer provides one. File, registry-key, and notification dependencies are
handled defensively but can still stop producing events or metrics after an operating system
update. The adapter's source, patch, binary provenance, and rebuild procedure are documented in
[`Vendor/README.md`](Vendor/README.md).

## Network and storage boundaries

Islet has no analytics or telemetry client. Its network code is limited to Pulse and T3 Code:

- Pulse listens only on `127.0.0.1`, starting at TCP port `47717` and using a bounded fallback
  range if that port is busy. Each request needs the user-only token stored at
  `~/Library/Application Support/Islet/pulse-token`. See the
  [Pulse integration guide](Integrations/Pulse/README.md) for protocol limits and examples.
- T3 Code reads a current local runtime descriptor and verifies the owning process before using a
  loopback endpoint. Other Macs must be paired explicitly. Remote endpoints use HTTPS unless a
  reviewed build and the user both approve one exact plain HTTP origin. Bearer tokens stay in the
  default Keychain with `ThisDeviceOnly` protection.

Islet does not operate a cloud service. Data leaves the Mac only through configured system
services and explicit actions: paired T3 requests go to the selected endpoint, AirDrop sends Shelf
files selected by the user, and opening a meeting or Pulse link hands its URL to the chosen app.
Calendar and reminder data may also follow the system accounts configured in macOS.

Local retention follows these rules:

- Interface settings, activity order, paired T3 endpoint metadata, hidden calendar identifiers,
  and timer state use local Defaults. A stale timer session is discarded after 30 days.
- Shelf drops are copies under `~/Library/Application Support/Islet/Shelf`. They persist until the
  user removes them. The Shelf accepts at most 100 items and 2 GiB while reserving 1 GiB of free
  disk space.
- Clipboard history stays in process memory, holds at most 20 items or 32 MiB, and clears when the
  activity stops, the user pauses it, or Islet quits. Filters reject concealed pasteboard entries
  and common credential formats, but callers should not treat the filter as a secret scanner.
- Calendar and reminder records stay in memory. Completing or rescheduling a reminder writes that
  change back through EventKit.
- Pulse active items and its payload-free history are memory-only and never survive quit. Items
  leave when they end, expire, are dismissed, or Pulse stops; history can be cleared separately.
  The history is capped at 200 entries and omits titles, subtitles, links, tokens, and error text.
  The Pulse token itself persists with user-only file permissions until it is rotated.
- Live T3 agent snapshots and system metric samples stay in memory. T3 credentials persist only in
  Keychain.

Settings can export portable preferences as JSON. The export excludes credentials, tokens, paired
machines, permission grants, calendar identifiers, activity data, and session history.

## Integrations and releases

- [Pulse provider protocol, reference CLI, and examples](Integrations/Pulse/README.md)
- [Release signing, notarization, and tag procedure](RELEASING.md)
- [MediaRemoteAdapter provenance and review procedure](Vendor/README.md)
