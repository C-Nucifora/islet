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

/// One notch panel plus the frame plumbing that keeps its host window on the model's current frame.
///
/// A class rather than a struct because re-asserting a frame needs per-panel mutable state: the
/// re-entrancy guard has to outlive any single call, or a `didMove` fired by our own `setFrame`
/// would call straight back into it.
@MainActor
final class PanelInstance {
  let display: ManagedDisplay
  let panel: NotchPanel
  let viewModel: NotchViewModel
  var cancellables: Set<AnyCancellable> = []
  private var isApplying = false
  private var wasExpanded = false
  private let pointerMonitoringID = UUID()

  var screenUUID: String { display.id }

  init(display: ManagedDisplay, panel: NotchPanel, viewModel: NotchViewModel) {
    self.display = display
    self.panel = panel
    self.viewModel = viewModel
    viewModel.$panelFrame
      .removeDuplicates()
      .sink { [weak self] frame in self?.apply(frame) }
      .store(in: &cancellables)
  }

  /// Applies one frame transaction, aligns the fixed renderer inside the clipped window, then
  /// publishes the actual result.
  private func apply(_ frame: CGRect) {
    guard !isApplying else { return }
    isApplying = true
    if panel.frame != frame { panel.setFrame(frame, display: false) }
    let actual = panel.frame
    (panel.contentView as? NotchHostingContainer)?.alignRenderer(toWindowFrame: actual)
    if actual != frame {
      Log.app.error(
        "Panel frame diverged on \(self.screenUUID, privacy: .public): requested \(NSStringFromRect(frame), privacy: .public) actual \(NSStringFromRect(actual), privacy: .public)"
      )
    }
    viewModel.setActualPanelFrame(actual)
    isApplying = false
  }

  /// Feeds the window's real frame into the model without touching the window.
  func syncActualFrame() {
    (panel.contentView as? NotchHostingContainer)?.alignRenderer(toWindowFrame: panel.frame)
    viewModel.setActualPanelFrame(panel.frame)
  }

  /// Unconditional re-push of the current frame. A display or Space transition can move a panel
  /// behind our back without changing any model value that could trigger a Combine publisher.
  func reassert() {
    apply(viewModel.panelFrame)
  }

