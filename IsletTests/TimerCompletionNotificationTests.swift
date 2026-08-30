import AppKit
import SwiftUI
import XCTest

@testable import Islet

@MainActor
final class TimerCompletionNotificationTests: XCTestCase {
  func testExpandedTimerIsVisibleWithoutApplicationActivation() {
    XCTAssertTrue(
      TimerCompletionVisibility.isVisible(
        screenAwake: true, sessionActive: true, visiblePanelPresentingTimer: true))
  }

  func testSleepingDisplayOrLockedSessionMakesTimerCompletionUnavailable() {
    XCTAssertFalse(
      TimerCompletionVisibility.isVisible(
        screenAwake: false, sessionActive: true, visiblePanelPresentingTimer: true))
    XCTAssertFalse(
      TimerCompletionVisibility.isVisible(
        screenAwake: true, sessionActive: false, visiblePanelPresentingTimer: true))
  }

  func testFinishedTimerRendersNotificationFallback() throws {
    let notifier = DeferredUnavailableTimerCompletionNotifierStub()
    let persistence = NotificationTimerPersistenceBox()
    let timer = TimerActivity(
      persistenceStore: persistence.store,
      completionNotifier: notifier)
    timer.start(300, label: "Focus")
    timer.cancel()
    timer.presentCompletionFromNotification(
      TimerCompletionSnapshot(duration: 300, label: "Focus"))
    notifier.reportUnavailable()

    XCTAssertTrue(timer.finished)
    XCTAssertNotNil(timer.notificationFallbackMessage)

    let size = CGSize(width: 400, height: 150)
    let host = NSHostingView(
      rootView: TimerExpandedView(activity: timer)
        .frame(width: size.width, height: size.height)
        .background(Color.black)
        .environment(\.appTheme, .ocean)
        .environment(\.colorScheme, .dark))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: CGRect(origin: CGPoint(x: -5_000, y: -5_000), size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.close() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))

