# Islet

[![CI](https://github.com/C-Nucifora/islet/actions/workflows/ci.yml/badge.svg)](https://github.com/C-Nucifora/islet/actions/workflows/ci.yml)

Islet is a macOS utility that puts timers, media controls, files, and live status around the MacBook notch. It runs without a Dock or menu-bar icon. Open it by pushing the pointer past the top edge of the display, or switch to click-to-pin interaction in Settings.

Islet currently targets macOS 26 and is under active development. Build it from source to try it.

## What Islet includes

- A contextual Home view for upcoming events, reminders, timers, and actions that adapt to the current app, Focus, power state, display, and time.
- Activities for Now Playing, battery and power flow, system metrics, clipboard history, connected ports, iPhone Live Activities, and a temporary file shelf.
- Brief alerts for hardware, network, power, session, screenshot, Focus, and VPN changes.
- Local integrations for T3 Code agents and Pulse updates from scripts or other tools.

You can choose, reorder, and hide activities during setup or in Settings. Islet can also run on multiple displays and hide itself when another app is full screen.

## Requirements

- macOS 26 or later
- Xcode 26 with the command-line tools installed
- A stable code-signing identity for local builds

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen), so the generated `Islet.xcodeproj` is not committed.

## Build from source

Clone the repository and install its pinned XcodeGen version into the ignored `.build` directory:

```sh
git clone https://github.com/C-Nucifora/islet.git
cd islet
Scripts/install-xcodegen.sh "$PWD/.build/xcodegen"
export PATH="$PWD/.build/xcodegen/bin:$PATH"
```

Create the local signing identity once. Stable signing keeps Calendar, Reminders, Accessibility, and other macOS permission grants attached to the same app identity across rebuilds.

```sh
Scripts/create-signing-certificate.sh
```

Generate the project, then open it in Xcode:

```sh
xcodegen generate
open Islet.xcodeproj
```

Select the `Islet` scheme and run it. The first launch walks through interaction, activities, and the permissions used by the features you select.

To use a different bundle identifier or signing identity, add an ignored `Config/Islet.local.xcconfig` file with your overrides:

```xcconfig
ISLET_PRODUCT_BUNDLE_IDENTIFIER = com.example.islet
ISLET_CODE_SIGN_IDENTITY = Your Code Signing Identity
```

## Run the tests

The scheme's test action uses the `Testing` configuration and the `dev.islet.tests` identity.
Its standard preferences, including writes through Defaults, are separate from the installed app.
Debug and Release builds retain the configured application identity. Do not override the test
configuration or test host bundle identifier.

Keep the installed Islet app closed during app-hosted tests until testing alongside an installed
copy has been verified. Never run multiple Islet test suites concurrently. The test runner checks
`pgrep -x Islet`, takes a per-user test lock, and gives each worktree its own DerivedData directory.
It compares production preferences before and after the whole suite without logging their values.

```sh
xcodegen generate
python3 Scripts/test-islet.py --timeout 600
```

Pass additional build settings or a focused selection after `--`:

```sh
python3 Scripts/test-islet.py --timeout 600 -- \
  -only-testing:IsletTests/TestHostIsolationTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
```

Cancellation or timeout stops only the test host, `xcodebuild`, `swift-frontend`, and
`islet-xcode-pulse` processes owned by that run. Wait for the runner to finish before relaunching
the installed app. Xcode's test action selects the same isolated configuration, but the command-line
runner additionally enforces the lock, hard timeout, and whole-suite preferences check.

CI runs the full suite on both arm64 and x86_64, verifies the vendored MediaRemote adapter, lints integration files, and runs static analysis.

## Permissions and privacy

Islet asks for access only when a selected feature needs it. Calendar and Reminders data stays on the Mac. Clipboard history is held in memory for the current session and filters concealed, transient, password-manager, and likely credential content. Location access is optional and is used only to add Wi-Fi network names to connection alerts.

The Permissions and Diagnostics pages in Settings show the current state of each integration and provide recovery actions when macOS access is missing.

## Project notes

- [Release process](RELEASING.md)
- [T3 Connect verification](docs/t3-connect-verification.md)
- [Vendored MediaRemote adapter](Vendor/README.md)
