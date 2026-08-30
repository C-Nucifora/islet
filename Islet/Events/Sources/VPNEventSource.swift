import AppKit
import Combine
import Defaults
import Foundation
import SystemConfiguration

/// Which tunnel interfaces exist right now.
///
/// Split from the source so the classifier is a pure, tested function. It is the only part that can
/// be wrong in a way tests can catch.
enum TunnelInterfaces {
  /// `utun` and `ipsec` are the tunnel families. The digit check matters: `utunnel` is not a tunnel,
  /// and a bare prefix match would classify it as one.
  static func isTunnel(_ name: String) -> Bool {
    for prefix in ["utun", "ipsec"] where name.hasPrefix(prefix) {
      let rest = name.dropFirst(prefix.count)
      return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }
    return false
  }

  /// Live interface names from `getifaddrs`. Public API, no permission.
  static func current() -> [String] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let head else { return [] }
    defer { freeifaddrs(head) }

    var names: Set<String> = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = head
    while let entry = cursor {
      let name = String(cString: entry.pointee.ifa_name)
      if isTunnel(name) { names.insert(name) }
      cursor = entry.pointee.ifa_next
    }
    return names.sorted()
  }
}

struct TunnelInterfaceChange: Equatable {
  let added: [String]
  let removed: [String]

  var isEmpty: Bool { added.isEmpty && removed.isEmpty }
}

/// Owns the interface baseline independently of the notification mechanism.
struct TunnelInterfaceTracker {
  private(set) var known: [String] = []

  mutating func setBaseline(_ interfaces: [String]) {
    known = interfaces
  }

  mutating func update(_ interfaces: [String]) -> TunnelInterfaceChange {
    let diff = SetDiff.changes(from: known, to: interfaces)
    known = interfaces
    return TunnelInterfaceChange(added: diff.added, removed: diff.removed)
  }

  mutating func reset() {
    known = []
  }
}

/// Generation tokens make a burst of dynamic-store callbacks produce one interface read.
struct TunnelRefreshGate {
  private var generation: UInt = 0

  mutating func signal() -> UInt {
    generation &+= 1
    return generation
  }

  func isCurrent(_ token: UInt) -> Bool {
    token == generation
  }

  mutating func reset() {
    generation &+= 1
  }
}

enum TunnelObservationCadence: Equatable {
  case subscribedRecovery
  case pollingFallback

  static func afterSubscription(started: Bool) -> Self {
    started ? .subscribedRecovery : .pollingFallback
  }

  func interval(for policy: EnergyPolicy) -> TimeInterval {
    switch self {
    case .pollingFallback:
      return policy.tunnelPollingInterval
    case .subscribedRecovery:
      if policy.isConstrained { return 15 * 60 }
      return policy.mode == .live ? 5 * 60 : 10 * 60
    }
  }
}

@MainActor
protocol TunnelNetworkChangeMonitoring: AnyObject {
  func start(handler: @escaping @MainActor () -> Void) -> Bool
  func stop()
}

/// The callback box crosses a C callback boundary. Its closure immediately returns to the main
/// actor before it touches the event source.
private final class TunnelDynamicStoreCallbackBox: @unchecked Sendable {
  let handler: @Sendable () -> Void

  init(handler: @escaping @Sendable () -> Void) {
    self.handler = handler
  }
}

@MainActor
private final class TunnelDynamicStoreMonitor: TunnelNetworkChangeMonitoring {
  private var store: SCDynamicStore?
  private var callbackBox: TunnelDynamicStoreCallbackBox?

  func start(handler: @escaping @MainActor () -> Void) -> Bool {
    guard store == nil else { return true }

    let box = TunnelDynamicStoreCallbackBox {
      Task { @MainActor in handler() }
    }
    var context = SCDynamicStoreContext(
      version: 0,
      info: Unmanaged.passUnretained(box).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil)
    guard
      let store = SCDynamicStoreCreate(
        nil,
        "dev.islet.network-tunnel" as CFString,
        { _, _, info in
          guard let info else { return }
          Unmanaged<TunnelDynamicStoreCallbackBox>.fromOpaque(info)
            .takeUnretainedValue().handler()
        },
        &context)
    else { return false }

    let patterns =
      [
        "State:/Network/Interface/.*/IPv4",
        "State:/Network/Interface/.*/IPv6",
        "State:/Network/Interface/.*/Link",
      ] as CFArray
    guard SCDynamicStoreSetNotificationKeys(store, nil, patterns) else { return false }
    guard SCDynamicStoreSetDispatchQueue(store, DispatchQueue.main) else { return false }

    callbackBox = box
    self.store = store
    return true
  }

  func stop() {
    if let store {
      SCDynamicStoreSetDispatchQueue(store, nil)
    }
    store = nil
    callbackBox = nil
  }
}