    let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: representation)

    XCTAssertGreaterThan(
      orangePixelCount(in: representation), 20,
      "the finished presentation should render the notification fallback message")
  }

  func testNotificationActivationRestoresCompletionAfterTimerHasCleared() {
    let persistence = NotificationTimerPersistenceBox()
    let timer = TimerActivity(
      persistenceStore: persistence.store,
      completionNotifier: TimerCompletionNotifierStub())
    timer.start(300, label: "Focus")
    timer.cancel()

    timer.presentCompletionFromNotification(
      TimerCompletionSnapshot(duration: 300, label: "Focus"))

    XCTAssertTrue(timer.finished)
    XCTAssertTrue(timer.isActive)
    XCTAssertEqual(timer.label, "Focus")
    XCTAssertEqual(timer.total, 300)
    XCTAssertEqual(timer.remainingNow, 0)
  }

  func testNotificationActivationDoesNotReplaceANewerRunningTimer() {
    let persistence = NotificationTimerPersistenceBox()
    let timer = TimerActivity(
      persistenceStore: persistence.store,
      completionNotifier: TimerCompletionNotifierStub())
    timer.start(600, label: "Current")
    let currentDeadline = timer.endDate

    timer.presentCompletionFromNotification(
      TimerCompletionSnapshot(duration: 300, label: "Older"))

    XCTAssertTrue(timer.isRunning)
    XCTAssertFalse(timer.finished)
    XCTAssertEqual(timer.label, "Current")
    XCTAssertEqual(timer.endDate, currentDeadline)
  }

  func testNotificationActivationDoesNotReplaceANewerPausedTimer() {
    let persistence = NotificationTimerPersistenceBox()
    let timer = TimerActivity(
      persistenceStore: persistence.store,
      completionNotifier: TimerCompletionNotifierStub())
    timer.start(600, label: "Current")
    timer.togglePause()
    let currentRemaining = timer.remainingNow

    timer.presentCompletionFromNotification(
      TimerCompletionSnapshot(duration: 300, label: "Older"))

    XCTAssertTrue(timer.isPaused)
    XCTAssertFalse(timer.finished)
    XCTAssertEqual(timer.label, "Current")
    XCTAssertEqual(timer.remainingNow, currentRemaining, accuracy: 0.01)
  }

  func testNotificationActivationRestoresClickedSnapshotInsteadOfNewestPreset() {
    let persistence = NotificationTimerPersistenceBox()
    let timer = TimerActivity(
      persistenceStore: persistence.store,
      completionNotifier: TimerCompletionNotifierStub())
    timer.start(300, label: "Focus")
    timer.cancel()
    timer.start(600, label: "Break")
    timer.cancel()

    timer.presentCompletionFromNotification(
      TimerCompletionSnapshot(duration: 300, label: "Focus"))

    XCTAssertEqual(timer.total, 300)
    XCTAssertEqual(timer.label, "Focus")
    XCTAssertEqual(timer.lastDuration, 300)
    XCTAssertEqual(timer.lastLabel, "Focus")

    timer.restartLastTimer()

    XCTAssertTrue(timer.isRunning)
    XCTAssertEqual(timer.total, 300)
    XCTAssertEqual(timer.label, "Focus")
  }

  func testNotificationActivationRefreshesExistingRetainedCompletion() throws {
    let now = Date(timeIntervalSinceReferenceDate: 90_000)
    let session = TimerSessionSnapshot(
      savedAt: now.addingTimeInterval(-5), label: "Focus", duration: 300,
      deadline: now.addingTimeInterval(-1), isPaused: false, pausedRemaining: nil)
    let persistence = NotificationTimerPersistenceBox(
      sessionData: try XCTUnwrap(TimerPersistence.encode(session)))
    let timer = TimerActivity(
      persistenceStore: persistence.store, now: now,
      completionNotifier: TimerCompletionNotifierStub())
    XCTAssertTrue(timer.finished)

    timer.presentCompletionFromNotification(
      TimerCompletionSnapshot(duration: 600, label: "Break"))

    XCTAssertTrue(timer.finished)
    XCTAssertTrue(timer.isActive)
    XCTAssertEqual(timer.total, 600)
    XCTAssertEqual(timer.label, "Break")
  }

  func testCompletionSnapshotUsesStableNotificationMetadata() throws {
    let snapshot = TimerCompletionSnapshot(duration: 300, label: "Focus")

    XCTAssertEqual(snapshot.notificationUserInfo["islet.timer.duration"] as? Double, 300)
    XCTAssertEqual(snapshot.notificationUserInfo["islet.timer.label"] as? String, "Focus")
    XCTAssertEqual(
      TimerCompletionSnapshot(notificationUserInfo: [
        "islet.timer.duration": 300.0,
        "islet.timer.label": "Focus",
      ]),
      snapshot)
  }

  func testVisibleCompletionDoesNotDeliverANotification() {
    let client = NotificationClientStub(status: .allowed)
    let coordinator = TimerCompletionNotificationCoordinator(
      client: client, isCompletionVisible: { true })
    var fallbackCount = 0

    coordinator.notifyTimerFinished(
      completionID: UUID(), snapshot: TimerCompletionSnapshot(duration: 300, label: "Focus"),
      title: "Focus done", body: "Your timer finished."
    ) {
      fallbackCount += 1
    }

    XCTAssertTrue(client.alerts.isEmpty)
    XCTAssertEqual(fallbackCount, 0)
  }

  func testHiddenCompletionDeliversOnlyOnce() {
    let client = NotificationClientStub(status: .allowed)
    let coordinator = TimerCompletionNotificationCoordinator(
      client: client, isCompletionVisible: { false })
    let completionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    coordinator.notifyTimerFinished(
      completionID: completionID,
      snapshot: TimerCompletionSnapshot(duration: 300, label: "Focus"),
      title: "Focus done", body: "Your timer finished."
    ) {}
    coordinator.notifyTimerFinished(
      completionID: completionID,
      snapshot: TimerCompletionSnapshot(duration: 300, label: "Focus"),
      title: "Focus done", body: "Your timer finished."
    ) {}

    XCTAssertEqual(
      client.alerts,
      [
        TimerCompletionAlert(
          identifier: "timer-completion-11111111-1111-1111-1111-111111111111",
          title: "Focus done", body: "Your timer finished.",
          snapshot: TimerCompletionSnapshot(duration: 300, label: "Focus"))
      ])
  }

  func testCompletionThatBecomesVisibleDuringAuthorizationDoesNotDeliver() {
    let client = DeferredNotificationClientStub()
    var isVisible = false
    let coordinator = TimerCompletionNotificationCoordinator(
      client: client, isCompletionVisible: { isVisible })

    coordinator.notifyTimerFinished(
      completionID: UUID(), snapshot: TimerCompletionSnapshot(duration: 300, label: "Focus"),
      title: "Focus done", body: "Your timer finished."
    ) {}
    isVisible = true
    client.resolveAuthorization(as: .allowed)

    XCTAssertTrue(client.alerts.isEmpty)
  }

  func testPendingPermissionDeliversHiddenCompletionAfterAuthorizationIsGranted() {
    let client = PendingPermissionNotificationClientStub()
    let coordinator = TimerCompletionNotificationCoordinator(
      client: client, isCompletionVisible: { false })
    let completionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    var fallbackCount = 0

    coordinator.prepareForTimerStart { fallbackCount += 1 }
    coordinator.notifyTimerFinished(
      completionID: completionID,
      snapshot: TimerCompletionSnapshot(duration: 300, label: "Focus"),
      title: "Focus done", body: "Your timer finished."
    ) {
      fallbackCount += 1
    }

    XCTAssertTrue(client.alerts.isEmpty)
    XCTAssertEqual(fallbackCount, 0)

    client.resolvePermissionRequest(granted: true)

    XCTAssertEqual(
      client.alerts,
      [
        TimerCompletionAlert(
          identifier: "timer-completion-22222222-2222-2222-2222-222222222222",
          title: "Focus done", body: "Your timer finished.",
          snapshot: TimerCompletionSnapshot(duration: 300, label: "Focus"))
      ])
    XCTAssertEqual(fallbackCount, 0)
  }

  func testDeniedPermissionExplainsTheInAppFallbackWithoutDelivering() {
    let client = NotificationClientStub(status: .denied)
    let coordinator = TimerCompletionNotificationCoordinator(
      client: client, isCompletionVisible: { false })
    var fallbackCount = 0

    coordinator.prepareForTimerStart { fallbackCount += 1 }
    coordinator.notifyTimerFinished(
      completionID: UUID(), snapshot: TimerCompletionSnapshot(duration: 300, label: nil),
      title: "Timer done", body: "Your timer finished."
    ) {
      fallbackCount += 1
    }

    XCTAssertEqual(fallbackCount, 2)
    XCTAssertTrue(client.alerts.isEmpty)
    XCTAssertEqual(client.authorizationRequests, 0)
  }

  func testPermissionIsRequestedOnlyWhenATimerStarts() {
    let client = NotificationClientStub(status: .notDetermined, granted: false)
    let coordinator = TimerCompletionNotificationCoordinator(
      client: client, isCompletionVisible: { false })
    var fallbackCount = 0

    coordinator.prepareForTimerStart { fallbackCount += 1 }

    XCTAssertEqual(client.authorizationRequests, 1)
    XCTAssertEqual(fallbackCount, 1)
    XCTAssertTrue(client.alerts.isEmpty)
  }

  func testCompletionDoesNotPromptWhenNoStartTimeRequestIsPending() {
    let client = NotificationClientStub(status: .notDetermined, granted: false)
    let coordinator = TimerCompletionNotificationCoordinator(
      client: client, isCompletionVisible: { false })
    var fallbackCount = 0

    coordinator.notifyTimerFinished(
      completionID: UUID(), snapshot: TimerCompletionSnapshot(duration: 300, label: nil),
      title: "Timer done", body: "Your timer finished."
    ) {
      fallbackCount += 1
    }

    XCTAssertEqual(client.authorizationRequests, 0)
    XCTAssertEqual(fallbackCount, 1)
    XCTAssertTrue(client.alerts.isEmpty)
  }

  private func orangePixelCount(in representation: NSBitmapImageRep) -> Int {
    (0..<representation.pixelsHigh).reduce(into: 0) { count, y in
      for x in 0..<representation.pixelsWide {
        guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
          continue
        }
        if abs(color.hueComponent - 0.083) < 0.035, color.saturationComponent > 0.55,
          color.brightnessComponent > 0.45
        {
          count += 1
        }
      }
    }
  }
}

