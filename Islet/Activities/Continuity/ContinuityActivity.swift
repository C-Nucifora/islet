import Combine
import Defaults
import SwiftUI

/// The iPhone tab: which apps are running Live Activities on the paired phone.
@MainActor
final class ContinuityActivity: NotchActivity, ObservableObject {
  let id = "continuity"
  let priority = ActivityPriority.ambient
  let tabIcon = "iphone.gen3"
  private(set) var activationDate: Date?

  let monitor = ContinuityMonitor.shared
  private var cancellables: Set<AnyCancellable> = []

  var isActive: Bool {
    return !monitor.cards.isEmpty || Defaults[.continuityAlwaysVisible]
  }

  /// The card the compact island shows: the leftmost in the menu bar, matching what the user's eye
  /// lands on first.
  var promoted: LiveActivityCard? { monitor.cards.first }

  func start() {
    guard cancellables.isEmpty else { return }
    monitor.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        if self.isActive, self.activationDate == nil { self.activationDate = Date() }
        if !self.isActive { self.activationDate = nil }
        self.objectWillChange.send()
      }
      .store(in: &cancellables)
    monitor.start()
    if isActive { activationDate = Date() }
  }

  func stop() {
    guard !cancellables.isEmpty else { return }
    cancellables.removeAll()
    monitor.stop()
    activationDate = nil
    objectWillChange.send()
  }

  var compactLeading: AnyView { AnyView(ContinuityCompactLeading(activity: self)) }
  var compactTrailing: AnyView { AnyView(ContinuityCompactTrailing(activity: self)) }
  var expandedView: AnyView { AnyView(ContinuityExpandedView(activity: self)) }

  var accessibilityPrimaryActionName: String? {
    promoted == nil ? nil : "Opened iPhone Mirroring"
  }

  func performAccessibilityPrimaryAction() -> Bool {
    guard promoted != nil else { return false }
    return Self.openIPhoneMirroring()
  }

  @discardableResult
  static func openIPhoneMirroring() -> Bool {
    guard
      let url = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.ScreenContinuity")
    else { return false }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    return true
  }
}
