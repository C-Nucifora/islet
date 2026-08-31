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

struct IslandKeyboardModifiers: OptionSet, Equatable, Sendable {
  let rawValue: UInt8

  static let command = Self(rawValue: 1 << 0)
  static let control = Self(rawValue: 1 << 1)
  static let option = Self(rawValue: 1 << 2)
  static let shift = Self(rawValue: 1 << 3)
}

struct IslandKeyStroke: Equatable, Sendable {
  let key: String
  let modifiers: IslandKeyboardModifiers
  let isEditingText: Bool
}

enum IslandKeyboardCommand: Equatable, Sendable {
  case selectTab(Int)
  case cycleTab(Int)
  case primaryAction
  case dismissTransient
  case close
}

/// Keyboard policy for the expanded island. The AppKit panel and tests both use this function, so
/// shortcut behavior cannot drift between the documented commands and the event handler.
enum IslandKeyboardPolicy {
  static func command(for stroke: IslandKeyStroke) -> IslandKeyboardCommand? {
    guard !stroke.isEditingText else { return nil }
    let key = stroke.key.lowercased()

    if stroke.modifiers == .command, let number = Int(key), (1...9).contains(number) {
      return .selectTab(number - 1)
    }
    if stroke.modifiers == .control, key == "\t" { return .cycleTab(1) }
    if stroke.modifiers == [.control, .shift], key == "\u{19}" { return .cycleTab(-1) }
    if stroke.modifiers == .command, key == "\r" { return .primaryAction }
    if stroke.modifiers.isEmpty, key == "\u{1b}" { return .dismissTransient }
    if stroke.modifiers == .command, key == "w" { return .close }
    return nil
  }

  static func selectedID(
    for command: IslandKeyboardCommand, tabIDs: [String], currentID: String
  ) -> String? {
    guard !tabIDs.isEmpty else { return nil }
    switch command {
    case .selectTab(let index):
      return tabIDs.indices.contains(index) ? tabIDs[index] : nil
    case .cycleTab(let delta):
      let currentIndex = tabIDs.firstIndex(of: currentID) ?? 0
      let nextIndex = (currentIndex + delta % tabIDs.count + tabIDs.count) % tabIDs.count
      return tabIDs[nextIndex]
    case .primaryAction, .dismissTransient, .close:
      return nil
    }
  }
}

enum ExpandedFocusTarget: Equatable, Sendable {
  case tab(String)
  case overflow
  case quickActions
  case settings
  case content(String)
}

enum ExpandedSelectionPolicy {
  static let homeID = "\u{0000}home"

  static func effectiveSelection(
    tabIDs: [String], storedSelection: String?, shelfPresentationActive: Bool,
    primaryActivityID: String?
  ) -> String {
    if shelfPresentationActive, tabIDs.contains("shelf") { return "shelf" }
    if let storedSelection, tabIDs.contains(storedSelection) { return storedSelection }
    if let primaryActivityID,
      ["timer", "nowPlaying"].contains(primaryActivityID), tabIDs.contains(primaryActivityID)
    {
      return primaryActivityID
    }
    return tabIDs.contains(homeID) ? homeID : (tabIDs.first ?? homeID)
  }
}

/// The declared traversal order for both the visible switcher and its selected activity group.
/// Native controls inside the content group retain their source order.
enum ExpandedFocusOrder {
  static func targets(
    visibleTabIDs: [String], overflowTabIDs: [String], selectedID: String
  ) -> [ExpandedFocusTarget] {
    visibleTabIDs.map(ExpandedFocusTarget.tab)
      + (overflowTabIDs.isEmpty ? [] : [.overflow])
      + [.quickActions, .settings, .content(selectedID)]
  }
}

enum ActivityAccessibilityText {
  static func clipboardItem(preview: String, detail: String?) -> String {
    [preview, detail].compactMap { $0 }.joined(separator: ", ")
  }

  static func portDevice(name: String, vendor: String?, speed: String?, port: String) -> String {
    [name, vendor, speed, port].compactMap { $0 }.joined(separator: ", ")
  }

  static func pulseItem(source: String, title: String, state: String, subtitle: String?) -> String {
    [source, title, state, subtitle].compactMap { $0 }.joined(separator: ", ")
  }

  static func reminder(title: String, due: String?, overdue: Bool) -> String {
    [title, overdue ? "overdue" : nil, due].compactMap { $0 }.joined(separator: ", ")
  }
}
