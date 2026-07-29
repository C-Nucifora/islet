import Combine
import Foundation

/// Which tunnel interfaces exist right now.
///
/// Split from the source so the classifier is a pure, tested function — it is the only part that can
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

/// Network tunnels coming up and going down.
///
/// **Heuristic, and the event text says so.** A `utun` interface is not proof of a VPN: iCloud
/// Private Relay, Handoff, AirPlay and Continuity all create them. The event reads "Network tunnel
/// up", never "VPN connected", because Islet genuinely cannot tell the difference.
///
/// There is no notification for interface changes that does not involve SystemConfiguration
/// dynamic-store plumbing, so this polls. `getifaddrs` measured at 0.024 ms; at 5s that is free.
@MainActor
final class VPNEventSource: SystemEventSource {
  let id = "vpn"
  let displayName = "Network tunnel"
  let tier = SystemEventTier.heuristic

  private var timer: AnyCancellable?
  private var known: [String] = []

  func start() {
    guard timer == nil else { return }
    known = TunnelInterfaces.current()  // baseline: a tunnel already up is not news
    timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in self?.check() }
  }

  func stop() {
    timer = nil
    known = []
  }

  private func check() {
    let now = TunnelInterfaces.current()
    let diff = SetDiff.changes(from: known, to: now)
    known = now
    guard !diff.added.isEmpty || !diff.removed.isEmpty else { return }
    let up = !diff.added.isEmpty
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id,
        icon: up ? "lock.shield.fill" : "lock.shield",
        title: up ? "Network tunnel up" : "Network tunnel down",
        subtitle: (up ? diff.added : diff.removed).first,
        accentHex: up ? EventAccent.info : EventAccent.neutral,
        motion: .vpn,
        urgency: .ambient,
        announcement: up ? "Network tunnel up" : "Network tunnel down"))
  }
}
