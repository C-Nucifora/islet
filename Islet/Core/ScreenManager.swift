import AppKit
import Combine
import Defaults
import SwiftUI

/// The view state that has to survive replacing a panel and its SwiftUI tree.
struct PanelPresentationState: Equatable {
  var notchState: NotchState = .closed
  var selectedActivityID: String?
  var temporarilyPresentedActivityID: String?
  var expandedWidth: CGFloat = Metrics.expandedSize.width
  var expandedHeight: CGFloat = Metrics.expandedSize.height

  static let initial = PanelPresentationState()
}

nonisolated enum TimerCompletionVisibility {
  static func isVisible(
    screenAwake: Bool, sessionActive: Bool, visiblePanelPresentingTimer: Bool
  ) -> Bool {
    screenAwake && sessionActive && visiblePanelPresentingTimer
  }
}

/// A hardware identity is used only when macOS gives the same display a new UUID. External
/// displays without a serial number are deliberately left unmatched rather than risking state
/// moving between two identical monitors.
enum DisplayHardwareIdentity: Hashable {
  case builtin
  case external(vendor: UInt32, model: UInt32, serial: UInt32)
}

struct ManagedDisplay: Equatable {
  let id: String
  let hardwareIdentity: DisplayHardwareIdentity?
}

struct ManagedDisplayState: Equatable {
  let display: ManagedDisplay
  let presentation: PanelPresentationState
}

/// Pure display-state matching policy. Keeping this independent of AppKit makes display-change
/// behavior deterministic in tests and keeps panel creation and teardown unchanged.
enum DisplayStateReconciler {
  static func reconcile(
    previous: [ManagedDisplayState], current: [ManagedDisplay], preferredDisplayID: String?
  ) -> [String: PanelPresentationState] {
    var result = Dictionary(
      uniqueKeysWithValues: current.map { ($0.id, PanelPresentationState.initial) })
    var remainingPrevious = Dictionary(uniqueKeysWithValues: previous.map { ($0.display.id, $0) })
    var unmatchedCurrent = current

    // A stable display UUID is the strongest match and remains valid across rearrangement.
    for display in current where remainingPrevious[display.id] != nil {
      result[display.id] = remainingPrevious.removeValue(forKey: display.id)?.presentation
      unmatchedCurrent.removeAll { $0.id == display.id }
    }

    // A changed UUID is accepted only when one old and one new display share a reliable identity.
    let identities = Set(unmatchedCurrent.compactMap(\.hardwareIdentity))
    for identity in identities {
      let oldMatches = remainingPrevious.values.filter {
        $0.display.hardwareIdentity == identity
      }
      let newMatches = unmatchedCurrent.filter { $0.hardwareIdentity == identity }
      guard oldMatches.count == 1, newMatches.count == 1,
        let old = oldMatches.first, let new = newMatches.first
      else { continue }
      result[new.id] = old.presentation
      remainingPrevious.removeValue(forKey: old.display.id)
      unmatchedCurrent.removeAll { $0.id == new.id }
    }

    // If an open panel vanished, keep that presentation open on a surviving target. Prefer the
    // screen under the pointer, then target-screen order. Never replace another open presentation.
    var destinationIDs = current.map(\.id)
    if let preferredDisplayID,
      let index = destinationIDs.firstIndex(of: preferredDisplayID)
    {
      destinationIDs.remove(at: index)
      destinationIDs.insert(preferredDisplayID, at: 0)
    }
    let vanishedPresentations = remainingPrevious.values
      .filter { $0.presentation.notchState.isExpanded }
      .sorted { $0.display.id < $1.display.id }
    for vanished in vanishedPresentations {
      guard
        let destinationID = destinationIDs.first(where: {
          result[$0]?.notchState.isExpanded == false
        })
      else { break }
      result[destinationID] = vanished.presentation
    }

    return result
  }
}

/// One notch panel plus the frame plumbing that keeps its reserved host window in place.
///
/// A class rather than a struct because re-asserting a frame needs per-panel mutable state: the
/// re-entrancy guard has to outlive any single call, or a `didMove` fired by our own `setFrame`
/// would call straight back into it.
@MainActor
private final class PanelInstance {
  let display: ManagedDisplay
  let panel: NotchPanel
  let viewModel: NotchViewModel
  var cancellables: Set<AnyCancellable> = []
  private var isApplying = false
  private let pointerMonitoringID = UUID()