@MainActor
private final class TimerCompletionNotifierStub: TimerCompletionNotifying {
  func prepareForTimerStart(onUnavailable: @escaping @MainActor () -> Void) {}

  func notifyTimerFinished(
    completionID: UUID, snapshot: TimerCompletionSnapshot, title: String, body: String,
    onUnavailable: @escaping @MainActor () -> Void
  ) {}
}

@MainActor
private final class DeferredUnavailableTimerCompletionNotifierStub: TimerCompletionNotifying {
  private var onUnavailable: (() -> Void)?

  func prepareForTimerStart(onUnavailable: @escaping @MainActor () -> Void) {
    self.onUnavailable = onUnavailable
  }

  func notifyTimerFinished(
    completionID: UUID, snapshot: TimerCompletionSnapshot, title: String, body: String,
    onUnavailable: @escaping @MainActor () -> Void
  ) {}

  func reportUnavailable() {
    onUnavailable?()
  }
}

@MainActor
private final class NotificationTimerPersistenceBox {
  var sessionData: Data?
  var presetData: Data?

  init(sessionData: Data? = nil, presetData: Data? = nil) {
    self.sessionData = sessionData
    self.presetData = presetData
  }

  var store: TimerPersistenceStore {
    TimerPersistenceStore(
      readSessionData: { [weak self] in self?.sessionData },
      writeSessionData: { [weak self] in self?.sessionData = $0 },
      readPresetData: { [weak self] in self?.presetData },
      writePresetData: { [weak self] in self?.presetData = $0 })
  }
}

