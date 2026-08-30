import Defaults
import Foundation

enum ContextTriggerKind: String, CaseIterable, Codable, Identifiable, Sendable {
  case focusMode
  case powerSource
  case lowPowerMode
  case frontmostApp
  case fullscreenPresentation
  case timeRange
  case activeDisplay
  case wifiNetwork

  var id: Self { self }

  var title: String {
    switch self {
    case .focusMode: "Focus mode"
    case .powerSource: "Power source"
    case .lowPowerMode: "Low Power Mode"
    case .frontmostApp: "Frontmost app"
    case .fullscreenPresentation: "Fullscreen presentation"
    case .timeRange: "Time range"
    case .activeDisplay: "Active display"
    case .wifiNetwork: "Wi-Fi network"
    }
  }
}

enum ContextPowerSource: String, CaseIterable, Codable, Identifiable, Sendable {
  case ac
  case battery

  var id: Self { self }
  var title: String { self == .ac ? "Power adapter" : "Battery" }
}

struct ContextRuleTrigger: Codable, Equatable, Sendable {
  var kind: ContextTriggerKind = .focusMode
  var text = ""
  var boolean = true
  var powerSource = ContextPowerSource.ac
  var startMinute = 9 * 60
  var endMinute = 17 * 60

  var isValid: Bool {
    switch kind {
    case .focusMode:
      text.count <= ContextRule.maximumTriggerValueLength
    case .frontmostApp, .activeDisplay, .wifiNetwork:
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && text.count <= ContextRule.maximumTriggerValueLength
    case .powerSource, .lowPowerMode, .fullscreenPresentation:
      true
    case .timeRange:
      (0..<24 * 60).contains(startMinute) && (0..<24 * 60).contains(endMinute)
        && startMinute != endMinute
    }
  }
}

struct ContextRuleAction: Codable, Equatable, Sendable {
  static let maximumActivityCount = 100
  static let maximumActivityIDLength = 128

  var pulseDelivery: PulseDeliveryProfile?
  var energyMode: EnergyMode?
  /// A false value hides an activity. A true value keeps an otherwise-enabled activity visible.
  /// This never enables an activity disabled in Activity order.
  var activityVisibility: [String: Bool] = [:]

  var isEmpty: Bool {
    pulseDelivery == nil && energyMode == nil && !activityVisibility.values.contains(false)
  }

  var isValid: Bool {
    activityVisibility.count <= Self.maximumActivityCount
      && activityVisibility.keys.allSatisfy {
        !$0.isEmpty && $0.count <= Self.maximumActivityIDLength
      }
  }

  func summary(activityName: (String) -> String = ActivityCatalog.name) -> String {
    var changes: [String] = []
    if let pulseDelivery { changes.append("Pulse: \(pulseDelivery.title)") }
    if let energyMode { changes.append("Energy: \(energyMode.title)") }
    let hidden = activityVisibility.filter { !$0.value }.keys.sorted().map(activityName)
    if !hidden.isEmpty { changes.append("Hide: \(hidden.joined(separator: ", "))") }
    return changes.isEmpty ? "No changes" : changes.joined(separator: " · ")
  }
}

struct ContextRule: Codable, Defaults.Serializable, Equatable, Identifiable, Sendable {
  static let maximumCount = 100
  static let maximumNameLength = 80
  static let maximumTriggerValueLength = 256

  var id = UUID()
  var name = "New rule"
  var isEnabled = true
  var trigger = ContextRuleTrigger()
  var action = ContextRuleAction()

  var isValid: Bool {
    let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return !cleanedName.isEmpty && cleanedName.count <= Self.maximumNameLength
      && trigger.isValid && action.isValid && !action.isEmpty
  }
}

struct ContextManualOverride: Codable, Defaults.Serializable, Equatable, Sendable {
  var action: ContextRuleAction
  var expiresAt: Date

  func isActive(at date: Date) -> Bool { expiresAt > date && !action.isEmpty }
}

struct ContextSnapshot: Equatable, Sendable {
  var focusMode: String?
  var powerSource: ContextPowerSource?
  var lowPowerMode = false
  var frontmostBundleIdentifier: String?
  var isFullscreenPresentation = false
  var minuteOfDay = 0
  var activeDisplayID: String?
  var activeDisplayName: String?
  var wifiNetwork: String?
}

struct ContextRuleResolution: Equatable, Sendable {
  var matchedRuleID: UUID?
  var title: String?
  var reason: String?
  var action: ContextRuleAction?
  var isManualOverride = false

