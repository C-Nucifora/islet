# Compact Event Marquee Design

## Problem

System-event sneaks can contain user-controlled strings such as Bluetooth device names, Wi-Fi
SSIDs, filenames, display names, and mounted-volume names. `EventTrailingView` currently permits
that content to measure up to 175 points wide. The collapsed panel and island correctly grow to
match the measured trailing slot, so a long event makes the island extend much too far to the
right.

The notch-alignment geometry is not at fault. Its asymmetric sizing is required to keep the drawn
island aligned with the physical notch and to avoid intercepting unrelated menu-bar clicks.

## Approved Behavior

Event text will render inside a fixed 120-point trailing viewport. Short messages remain static.
When the full title and subtitle overflow, the combined one-line message will:

1. remain still briefly so its beginning can be read;
2. scroll slowly from right to left until its end is visible;
3. pause at the end; and
4. reset and repeat after a short gap.

A subtle horizontal edge fade will make the viewport boundary intentional rather than appearing
as hard clipping. The event icon remains in the leading slot. The full event announcement remains
available to VoiceOver.

When Reduce Motion is enabled, the marquee will not move. The same 120-point viewport will use a
single-line tail-truncated presentation instead.

## Architecture

### `CompactMarqueeText`

A focused SwiftUI view will own overflow measurement and animation. It accepts the rendered
message content and a fixed viewport width. It measures the content and viewport independently,
starts animation only when content exceeds the viewport, and derives travel distance from that
difference.

The animation state will reset when the displayed event changes, preventing offsets from one event
from carrying into the next. Animation tasks will be cancelled when the view disappears or Reduce
Motion becomes active.

### `EventTrailingView`

The existing title and optional subtitle remain one semantic message. Their current visual
hierarchy—semibold white title and secondary subtitle—will be preserved inside the marquee. The
view will expose a fixed width rather than a maximum ideal width, so the surrounding measurement
pipeline has a stable contract.

### Geometry and panel sizing

`NotchRootView`, `NotchGeometry`, and `NotchViewModel` will remain unchanged unless a failing
integration test proves otherwise. They should continue sizing and aligning the panel from actual
slot measurements; the event view is responsible for offering a bounded measurement.

## Timing and Motion

The marquee will use a calm, constant-speed translation appropriate for reading rather than a
decorative spring. Timing will be based on travel distance so longer messages move at the same
perceptual speed as shorter ones. Start and end pauses will separate reading phases and avoid a
perpetually moving interface.

The existing event appearance/disappearance transition remains unchanged. No vertical movement or
additional island growth will be introduced.

## Accessibility

- VoiceOver continues to announce `SystemEvent.spokenAnnouncement`, including the full untruncated
  content.
- Reduce Motion disables marquee translation and presents a stable tail-truncated line.
- Color is not the sole carrier of meaning; title/subtitle text remains present.
- The compact sneak remains noninteractive, so no new focus target or keyboard behavior is needed.

## Testing

Tests will be added before production changes.

- A pure layout/timing model test will prove that content wider than 120 points produces bounded
  viewport geometry and the correct travel distance.
- A short-message case will prove that no scrolling is requested.
- A Reduce Motion case will prove that animation is suppressed.
- The real Bluetooth sneak hosting test will assert that a deliberately long device name cannot
  make the trailing slot or collapsed panel exceed the approved compact allowance.
- The existing geometry and full unit-test suites will be run after the change.

## Out of Scope

- Changing system-event wording or source detection.
- Changing compact activity layouts that are not system-event sneaks.
- Reworking notch alignment, hover behavior, or expanded-island sizing.
- Adding interaction to pause or scrub transient event messages.