@MainActor
private final class NotificationClientStub: TimerCompletionNotificationClient {
  var status: TimerNotificationAuthorization
  var granted: Bool
  var authorizationRequests = 0
  var alerts: [TimerCompletionAlert] = []

  init(status: TimerNotificationAuthorization, granted: Bool = true) {
    self.status = status
    self.granted = granted
  }

  func authorizationStatus(
    _ completion: @escaping @MainActor (TimerNotificationAuthorization) -> Void
  ) {
    completion(status)
  }

  func requestAuthorization(_ completion: @escaping @MainActor (Bool) -> Void) {
    authorizationRequests += 1
    completion(granted)
  }

  func deliver(
    _ alert: TimerCompletionAlert, completion: @escaping @MainActor (Error?) -> Void
  ) {
    alerts.append(alert)
    completion(nil)
  }
}

@MainActor
private final class DeferredNotificationClientStub: TimerCompletionNotificationClient {
  private var authorizationCompletion: ((TimerNotificationAuthorization) -> Void)?
  var alerts: [TimerCompletionAlert] = []

  func authorizationStatus(
    _ completion: @escaping @MainActor (TimerNotificationAuthorization) -> Void
  ) {
    authorizationCompletion = completion
  }

  func resolveAuthorization(as status: TimerNotificationAuthorization) {
    let completion = authorizationCompletion
    authorizationCompletion = nil
    completion?(status)
  }

  func requestAuthorization(_ completion: @escaping @MainActor (Bool) -> Void) {
    completion(false)
  }

  func deliver(
    _ alert: TimerCompletionAlert, completion: @escaping @MainActor (Error?) -> Void
  ) {
    alerts.append(alert)
    completion(nil)
  }
}

@MainActor
private final class PendingPermissionNotificationClientStub: TimerCompletionNotificationClient {
  private var permissionCompletion: ((Bool) -> Void)?
  var alerts: [TimerCompletionAlert] = []

  func authorizationStatus(
    _ completion: @escaping @MainActor (TimerNotificationAuthorization) -> Void
  ) {
    completion(.notDetermined)
  }

  func requestAuthorization(_ completion: @escaping @MainActor (Bool) -> Void) {
    permissionCompletion = completion
  }

  func deliver(
    _ alert: TimerCompletionAlert, completion: @escaping @MainActor (Error?) -> Void
  ) {
    alerts.append(alert)
    completion(nil)
  }

  func resolvePermissionRequest(granted: Bool) {
    let completion = permissionCompletion
    permissionCompletion = nil
    completion?(granted)
  }
}