/// Network tunnels coming up and going down.
///
/// **Heuristic, and the event text says so.** A `utun` interface is not proof of a VPN: iCloud
/// Private Relay, Handoff, AirPlay and Continuity all create them. The event reads "Network tunnel
/// up", never "VPN connected", because Islet genuinely cannot tell the difference.
///
/// SystemConfiguration interface-state callbacks are the primary signal. A slow timer repairs a
/// missed callback, and falls back to the old energy-aware polling cadence if subscription setup
/// fails. Dynamic-store bursts are debounced before `getifaddrs`, so one network reconfiguration
/// causes one interface read.
@MainActor
final class VPNEventSource: SystemEventSource {
  let id = "vpn"
  let displayName = "Network tunnel"
  let tier = SystemEventTier.heuristic

  private let interfaceReader: () -> [String]
  private let monitor: any TunnelNetworkChangeMonitoring
  private let emitter: (SystemEvent) -> Void
  private let debounceDuration: Duration
  private var recoveryTimer: AnyCancellable?
  private var cancellables: Set<AnyCancellable> = []
  private var refreshTask: Task<Void, Never>?
  private var tracker = TunnelInterfaceTracker()
  private var refreshGate = TunnelRefreshGate()
  private(set) var cadence = TunnelObservationCadence.pollingFallback
  private var running = false

  init(
    interfaceReader: @escaping () -> [String] = TunnelInterfaces.current,
    monitor: (any TunnelNetworkChangeMonitoring)? = nil,
    debounceDuration: Duration = .milliseconds(350),
    emitter: @escaping (SystemEvent) -> Void = { SystemEventBus.shared.emit($0) }
  ) {
    self.interfaceReader = interfaceReader
    self.monitor = monitor ?? TunnelDynamicStoreMonitor()
    self.debounceDuration = debounceDuration
    self.emitter = emitter
  }

  func start() {
    guard !running else { return }
    running = true
    tracker.setBaseline(interfaceReader())
    cadence = .afterSubscription(started: startSubscription())

    Defaults.publisher(.energyMode)
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.restartRecoveryTimer() }
      .store(in: &cancellables)
    ContextRuleCenter.shared.$resolution
      .dropFirst()
      .sink { [weak self] _ in self?.restartRecoveryTimer() }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.restartRecoveryTimer() }
      .store(in: &cancellables)
    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.handleWake() }
      .store(in: &cancellables)
    restartRecoveryTimer()
  }

  func stop() {
    guard running else { return }
    running = false
    refreshTask?.cancel()
    refreshTask = nil
    refreshGate.reset()
    recoveryTimer = nil
    cancellables.removeAll()
    monitor.stop()
    cadence = .pollingFallback
    tracker.reset()
  }

  private func startSubscription() -> Bool {
    monitor.start { [weak self] in
      self?.handleNetworkChange()
    }
  }

  func handleNetworkChange() {
    guard running else { return }
    let token = refreshGate.signal()
    let debounceDuration = debounceDuration
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      do {
        try await Task.sleep(for: debounceDuration)
      } catch {
        return
      }
      guard let self, self.running, self.refreshGate.isCurrent(token) else { return }
      self.refreshTask = nil
      self.refreshInterfaces()
    }
  }

  func handleWake() {
    guard running else { return }
    refreshTask?.cancel()
    refreshTask = nil
    refreshGate.reset()
    refreshInterfaces()

    // Recreate the dispatch-queue registration after sleep. The dynamic store normally survives,
    // but rebuilding it here closes the one gap where a stale registration would leave only the
    // recovery timer reporting changes.
    monitor.stop()
    cadence = .afterSubscription(started: startSubscription())
    restartRecoveryTimer()
  }

  func handleRecoveryTick() {
    guard running else { return }
    reconcileAndRepairSubscription()
  }

  private func reconcileAndRepairSubscription() {
    refreshTask?.cancel()
    refreshTask = nil
    refreshGate.reset()
    refreshInterfaces()

    guard cadence == .pollingFallback, startSubscription() else { return }
    cadence = .subscribedRecovery
    restartRecoveryTimer()
  }

  private func restartRecoveryTimer() {
    let policy = EnergyPolicy(
      mode: ContextRuleCenter.shared.effectiveEnergyMode(baseline: Defaults[.energyMode]),
      systemLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    recoveryTimer = Timer.publish(
      every: cadence.interval(for: policy), on: .main, in: .common
    ).autoconnect().sink { [weak self] _ in self?.handleRecoveryTick() }
  }

  private func refreshInterfaces() {
    let change = tracker.update(interfaceReader())
    guard !change.isEmpty else { return }
    let up = !change.added.isEmpty
    emitter(
      SystemEvent(
        sourceID: id,
        icon: up ? "lock.shield.fill" : "lock.shield",
        title: up ? "Network tunnel up" : "Network tunnel down",
        subtitle: (up ? change.added : change.removed).first,
        accentHex: up ? EventAccent.info : EventAccent.neutral,
        motion: .vpn,
        urgency: .ambient,
        announcement: up ? "Network tunnel up" : "Network tunnel down"))
  }
}
