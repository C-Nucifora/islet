import AppKit
import ApplicationServices

/// The Accessibility grant, which Islet now needs in two places: the HUD's event tap and the
/// iPhone tab's read of ControlCenter's menu bar.
///
/// Worth centralising because the grant is easy to get wrong in a way that looks like a bug. It is
/// keyed on the app's code signature, and an ad-hoc signed build gets a new one every time it is
/// rebuilt — so a grant given yesterday is silently gone today, with the feature simply doing
/// nothing.
@MainActor
enum AccessibilityPermission {
  static var isTrusted: Bool { AXIsProcessTrusted() }

  /// Shows the system prompt. A no-op once granted, so it is safe to call from a button.
  static func prompt() {
    // Literal avoids referencing the non-Sendable global kAXTrustedCheckOptionPrompt.
    let options = ["AXTrustedCheckOptionPrompt": true]
    _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
  }

  /// Opens the Accessibility pane directly. The prompt only appears once per app per grant state,
  /// so a user who dismissed it needs a way back that does not involve hunting through Settings.
  static func openSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    else { return }
    NSWorkspace.shared.open(url)
  }
}