  /// The panel is `isMovable = false` and Islet never drags it, so a move we did not cause is the
  /// system relocating the window — put it back. Gated on an actual mismatch, which makes this a
  /// fixed point: a `setFrame` that lands exactly where asked posts no move, so it cannot loop.
  func reassertIfMoved() {
    guard !isApplying else { return }
    guard panel.frame != viewModel.panelFrame else {
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

  func updateKeyboardFocus(isExpanded: Bool) {
    guard isExpanded != wasExpanded else { return }
    wasExpanded = isExpanded
    if !isExpanded { panel.releaseKeyboardFocusIfAcquired() }
  }

  func requestKeyboardFocus() {
    guard viewModel.state.isExpanded else { return }
    panel.requestKeyboardFocus()
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
  private var topologyController: ScreenTopologyController
  private var cancellables: Set<AnyCancellable> = []
  private var fullscreenTimer: AnyCancellable?
  private var fullscreenTransitionRefreshes: Set<AnyCancellable> = []
  private var fullscreenTransitionRevision = FullscreenTransitionRevision()
  private var pendingOpenedActivity: PendingOpenedActivity?
  private var isScreenAwake = true
  private var isSessionActive = true
  private var lastActiveApplicationDisplayID: String?

  init(screenDescriptorProvider: any ScreenDescriptorProviding = AppKitScreenDescriptorProvider()) {
    topologyController = ScreenTopologyController(provider: screenDescriptorProvider)
  }

  /// The view model selected by the shared pointer, active app, preferred display and main-display
  /// policy. Callers that perform more than one operation should use `performOnActionTarget` so a
  /// concurrent display change cannot split one action across two panels.
  var viewModel: NotchViewModel? {
    resolveActionViewModel()
  }

  var isAnyPanelExpanded: Bool {
    instances.values.contains { $0.viewModel.state.isExpanded }
  }

  func performOnActionTarget(_ action: (NotchViewModel) -> Void) {
    guard let viewModel = resolveActionViewModel() else { return }
    action(viewModel)
  }

  /// Capture the active external app before opening an Islet-owned utility panel makes Islet the
  /// frontmost process. The action resolver also refreshes this immediately before each action.
  func captureActiveApplicationDisplay() {
    guard let application = NSWorkspace.shared.frontmostApplication else { return }
    captureActiveApplicationDisplay(application)
  }

  private func captureActiveApplicationDisplay(_ application: NSRunningApplication) {
    guard application.processIdentifier != NSRunningApplication.current.processIdentifier else {
      return
    }
    lastActiveApplicationDisplayID = activeApplicationDisplayID(
      processIdentifier: application.processIdentifier)
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
    captureActiveApplicationDisplay()
    rebuild()
    NotificationCenter.default
      .publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in
        self?.rebuild()
        self?.reassertAll()
      }
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
      .sink { [weak self] notification in
        if let application =
          notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        {
          self?.captureActiveApplicationDisplay(application)
        }
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
    topologyController.reset()
    lastActiveApplicationDisplayID = nil
  }

  private func resolveActionViewModel() -> NotchViewModel? {
    captureActiveApplicationDisplay()

    // Re-resolve after one synchronous rebuild. This handles the debounce window after a display
    // change or preference update without ever falling back to dictionary enumeration order.
    for attempt in 0...1 {
      let displays = DisplaySelection.snapshots()
      let pointerID = NSScreen.screenWithMouse?.displayUUID.flatMap(DisplaySelection.stableID)
      if let targetID = DisplaySelection.actionTargetID(
        showOnAllDisplays: Defaults[.showOnAllDisplays],
        storedPreference: Defaults[.preferredDisplayID],
        displays: displays,
        displayUnderPointerID: pointerID,
        activeApplicationDisplayID: lastActiveApplicationDisplayID,
        hostedPanelIDs: Set(instances.keys)),
        let instance = instances[targetID]
      {
        return instance.viewModel
      }
      if attempt == 0 { rebuild() }
    }
    return nil
  }

  private func activeApplicationDisplayID(processIdentifier: pid_t) -> String? {
    guard
      let windowInfo = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return nil }

    let windows = windowInfo.compactMap { window -> ActiveApplicationWindowSnapshot? in
      guard
        let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
        let layer = window[kCGWindowLayer as String] as? Int,
        let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
      else { return nil }
      return ActiveApplicationWindowSnapshot(
        ownerProcessIdentifier: ownerPID, layer: layer, bounds: bounds)
    }
    let displays = NSScreen.screens.compactMap { screen -> ActionDisplayGeometry? in
      guard
        let displayID = screen.displayID,
        let stableID = screen.displayUUID.flatMap(DisplaySelection.stableID),
        CGDisplayIsOnline(displayID) != 0, CGDisplayIsActive(displayID) != 0,
        CGDisplayIsAsleep(displayID) == 0
      else { return nil }
      return ActionDisplayGeometry(
        stableID: stableID, bounds: CGDisplayBounds(displayID),
        isMain: displayID == CGMainDisplayID())
    }
    return ActiveApplicationDisplayResolver.targetID(
      processIdentifier: processIdentifier, windows: windows, displays: displays)
  }

  private func targetDescriptors() -> ScreenTopologyTransition {
    let descriptors = topologyController.provider.currentDescriptors()
    let displays = descriptors.map(\.snapshot)
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

    return topologyController.reconcile(
      showOnAllDisplays: Defaults[.showOnAllDisplays],
      storedPreference: activePreference,
      descriptors: descriptors)
  }

  func rebuild() {
    let previous = instances.values.map {
      ManagedDisplayState(display: $0.display, presentation: $0.viewModel.presentationState)
    }
    let transition = targetDescriptors()
    let targets = transition.descriptors
    let presentations = DisplayStateReconciler.reconcile(
      previous: previous, current: targets.map(\.managedDisplay),
      preferredDisplayID: NSScreen.screenWithMouse?.displayUUID.flatMap(DisplaySelection.stableID))

    var replacementIDs = transition.replacementIDs
    for descriptor in targets {
      guard let instance = instances[descriptor.id],
        let presentation = presentations[descriptor.id]
      else { continue }
      if instance.viewModel.presentationState != presentation {
        replacementIDs.insert(descriptor.id)
      }
    }

    // Close vanished and reconfigured panels before creating replacements. This releases their
    // event subscriptions and drag targets in the same notification turn and prevents duplicate
    // windows for one display UUID.
    let targetIDs = Set(transition.panelIDs)
    let staleIDs = Set(instances.keys).subtracting(targetIDs).union(replacementIDs)
    for id in staleIDs {
      instances.removeValue(forKey: id)?.stop()
    }

    for descriptor in targets where instances[descriptor.id] == nil {
      let uuid = descriptor.id
      let vm = NotchViewModel(
        geometry: descriptor.geometry, initialPresentation: presentations[uuid] ?? .initial)
      let panel = NotchPanel(frame: vm.panelFrame)
      let dropZoneID = UUID()
      panel.contentView = NotchHosting.view(for: vm)
      let inst = PanelInstance(
        display: descriptor.managedDisplay, panel: panel, viewModel: vm)
      panel.acceptsFileDrops = {
        ActivityCenter.shared.isAvailableInExpandedSwitcher("shelf")
          && !vm.shouldIgnorePanelMouseEvents(
            at: NSEvent.mouseLocation, allowingCompactFileDrag: true)
      }
      panel.fileDragTargetChanged = { [weak inst] targeted in
        ShelfModel.shared.setDropTarget(dropZoneID, active: targeted)
        vm.setShelfDropTargeted(targeted)
        if targeted { vm.apply(.fileDragEntered) }
        if !targeted { inst?.updateMousePassthrough() }
      }
      panel.fileURLsDropped = { urls in
        ShelfModel.shared.importDroppedURLs(urls)
      }
      panel.keyboardCommandHandler = { [weak vm] command in
        guard let vm else { return false }
        return Self.handleKeyboardCommand(command, viewModel: vm)
      }
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      panel.setFrame(vm.panelFrame, display: true)
      panel.sharingType = ScreenCaptureExclusionPolicy.current.sharingType(
        exclusionRequested: Defaults[.hideFromScreenRecording])

      inst.syncActualFrame()  // seed from the window we just placed, before anything is drawn
      vm.resumePointerTracking(at: NSEvent.mouseLocation)
      inst.updateMousePassthrough()
      inst.updateKeyboardFocus(isExpanded: vm.state.isExpanded)
      panel.alphaValue = 1  // alpha-flash hides ghost frames
      Publishers.CombineLatest4(
        vm.$state, vm.$expandedWidth, vm.$expandedHeight, vm.$actualPanelFrame
      )
      .sink { [weak inst] state, _, _, _ in
        inst?.updateMousePassthrough()
        inst?.updateKeyboardFocus(isExpanded: state.isExpanded)
      }
      .store(in: &inst.cancellables)
      vm.$keyboardFocusRequestRevision
        .dropFirst()
        .sink { [weak inst] _ in inst?.requestKeyboardFocus() }
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

  private static func handleKeyboardCommand(
    _ command: IslandKeyboardCommand, viewModel: NotchViewModel
  ) -> Bool {
    guard viewModel.state.isExpanded else { return false }
    let activities = ActivityCenter.shared.expandedActivities
    let tabIDs = [ExpandedSelectionPolicy.homeID] + activities.map(\.id)
    let currentID = ExpandedSelectionPolicy.effectiveSelection(
      tabIDs: tabIDs, storedSelection: viewModel.selectedActivityID,
      shelfPresentationActive: viewModel.isShelfDropTargeted,
      primaryActivityID: ActivityCenter.shared.primaryActivity?.id)

    if let selectedID = IslandKeyboardPolicy.selectedID(
      for: command, tabIDs: tabIDs, currentID: currentID)
    {
      viewModel.selectActivity(selectedID)
      A11y.announce(
        selectedID == ExpandedSelectionPolicy.homeID
          ? "Home selected" : "\(ActivityCatalog.name(for: selectedID)) selected")
      return true
    }

    switch command {
    case .primaryAction:
      guard currentID != ExpandedSelectionPolicy.homeID,
        let activity = activities.first(where: { $0.id == currentID })
      else {
        A11y.announce("Home has no primary action")
        return true
      }
      let announcement = activity.accessibilityPrimaryActionName
      Task { @MainActor in
        guard await activity.performAccessibilityPrimaryAction() else {
          A11y.announce("\(ActivityCatalog.name(for: currentID)) has no available primary action")
          return
        }
        if let announcement { A11y.announce(announcement) }
      }
      return true
    case .dismissTransient:
      if HUDController.shared.dismiss() {
        A11y.announce("Dismissed")
        return true
      }
      if let activity = activities.first(where: { $0.id == currentID }),
        activity.dismissAccessibilityTransient()
      {
        A11y.announce("Dismissed")
        return true
      }
      if currentID == ExpandedSelectionPolicy.homeID,
        RemindersProvider.shared.lastActionError != nil
      {
        RemindersProvider.shared.dismissActionError()
        A11y.announce("Dismissed")
        return true
      }
      A11y.announce("Nothing to dismiss")
      return true
    case .close:
      viewModel.apply(.clickedNotch)
      A11y.announce("Islet closed")
      return true
    case .selectTab, .cycleTab:
      return false
    }
  }

  /// Re-pushes every panel's current frame after a display, Space or app activation change.
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
