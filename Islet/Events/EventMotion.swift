import SwiftUI

/// Per-source choreography for an event's icon.
///
/// Each profile is a distinct piece of motion, so a Wi-Fi drop and a completed timer do not feel
/// identical — but all of them obey two rules:
///
/// 1. **Overshoot is inward only.** Scale runs 0.6 → 1.0 and never past it. `Metrics.islandMargin`
///    is 4pt, `Metrics.collapsedDepth` is 12pt, and the island is clipped by both the `NotchShape`
///    mask and the panel window. A bounce to 1.15 is clipped to a hard edge, and widening the
///    margins to fit it gives back the menu-bar clickability commits 372c645 and 61cf4d5 bought.
/// 2. **Everything routes through `Motion.gated`**, so Reduce Motion makes the change instant
///    rather than removing the event.
private struct EventMotionModifier: ViewModifier {
  let profile: MotionProfile
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  @ViewBuilder
  func body(content: Content) -> some View {
    if reduceMotion {
      content
    } else {
      animated(content: content)
    }
  }

  @ViewBuilder
  private func animated(content: Content) -> some View {
    switch profile {
    // Signal arcs filling outward from the dot.
    case .wifi:
      content
        .symbolEffect(.variableColor.iterative, options: .repeat(2), value: appeared)
        .scaleEffect(appeared ? 1.0 : 0.7)
        .onAppear { animate() }

    // A pulse, the way a pairing indicator pulses.
    case .bluetooth:
      content
        .symbolEffect(.pulse, options: .repeat(2), value: appeared)
        .scaleEffect(appeared ? 1.0 : 0.8)
        .onAppear { animate() }

    // Slides in from the leading edge, like a plug going in. Travel is inside the measured slot.
    case .usb:
      content
        .offset(x: appeared ? 0 : -10)
        .opacity(appeared ? 1 : 0)
        .onAppear { animate() }

    // A radar sweep outward.
    case .airdrop:
      content
        .symbolEffect(.variableColor.cumulative, options: .repeat(3), value: appeared)
        .scaleEffect(appeared ? 1.0 : 0.75)
        .onAppear { animate() }

    // A drive rising into place.
    case .volumeMount:
      content
        .offset(y: appeared ? 0 : 6)
        .opacity(appeared ? 1 : 0)
        .onAppear { animate() }

    // A screen unfolding.
    case .display:
      content
        .scaleEffect(x: appeared ? 1.0 : 0.6, y: appeared ? 1.0 : 0.85, anchor: .center)
        .opacity(appeared ? 1 : 0)
        .onAppear { animate() }

    // The checkmark draws itself on.
    case .chargeComplete:
      content
        .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
        .scaleEffect(appeared ? 1.0 : 0.6)
        .onAppear { animate() }

    // A slow amber breath — deliberately calmer than the rest; it is a state, not an arrival.
    case .lowPower:
      content
        .symbolEffect(.pulse, options: .repeat(3), value: appeared)
        .opacity(appeared ? 1 : 0.3)
        .onAppear { animate() }

    // Flash, then settle small — the shutter.
    case .screenshot:
      content
        .scaleEffect(appeared ? 1.0 : 0.9)
        .brightness(appeared ? 0 : 0.8)
        .onAppear { animate() }

    // Snaps shut.
    case .lock:
      content
        .symbolEffect(.bounce.down, options: .nonRepeating, value: appeared)
        .scaleEffect(appeared ? 1.0 : 0.85)
        .onAppear { animate() }

    // Fades down, like the screen going to sleep.
    case .sleepWake:
      content
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1.0 : 0.92)
        .onAppear { animate() }

    // A shake: this one wants attention.
    case .peripheralLow:
      content
        .symbolEffect(.wiggle, options: .repeat(2), value: appeared)
        .onAppear { animate() }

    // A crescent settling in.
    case .focus:
      content
        .rotationEffect(.degrees(appeared ? 0 : -25))
        .scaleEffect(appeared ? 1.0 : 0.8)
        .onAppear { animate() }

    // The shield seals.
    case .vpn:
      content
        .symbolEffect(.bounce.up, options: .nonRepeating, value: appeared)
        .scaleEffect(appeared ? 1.0 : 0.75)
        .onAppear { animate() }

    // Everything else: a plain settle. Still gated, still inward.
    case .generic:
      content
        .scaleEffect(appeared ? 1.0 : 0.8)
        .opacity(appeared ? 1 : 0)
        .onAppear { animate() }
    }
  }

  /// One entry point so no profile can forget the Reduce Motion gate. `withAnimation(nil)` applies
  /// the state change instantly, which is exactly the wanted behaviour: the event still appears.
  private func animate() {
    withAnimation(Motion.gated(.bouncy(duration: 0.45))) { appeared = true }
  }
}

extension View {
  /// Applies the bespoke choreography for a source's event class.
  func eventMotion(_ profile: MotionProfile) -> some View {
    modifier(EventMotionModifier(profile: profile))
  }
}
