import AppKit

@MainActor
enum A11y {
  static var isVoiceOverEnabled: Bool { NSWorkspace.shared.isVoiceOverEnabled }

  /// Speaks a message via VoiceOver (no-op when VoiceOver is off). Used for the island's transient
  /// events, which are otherwise invisible to assistive tech.
  static func announce(_ message: String) {
    guard NSWorkspace.shared.isVoiceOverEnabled else { return }
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }
}
