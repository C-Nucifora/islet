import AppKit
import Combine

/// Disks and volumes mounting and unmounting.
///
/// `NSWorkspace` posts both, with the volume URL in the userInfo — no polling, no permission.
@MainActor
final class VolumeEventSource: SystemEventSource {
  let id = "volume"
  let displayName = String(localized: "Disks and volumes")
  let tier = SystemEventTier.core

  private var cancellables: Set<AnyCancellable> = []

  func start() {
    guard cancellables.isEmpty else { return }
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.didMountNotification)
      .sink { [weak self] note in self?.report(note, mounted: true) }
      .store(in: &cancellables)
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.didUnmountNotification)
      .sink { [weak self] note in self?.report(note, mounted: false) }
      .store(in: &cancellables)
  }

  func stop() { cancellables.removeAll() }

  private func report(_ note: Notification, mounted: Bool) {
    let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
    let name =
      url.map { FileManager.default.displayName(atPath: $0.path) } ?? String(localized: "Volume")
    SystemEventBus.shared.emit(
      SystemEvent(
        sourceID: id,
        icon: mounted ? "externaldrive.fill.badge.plus" : "externaldrive.fill.badge.minus",
        title: name,
        subtitle: mounted ? String(localized: "Mounted") : String(localized: "Ejected"),
        accentHex: mounted ? EventAccent.info : EventAccent.neutral,
        motion: .volumeMount,
        urgency: mounted ? .normal : .ambient,
        announcement: mounted
          ? String(localized: "\(name) mounted") : String(localized: "\(name) ejected")))
  }
}