  var screenUUID: String { display.id }

  init(display: ManagedDisplay, panel: NotchPanel, viewModel: NotchViewModel) {
    self.display = display
    self.panel = panel
    self.viewModel = viewModel
  }

  /// Reasserts the panel's one reserved frame.
  ///
  /// The window's real frame is read straight back and pushed into the model. `NotchPanel` returns
  /// `constrainFrameRect` unchanged so the two should always agree, but the island is positioned
  /// inside the real frame, so any system adjustment still has to be measured.
  ///
  /// The visible island changes size inside this frame. Resizing the NSWindow in response to a
  /// SwiftUI geometry callback races NSHostingView constraint maintenance and AppKit terminates
  /// the process in `_postWindowNeedsUpdateConstraints`.
  private func applyReservedFrame() {
    guard !isApplying else { return }
    isApplying = true
    let frame = viewModel.reservedPanelFrame
    panel.setFrame(frame, display: false)
    let actual = panel.frame
    if actual != frame {
      Log.app.error(
        "Panel frame diverged on \(self.screenUUID, privacy: .public): requested \(NSStringFromRect(frame), privacy: .public) actual \(NSStringFromRect(actual), privacy: .public)"
      )
    }
    viewModel.setActualPanelFrame(actual)
    isApplying = false
  }

  /// Feeds the window's real frame into the model without touching the window.
  func syncActualFrame() { viewModel.setActualPanelFrame(panel.frame) }

  /// Unconditional re-push of the reserved frame. A display or Space transition can move a panel
  /// behind our back without changing any model value that could trigger a Combine publisher.
  func reassert() { applyReservedFrame() }

  /// The panel is `isMovable = false` and Islet never drags it, so a move we did not cause is the
  /// system relocating the window — put it back. Gated on an actual mismatch, which makes this a
  /// fixed point: a `setFrame` that lands exactly where asked posts no move, so it cannot loop.
  func reassertIfMoved() {
    guard !isApplying else { return }
    guard panel.frame != viewModel.reservedPanelFrame else {
      syncActualFrame()
      return
    }
    Log.app.notice("Panel on \(self.screenUUID, privacy: .public) moved; re-asserting its frame")
    reassert()
  }

  func updateMousePassthrough(
    at location: CGPoint = NSEvent.mouseLocation, allowingCompactFileDrag: Bool = false
  ) {
    EventMonitors.shared.setPointerPassthroughNeeded(
      viewModel.needsPointerPassthroughMonitoring, sourceID: pointerMonitoringID)
    let shouldIgnore = viewModel.shouldIgnorePanelMouseEvents(
      at: location, allowingCompactFileDrag: allowingCompactFileDrag)
    if panel.ignoresMouseEvents != shouldIgnore { panel.ignoresMouseEvents = shouldIgnore }
  }

  func stop() {
    EventMonitors.shared.setPointerPassthroughNeeded(false, sourceID: pointerMonitoringID)
    cancellables.removeAll()
    panel.close()
  }
}

/// One notch panel per active screen, keyed by display UUID. Rebuilds on display changes;
/// hides panels on screens showing a fullscreen app when that option is enabled.
@MainActor
final class ScreenManager: ObservableObject {
  private struct PendingOpenedActivity {
    let id: String
    let allowingDisabledActivity: Bool
  }

  static let shared = ScreenManager()

  @Published private(set) var displayChoices: [DisplayChoice] = []
  private var instances: [String: PanelInstance] = [:]
  private var cancellables: Set<AnyCancellable> = []
  private var fullscreenTimer: AnyCancellable?
  private var displayState = ScreenManagerDisplayState()
  private var fullscreenTransitionRefreshes: Set<AnyCancellable> = []
  private var fullscreenTransitionRevision = FullscreenTransitionRevision()
  private var pendingOpenedActivity: PendingOpenedActivity?
  private var isScreenAwake = true
  private var isSessionActive = true
  /// Last-known notch measurements per display, so a transient empty aux-area read can't downgrade
  /// a built-in screen to the 200pt fallback for the rest of the session.
  private var stickiness = NotchStickiness()

