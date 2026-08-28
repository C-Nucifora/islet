import Combine
import Defaults
import SwiftUI

/// Shows what's plugged in: a device count in the compact island and a per-device list (name,
/// vendor, speed, port) when expanded.
@MainActor
final class PortsActivity: NotchActivity, ObservableObject {
  let id = "ports"
  let priority = ActivityPriority.ambient
  let tabIcon = "cable.connector"
  private(set) var activationDate: Date?

  private let monitor = PortMonitor.shared
  private var cancellables: Set<AnyCancellable> = []
  private var isMonitoring = false

  var isActive: Bool { Defaults[.portsEnabled] && !monitor.devices.isEmpty }

  func start() {
    guard !isMonitoring else { return }
    isMonitoring = true
    monitor.start(owner: id)
    monitor.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        if self.isActive, self.activationDate == nil { self.activationDate = Date() }
        if !self.isActive { self.activationDate = nil }
        self.objectWillChange.send()
      }
      .store(in: &cancellables)
  }

  func stop() {
    guard isMonitoring else { return }
    isMonitoring = false
    cancellables.removeAll()
    monitor.stop(owner: id)
    activationDate = nil
    objectWillChange.send()
  }

  var compactLeading: AnyView {
    AnyView(Image(systemName: "cable.connector").foregroundStyle(.cyan).font(.caption2))
  }
  var compactTrailing: AnyView {
    AnyView(
      Text("\(monitor.devices.count)")
        .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.cyan))
  }
  var expandedView: AnyView { AnyView(PortsView(monitor: monitor)) }
}

struct PortsView: View {
  @ObservedObject var monitor: PortMonitor

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("Connected — \(monitor.devices.count)", systemImage: "cable.connector")
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      if monitor.devices.isEmpty {
        Text("No USB devices").font(.caption).foregroundStyle(.secondary)
      } else {
        ScrollView(.vertical, showsIndicators: false) {
          VStack(spacing: 4) {
            ForEach(monitor.devices) { device in
              HStack(spacing: 8) {
                Image(systemName: "cable.connector.horizontal")
                  .font(.caption2).foregroundStyle(.cyan).frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                  Text(device.name).font(.caption).lineLimit(1)
                  if let vendor = device.vendor {
                    Text(vendor).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                  }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                  if let speed = device.speed {
                    Text(speed).font(.caption2.weight(.semibold)).monospacedDigit()
                  }
                  Text(device.portLabel).font(.system(size: 9)).foregroundStyle(.secondary)
                }
              }
              .padding(.vertical, 3).padding(.horizontal, 6)
              .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
            }
          }
        }
      }
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
