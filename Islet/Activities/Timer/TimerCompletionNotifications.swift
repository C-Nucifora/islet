import AppKit
import UserNotifications

/// The subset of notification authorization needed by timer completion. Keeping it independent of
/// UserNotifications lets the delivery policy run in tests without touching macOS notification
/// settings or creating a real alert.
enum TimerNotificationAuthorization: Equatable, Sendable {
  case notDetermined
  case allowed
  case denied
}

struct TimerCompletionAlert: Equatable, Sendable {
  let identifier: String
  let title: String
  let body: String
}

@MainActor
protocol TimerCompletionNotificationClient: AnyObject {
  func authorizationStatus(
    _ completion: @escaping @MainActor (TimerNotificationAuthorization) -> Void)
  func requestAuthorization(_ completion: @escaping @MainActor (Bool) -> Void)
  func deliver(
    _ alert: TimerCompletionAlert, completion: @escaping @MainActor (Error?) -> Void)
}

/// A timer asks for notifications when the user starts it, rather than at app launch. Completion
/// delivery then remains conditional on whether the island already shows the result.
@MainActor
protocol TimerCompletionNotifying: AnyObject {
  func prepareForTimerStart(onUnavailable: @escaping @MainActor () -> Void)
  func notifyTimerFinished(
    completionID: UUID, title: String, body: String,
    onUnavailable: @escaping @MainActor () -> Void)
}

@MainActor
final class TimerCompletionNotificationCoordinator: TimerCompletionNotifying {
  private let client: any TimerCompletionNotificationClient
  private let isCompletionVisible: () -> Bool
  private var requestedPermission = false
  private var handledCompletionIDs: Set<UUID> = []
  private var handledCompletionOrder: [UUID] = []
  private static let maximumHandledCompletionCount = 256

  init(
    client: any TimerCompletionNotificationClient,
    isCompletionVisible: @escaping () -> Bool
  ) {
    self.client = client
    self.isCompletionVisible = isCompletionVisible
  }

  func prepareForTimerStart(onUnavailable: @escaping @MainActor () -> Void) {
    client.authorizationStatus { [weak self] status in
      guard let self else { return }
      switch status {
      case .allowed:
        break
      case .denied:
        onUnavailable()
      case .notDetermined:
        guard !requestedPermission else { return }
        requestedPermission = true
        client.requestAuthorization { [weak self] granted in
          self?.requestedPermission = false
          if !granted { onUnavailable() }
        }
      }
    }
  }

  func notifyTimerFinished(
    completionID: UUID, title: String, body: String,
    onUnavailable: @escaping @MainActor () -> Void
  ) {
    // A completion can be observed both by a deadline task and a control action at its deadline.
    // Record it before the asynchronous authorization lookup so those paths cannot queue twins.
    guard handledCompletionIDs.insert(completionID).inserted else { return }
    handledCompletionOrder.append(completionID)
    if handledCompletionOrder.count > Self.maximumHandledCompletionCount {
      handledCompletionIDs.remove(handledCompletionOrder.removeFirst())
    }
    guard !isCompletionVisible() else { return }

    client.authorizationStatus { [weak self] status in
      guard let self else { return }
      guard status == .allowed else {
        onUnavailable()
        return
      }
      // Authorization is asynchronous. The user may have opened Islet while it was being read, so
      // recheck immediately before delivery to avoid a redundant banner beside the visible result.
      guard !isCompletionVisible() else { return }
      let alert = TimerCompletionAlert(
        identifier: Self.identifier(for: completionID), title: title, body: body)
      client.deliver(alert) { error in
        if error != nil { onUnavailable() }
      }
    }
  }

  static func identifier(for completionID: UUID) -> String {
    "timer-completion-\(completionID.uuidString)"
  }
}

/// Production bridge for the pure coordinator. AppDelegate owns this object for the app lifetime,
/// which also keeps the UserNotifications delegate alive while Islet runs as an accessory app.
@MainActor
final class TimerCompletionNotifications: NSObject, TimerCompletionNotifying,
  UNUserNotificationCenterDelegate
{
  static let shared = TimerCompletionNotifications()

  private let center: UNUserNotificationCenter
  private let coordinator: TimerCompletionNotificationCoordinator

  private override init() {
    let center = UNUserNotificationCenter.current()
    self.center = center
    coordinator = TimerCompletionNotificationCoordinator(
      client: UserNotificationClient(center: center),
      isCompletionVisible: { ScreenManager.shared.isTimerCompletionVisible })
    super.init()
  }

  func start() {
    center.delegate = self
  }

  func prepareForTimerStart(onUnavailable: @escaping @MainActor () -> Void) {
    coordinator.prepareForTimerStart(onUnavailable: onUnavailable)
  }

  func notifyTimerFinished(
    completionID: UUID, title: String, body: String,
    onUnavailable: @escaping @MainActor () -> Void
  ) {
    coordinator.notifyTimerFinished(
      completionID: completionID, title: title, body: body, onUnavailable: onUnavailable)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let identifier = response.notification.request.identifier
    if identifier.hasPrefix("timer-completion-") {
      let title = response.notification.request.content.title
      Task { @MainActor in
        AppState.timer.presentCompletionFromNotification(title: title)
        NSApp.activate(ignoringOtherApps: true)
        ScreenManager.shared.openCompletedTimer()
      }
    }
    completionHandler()
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // The coordinator has already suppressed a visible island completion. For a hidden island,
    // keep the banner and sound even when Islet is technically active in the background.
    completionHandler([.banner, .list, .sound])
  }
}

@MainActor
private final class UserNotificationClient: TimerCompletionNotificationClient {
  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter) {
    self.center = center
  }

  func authorizationStatus(
    _ completion: @escaping @MainActor (TimerNotificationAuthorization) -> Void
  ) {
    center.getNotificationSettings { settings in
      let status: TimerNotificationAuthorization
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral:
        status = .allowed
      case .notDetermined:
        status = .notDetermined
      case .denied:
        status = .denied
      @unknown default:
        status = .denied
      }
      Task { @MainActor in
        completion(status)
      }
    }
  }

  func requestAuthorization(_ completion: @escaping @MainActor (Bool) -> Void) {
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
      Task { @MainActor in completion(granted && error == nil) }
    }
  }

  func deliver(
    _ alert: TimerCompletionAlert, completion: @escaping @MainActor (Error?) -> Void
  ) {
    let content = UNMutableNotificationContent()
    content.title = alert.title
    content.body = alert.body
    content.sound = .default
    center.add(UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil))
    {
      error in
      Task { @MainActor in completion(error) }
    }
  }
}