  /// The view model on the screen under the mouse (for menu-bar-driven actions), else any.
  var viewModel: NotchViewModel? {
    let displays = DisplaySelection.snapshots()
    let pointerID = NSScreen.screenWithMouse?.displayUUID.flatMap(DisplaySelection.stableID)
    guard
      let targetID = DisplaySelection.actionTargetID(
        showOnAllDisplays: Defaults[.showOnAllDisplays],
        storedPreference: Defaults[.preferredDisplayID],
        displays: displays,
        displayUnderPointerID: pointerID)
    else { return nil }
    if let instance = instances[targetID] { return instance.viewModel }

    // A preference change publishes asynchronously, and screen changes are deliberately debounced.
    // Build the new target now if an action arrives in that gap so Show Islet and Quick Actions do
    // not silently address the panel from the previous display set.
    rebuild()
    // The screen set itself may have changed between the snapshot above and the rebuild. In
    // single-display mode the rebuilt set contains exactly the fresh fallback; in all-display
    // mode any remaining panel is preferable to dropping the user action.
    return instances[targetID]?.viewModel ?? instances.values.first?.viewModel
  }

  /// A completion is already visible when the session and screen are available and a visible
  /// expanded panel is showing the timer. A compact countdown or a hidden fullscreen panel is not
  /// enough context to suppress the macOS notification.
  var isTimerCompletionVisible: Bool {
    TimerCompletionVisibility.isVisible(
      screenAwake: isScreenAwake,
      sessionActive: isSessionActive,
      visiblePanelPresentingTimer: instances.values.contains {
        $0.panel.isVisible && $0.viewModel.isPresenting(activityID: "timer")
      })
  }

  func openCompletedTimer() {
    open(activityID: "timer", allowingDisabledActivity: true)
  }

  private func open(activityID: String, allowingDisabledActivity: Bool = false) {
    guard
      let instance = instances.values.first(where: { $0.panel.isVisible }) ?? instances.values.first
    else {
      // A notification response can arrive while a cold launch is still building its panels.
      // Preserve the intent and replay it after `rebuild()` has created the first island.
      pendingOpenedActivity = PendingOpenedActivity(
        id: activityID, allowingDisabledActivity: allowingDisabledActivity)
      return
    }
    pendingOpenedActivity = nil
    instance.panel.orderFrontRegardless()
    instance.viewModel.open(
      activityID: activityID, allowingDisabledActivity: allowingDisabledActivity)
    instance.updateMousePassthrough()
  }

