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
  private var drainGeneration: UInt = 0

  func submit(_ sneak: Sneak) {
    logic.enqueue(sneak)
    drainIfNeeded()
  }

  @discardableResult
  func dismissCurrent() -> Bool {
    guard current != nil else { return false }
    drainTask?.cancel()
    drainGeneration &+= 1
    drainTask = nil
    withAnimation(Motion.gated(Motion.compact)) { current = nil }
    drainIfNeeded()
    return true
  }

  private func drainIfNeeded() {
    guard drainTask == nil else { return }
    let generation = drainGeneration
    drainTask = Task { [weak self] in
      await self?.drain(generation: generation)
      guard self?.drainGeneration == generation else { return }
      self?.drainTask = nil
    }
  }

  private func drain(generation: UInt) async {
    while true {
      while isSuspended() {
        do {
          try await Task.sleep(for: .milliseconds(200))
        } catch { return }
        guard !Task.isCancelled, generation == drainGeneration else { return }
      }
      guard let next = logic.popNext() else { return }
      withAnimation(Motion.gated(Motion.compact)) { current = next }
      if let announcement = next.announcement { A11y.announce(announcement) }
      do {
        try await Task.sleep(for: .seconds(next.duration))
      } catch { return }
      guard !Task.isCancelled, generation == drainGeneration else { return }
      withAnimation(Motion.gated(Motion.compact)) { current = nil }
      do {
        try await Task.sleep(for: .milliseconds(250))
      } catch { return }
      guard !Task.isCancelled, generation == drainGeneration else { return }
    }
  }
}
