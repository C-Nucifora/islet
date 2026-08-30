import XCTest

@testable import Islet

@MainActor
final class TimerCompletionNotificationTests: XCTestCase {
  func testVisibleCompletionDoesNotDeliverANotification() {
    let client = NotificationClientStub(status: .allowed)
    let coordinator = TimerCompletionNotificationCoordinator(
      client: client, isCompletionVisible: { true })
    var fallbackCount = 0

    coordinator.notifyTimerFinished(
      completionID: UUID(), title: "Focus done", body: "Your timer finished."
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
      completionID: completionID, title: "Focus done", body: "Your timer finished."
    ) {}
    coordinator.notifyTimerFinished(
      completionID: completionID, title: "Focus done", body: "Your timer finished."
    ) {}

    XCTAssertEqual(
      client.alerts,
      [
        TimerCompletionAlert(
          identifier: "timer-completion-11111111-1111-1111-1111-111111111111",
          title: "Focus done", body: "Your timer finished.")
      ])
  }

  func testCompletionThatBecomesVisibleDuringAuthorizationDoesNotDeliver() {
    let client = DeferredNotificationClientStub()
    var isVisible = false
    let coordinator = TimerCompletionNotificationCoordinator(
      client: client, isCompletionVisible: { isVisible })

    coordinator.notifyTimerFinished(
      completionID: UUID(), title: "Focus done", body: "Your timer finished."
    ) {}
    isVisible = true
    client.resolveAuthorization(as: .allowed)

    XCTAssertTrue(client.alerts.isEmpty)
  }

  func testDeniedPermissionExplainsTheInAppFallbackWithoutDelivering() {
    let client = NotificationClientStub(status: .denied)
    let coordinator = TimerCompletionNotificationCoordinator(
      client: client, isCompletionVisible: { false })
    var fallbackCount = 0

    coordinator.prepareForTimerStart { fallbackCount += 1 }
    coordinator.notifyTimerFinished(
      completionID: UUID(), title: "Timer done", body: "Your timer finished."
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
