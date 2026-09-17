# macOS 27 compatibility

Islet keeps macOS 26 as its minimum deployment target. The macOS 27 CI job builds
with Xcode 27 and runs the app-hosted test suite on Apple silicon. The existing
macOS 26 jobs continue to test Apple silicon and Intel.

GitHub's [`xcode-27` preview image](https://github.blog/changelog/2026-09-10-xcode-27-runner-image-now-runs-on-macos-27/)
runs macOS 27. The job checks the host OS and SDK versions so a runner image
change cannot silently replace macOS 27 coverage with an older OS.

Release packaging and the byte-for-byte MediaRemoteAdapter rebuild remain on
Xcode 26.6. The adapter's provenance manifest records that compiler and SDK;
rebuilding it with Xcode 27 would produce different artifacts. The macOS 27 job
verifies and embeds the same checked-in adapter used by releases.

## Compact notification layout

On macOS 27 and later, a display with a hardware notch uses an 80-point text
viewport for notification popups. Including the trailing padding, corner flare,
and window margin, the collapsed window extends 98 points beyond the notch.
Previously it extended 138 points. This leaves 40 more points for the menu bar
overflow arrows. It is a fixed layout budget, not detection of the arrows' position.

Long text continues to scroll within the narrower viewport. With Reduce
Motion enabled, the text stays still in the same bounded viewport. VoiceOver's
notification announcement is unchanged. iPhone Live Activity notifications use
the same viewport. macOS 26 and displays without a hardware notch use 120 points.
The expanded island and persistent activity indicators keep their existing layout.

## Verification

Local validation passed on macOS 27.0 build 26A428 with Xcode 27.0 build 27A266a:
1,643 XCTest cases and 7 Swift Testing checks, with no failures. One live menu-bar
integration test was skipped because the isolated test host lacked Accessibility
permission. The runner confirmed that production preferences were unchanged.
The regression test hosts the real notification, renderer and panel sizing path.
Before the fix it measures a 138-point trailing extent and fails the 98-point
limit. Geometry tests cover macOS 26, macOS 27 and a display without a notch.
Hosting tests check that long text fits the narrower viewport.

Follow the [test safety instructions](../README.md#run-the-tests). Quit the
installed app before running app-hosted tests, use a hard timeout, and wait for
the runner to exit before reopening it.

```sh
xcodegen generate
python3 Scripts/test-islet.py --timeout 600 -- \
  -only-testing:IsletTests/SneakSnapshotTests \
  -only-testing:IsletTests/NotchGeometryTests \
  -only-testing:IsletTests/TallTierHostingTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
```

These manual checks still require the relevant hardware, accounts or permissions:

- With the overflow arrows visible, trigger a long Bluetooth or track-change
  notification. Check that the arrows remain visible and clickable throughout it,
  with Reduce Motion both on and off.
- Check popup placement after changing display scaling or connecting an external
  display. If the arrows sit within 98 points of the notch, this budget needs a
  further adjustment.
- Exercise volume and brightness keys, media playback and track changes, iPhone
  Live Activities, and full-screen hide/show. Unit tests do not establish that
  undocumented system integrations work with every macOS update.

Apple's [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)
and [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
are the references for SDK behavior changes. The compatibility update does not
opt the whole app out of the new gesture behavior or change permission grants.
