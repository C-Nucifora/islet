import SwiftUI

/// Owns sneak timing: presents queued sneaks one at a time in the compact island,
/// never while the island is expanded (holds and drains after close).
///
/// Queue scheduling only chooses the next sneak. A newly queued alert does not interrupt `current`;
/// it presents after the current sneak's normal dwell and transition complete.
@MainActor
final class SneakQueue: ObservableObject {
  static let shared = SneakQueue()

  @Published private(set) var current: Sneak?
  /// Wired by the app to `viewModel.state.isExpanded`.
  var isSuspended: () -> Bool = { false }

  private var logic = SneakLogic()
  private var drainTask: Task<Void, Never>?

  func submit(_ sneak: Sneak) {
    logic.enqueue(sneak)
    drainIfNeeded()
  }

  private func drainIfNeeded() {
    guard drainTask == nil else { return }
    drainTask = Task { [weak self] in
      await self?.drain()
      self?.drainTask = nil
    }
  }

  private func drain() async {
    while true {
      while isSuspended() {
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
      }
      guard let next = logic.popNext() else { return }
      withAnimation(Motion.gated(Motion.compact)) { current = next }
      if let announcement = next.announcement { A11y.announce(announcement) }
      try? await Task.sleep(for: .seconds(next.duration))
      withAnimation(Motion.gated(Motion.compact)) { current = nil }
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
    }
  }
}