  func start() {
    guard cancellables.isEmpty else { return }
    rebuild()
    NotificationCenter.default
      .publisher(for: NSApplication.didChangeScreenParametersNotification)
      .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
      .sink { [weak self] _ in self?.rebuild() }
      .store(in: &cancellables)
    // Undebounced companion to the rebuild above. A display reconfiguration can displace the window
    // straight away, and half a second of a visibly misplaced island is half a second too many;
    // harmless when the debounced rebuild later replaces the panel outright.
    NotificationCenter.default
      .publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in self?.reassertAll() }
      .store(in: &cancellables)
    // Registered UNCONDITIONALLY, not behind `hideInFullscreen` (which defaults to false): a Space
    // switch is the most common way the panel ends up somewhere we did not put it.
    // `applyFullscreenVisibility` no-ops on its own when the option is off.
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
      .sink { [weak self] _ in
        self?.reassertAll()
        self?.refreshFullscreenTransition()
      }
      .store(in: &cancellables)
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.didActivateApplicationNotification)
      .sink { [weak self] _ in
        self?.reassertAll()
        self?.applyFullscreenVisibility()
      }
      .store(in: &cancellables)
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.didWakeNotification)
      .merge(
        with: NSWorkspace.shared.notificationCenter.publisher(
          for: NSWorkspace.sessionDidBecomeActiveNotification)
      )
      .sink { [weak self] _ in self?.refreshFullscreenTransition() }
      .store(in: &cancellables)
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.screensDidSleepNotification)
      .sink { [weak self] _ in self?.isScreenAwake = false }
      .store(in: &cancellables)
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.screensDidWakeNotification)
      .sink { [weak self] _ in self?.isScreenAwake = true }
      .store(in: &cancellables)
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.sessionDidResignActiveNotification)
      .sink { [weak self] _ in self?.isSessionActive = false }
      .store(in: &cancellables)
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
      .sink { [weak self] _ in self?.isSessionActive = true }
      .store(in: &cancellables)
    Defaults.publisher(.hideFromScreenRecording)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] change in
        if let instances = self?.instances.values {
          for instance in instances {
            instance.panel.sharingType = ScreenCaptureExclusionPolicy.current.sharingType(
              exclusionRequested: change.newValue)
          }
        }
      }
      .store(in: &cancellables)
    Defaults.publisher(.showOnAllDisplays)
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.rebuild() }
      .store(in: &cancellables)
    Defaults.publisher(.preferredDisplayID)
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.rebuild() }
      .store(in: &cancellables)
    Defaults.publisher(.hideInFullscreen)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.updateFullscreenObserving() }
      .store(in: &cancellables)
    updateFullscreenObserving()
  }

  func stop() {
    fullscreenTimer = nil
    fullscreenTransitionRefreshes.removeAll()
    cancellables.removeAll()
    for instance in instances.values { instance.stop() }
    instances.removeAll()
    displayState.reset()
  }

  private func targetScreens() -> [NSScreen] {
    let screens = NSScreen.screens
    let displays = DisplaySelection.snapshots(from: screens)
    displayChoices = DisplaySelection.choices(from: displays)

    let storedPreference = Defaults[.preferredDisplayID]
    let migratedPreference = DisplaySelection.migratedPreference(
      storedPreference: storedPreference, displays: displays)
    if let migratedPreference {
      Defaults[.preferredDisplayID] = migratedPreference
    }

    let activePreference = migratedPreference ?? storedPreference
    if let preferredID = DisplaySelection.resolvedPreferredID(
      storedPreference: activePreference, displays: displays),
      let choice = displayChoices.first(where: { $0.id == preferredID }),
      Defaults[.preferredDisplayName] != choice.name
    {
      Defaults[.preferredDisplayName] = choice.name
    }

    let transition = displayState.reconcile(
      showOnAllDisplays: Defaults[.showOnAllDisplays],
      storedPreference: activePreference,
      displays: displays)
    let screensByID = Dictionary(
      screens.compactMap { screen -> (String, NSScreen)? in
        guard let id = screen.displayUUID.flatMap(DisplaySelection.stableID) else { return nil }
        return (id, screen)
      }, uniquingKeysWith: { first, _ in first })
    return transition.panelIDs.compactMap { screensByID[$0] }
  }

  func rebuild() {
    let previous = instances.values.map {
      ManagedDisplayState(display: $0.display, presentation: $0.viewModel.presentationState)
    }
    let targets = targetScreens().compactMap { screen -> (NSScreen, ManagedDisplay)? in
      guard let id = screen.displayUUID else { return nil }
      return (screen, ManagedDisplay(id: id, hardwareIdentity: screen.displayHardwareIdentity))
    }
    let presentations = DisplayStateReconciler.reconcile(
      previous: previous, current: targets.map(\.1),
      preferredDisplayID: NSScreen.screenWithMouse?.displayUUID)

    for instance in instances.values { instance.stop() }
    instances.removeAll()

    for (screen, display) in targets {
      let uuid = display.id
      let raw = screen.notchReading
      let reading = stickiness.resolve(
        displayUUID: uuid, isBuiltin: screen.isBuiltin, reading: raw)
      if reading != raw {
        let kept =
          "safeAreaTop \(reading.safeAreaTop) aux \(reading.auxLeftWidth)/\(reading.auxRightWidth)"
        Log.app.notice(
          "Display \(uuid, privacy: .public) reported no notch; keeping \(kept, privacy: .public)")
      }
      let geometry = screen.notchGeometry(reading: reading)
      let vm = NotchViewModel(
        geometry: geometry, initialPresentation: presentations[uuid] ?? .initial)
      let panel = NotchPanel(frame: vm.reservedPanelFrame)
      let dropZoneID = UUID()
      panel.contentView = NotchHosting.view(for: vm)
      let inst = PanelInstance(display: display, panel: panel, viewModel: vm)
      panel.acceptsFileDrops = {
        ActivityCenter.shared.isAvailableInExpandedSwitcher("shelf")
          && !vm.shouldIgnorePanelMouseEvents(
            at: NSEvent.mouseLocation, allowingCompactFileDrag: true)
      }
      panel.fileDragTargetChanged = { [weak inst] targeted in
        ShelfModel.shared.setDropTarget(dropZoneID, active: targeted)
        if targeted { vm.apply(.fileDragEntered) }
        if !targeted { inst?.updateMousePassthrough() }
      }
      panel.fileURLsDropped = { urls in
        ShelfModel.shared.importDroppedURLs(urls)
      }
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      panel.setFrame(vm.reservedPanelFrame, display: true)
      panel.sharingType = ScreenCaptureExclusionPolicy.current.sharingType(
        exclusionRequested: Defaults[.hideFromScreenRecording])

      inst.syncActualFrame()  // seed from the window we just placed, before anything is drawn
      vm.resumePointerTracking(at: NSEvent.mouseLocation)
      inst.updateMousePassthrough()
      panel.alphaValue = 1  // alpha-flash hides ghost frames
      Publishers.CombineLatest4(
        vm.$state, vm.$expandedWidth, vm.$expandedHeight, vm.$actualPanelFrame
      )
      .sink { [weak inst] _ in inst?.updateMousePassthrough() }
      .store(in: &inst.cancellables)
      vm.$compactTargetRevision
        .dropFirst()
        .sink { [weak inst] _ in inst?.updateMousePassthrough() }
        .store(in: &inst.cancellables)
      EventMonitors.shared.pointerMovement
        .sink { [weak inst] location in inst?.updateMousePassthrough(at: location) }
        .store(in: &inst.cancellables)
      EventMonitors.shared.fileDragMovement
        .sink { [weak inst] location in
          inst?.updateMousePassthrough(at: location, allowingCompactFileDrag: true)
        }
        .store(in: &inst.cancellables)
      NotificationCenter.default
        .publisher(for: NSWindow.didMoveNotification, object: panel)
        .sink { [weak inst] _ in inst?.reassertIfMoved() }
        .store(in: &inst.cancellables)
      instances[uuid] = inst
    }
    Log.shell.info("Built \(self.instances.count) notch panel(s)")
    applyFullscreenVisibility()
    if let pendingOpenedActivity {
      open(
        activityID: pendingOpenedActivity.id,
        allowingDisabledActivity: pendingOpenedActivity.allowingDisabledActivity)
    }
  }

  /// Re-pushes every panel's reserved frame after a display, Space or app activation change.
  private func reassertAll() {
    for inst in instances.values { inst.reassert() }
  }

  // MARK: - Fullscreen awareness

  private func updateFullscreenObserving() {
    if Defaults[.hideInFullscreen] {
      // Space and application notifications are the normal update path. This poll only recovers
      // if WindowServer fails to send a notification or an update arrives while the Mac sleeps.
      fullscreenTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
        .sink { [weak self] _ in self?.applyFullscreenVisibility() }
      applyFullscreenVisibility()
    } else {
      fullscreenTimer = nil
      fullscreenTransitionRefreshes.removeAll()
      // Restore any panel we hid.
      for instance in instances.values where !instance.panel.isVisible {
        instance.panel.orderFrontRegardless()
      }
    }
  }

  private func applyFullscreenVisibility() {
    guard Defaults[.hideInFullscreen] else { return }
    let fullscreenDisplays = FullscreenDetector.fullscreenDisplayUUIDs()
    for inst in instances.values {
      let hidden = fullscreenDisplays.contains(inst.screenUUID)
      // orderOut (not alpha 0) so the hidden panel's SwiftUI tree stops rendering entirely.
      if hidden, inst.panel.isVisible {
        inst.panel.orderOut(nil)
      } else if !hidden, !inst.panel.isVisible {
        inst.panel.orderFrontRegardless()
      }
    }
  }

  /// WindowServer can post the Space-change notification just before its current-Space snapshot
  /// settles. Apply once now, then resample twice after the animation. Starting another transition
  /// invalidates the older follow-ups, which prevents a rapid Space switch from replaying stale
  /// work after the latest transition.
  private func refreshFullscreenTransition() {
    guard Defaults[.hideInFullscreen] else { return }
    fullscreenTransitionRefreshes.removeAll()
    let revision = fullscreenTransitionRevision.begin()
    applyFullscreenVisibility()

    for delay in FullscreenTransitionRevision.followUpDelays {
      Just(())
        .delay(for: .seconds(delay), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
          guard let self, fullscreenTransitionRevision.accepts(revision) else { return }
          applyFullscreenVisibility()
        }
        .store(in: &fullscreenTransitionRefreshes)
    }
  }
}

nonisolated struct FullscreenTransitionRevision {
  static let followUpDelays: [TimeInterval] = [0.2, 0.8]

  private(set) var value = 0

  mutating func begin() -> Int {
    value &+= 1
    return value
  }

  func accepts(_ revision: Int) -> Bool { revision == value }
}