  static let none = ContextRuleResolution()

  func energyMode(baseline: EnergyMode) -> EnergyMode {
    action?.energyMode ?? baseline
  }

  func pulseDelivery(baseline: PulseDeliveryProfile) -> PulseDeliveryProfile {
    action?.pulseDelivery ?? baseline
  }

  func isActivityVisible(_ id: String, baselineVisible: Bool) -> Bool {
    guard baselineVisible else { return false }
    return action?.activityVisibility[id] ?? true
  }
}

enum ContextRuleEvaluator {
  static func resolve(
    rules: [ContextRule], snapshot: ContextSnapshot, manualOverride: ContextManualOverride?,
    now: Date
  ) -> ContextRuleResolution {
    if let manualOverride, manualOverride.isActive(at: now) {
      return ContextRuleResolution(
        title: "Manual override",
        reason: "Expires \(manualOverride.expiresAt.formatted(date: .omitted, time: .shortened))",
        action: manualOverride.action, isManualOverride: true)
    }

    for rule in rules where rule.isEnabled && rule.isValid {
      if let reason = matchReason(for: rule.trigger, snapshot: snapshot) {
        return ContextRuleResolution(
          matchedRuleID: rule.id, title: rule.name, reason: reason, action: rule.action)
      }
    }
    return .none
  }

  static func matchReason(
    for trigger: ContextRuleTrigger, snapshot: ContextSnapshot
  ) -> String? {
    switch trigger.kind {
    case .focusMode:
      guard let focus = snapshot.focusMode else { return nil }
      let wanted = normalized(trigger.text)
      guard wanted.isEmpty || normalized(focus) == wanted else { return nil }
      return wanted.isEmpty ? "A Focus is active" : "Focus is \(focus)"
    case .powerSource:
      guard snapshot.powerSource == trigger.powerSource else { return nil }
      return trigger.powerSource == .ac ? "Connected to a power adapter" : "Running on battery"
    case .lowPowerMode:
      guard snapshot.lowPowerMode == trigger.boolean else { return nil }
      return trigger.boolean ? "Low Power Mode is on" : "Low Power Mode is off"
    case .frontmostApp:
      guard normalized(snapshot.frontmostBundleIdentifier) == normalized(trigger.text) else {
        return nil
      }
      return "Frontmost app is \(trigger.text)"
    case .fullscreenPresentation:
      guard snapshot.isFullscreenPresentation == trigger.boolean else { return nil }
      return trigger.boolean ? "A fullscreen presentation is active" : "No fullscreen presentation"
    case .timeRange:
      guard
        contains(
          minute: snapshot.minuteOfDay, start: trigger.startMinute, end: trigger.endMinute)
      else { return nil }
      return "Current time is in the configured range"
    case .activeDisplay:
      let wanted = normalized(trigger.text)
      guard
        normalized(snapshot.activeDisplayID) == wanted
          || normalized(snapshot.activeDisplayName) == wanted
      else { return nil }
      return "Active display is \(trigger.text)"
    case .wifiNetwork:
      guard normalized(snapshot.wifiNetwork) == normalized(trigger.text) else { return nil }
      return "Connected to \(trigger.text)"
    }
  }

  static func contains(minute: Int, start: Int, end: Int) -> Bool {
    guard (0..<24 * 60).contains(minute), start != end else { return false }
    if start < end { return (start..<end).contains(minute) }
    return minute >= start || minute < end
  }

  private static func normalized(_ value: String?) -> String {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
  }
}

struct ContextRuleRuntime: Equatable, Sendable {
  private(set) var isSleeping = false
  private(set) var resolution = ContextRuleResolution.none

  mutating func evaluate(
    rules: [ContextRule], snapshot: ContextSnapshot, manualOverride: ContextManualOverride?,
    now: Date
  ) {
    guard !isSleeping else { return }
    resolution = ContextRuleEvaluator.resolve(
      rules: rules, snapshot: snapshot, manualOverride: manualOverride, now: now)
  }

  mutating func sleep() {
    isSleeping = true
    resolution = .none
  }

  mutating func wake(
    rules: [ContextRule], snapshot: ContextSnapshot, manualOverride: ContextManualOverride?,
    now: Date
  ) {
    isSleeping = false
    evaluate(rules: rules, snapshot: snapshot, manualOverride: manualOverride, now: now)
  }
}

extension EnergyMode {
  var title: String {
    switch self {
    case .automatic: "Automatic"
    case .lowEnergy: "Low Energy"
    case .live: "Live"
    }
  }
}
