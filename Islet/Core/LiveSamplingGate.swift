import SwiftUI

/// Refcounted "is anyone watching?" gate.
///
/// A monitor that samples fast while its view is visible and slowly otherwise cannot use a Bool:
/// during a tab cross-fade SwiftUI runs the incoming view's `onAppear` before the outgoing view's
/// `onDisappear`, so the outgoing view switches sampling off with a subscriber still on screen and
/// the readout silently freezes. Counting observers fixes that.
@MainActor
final class LiveSamplingGate {
  private var count = 0
  private let onChange: (Bool) -> Void

  init(onChange: @escaping (Bool) -> Void) {
    self.onChange = onChange
  }

  var isLive: Bool { count > 0 }

  /// One more observer. 0 -> 1 announces `true`.
  func retain() {
    count += 1
    if count == 1 { onChange(true) }
  }

  /// One fewer observer. 1 -> 0 announces `false`. The count never goes below zero: SwiftUI does
  /// not promise a matching `onDisappear` for every `onAppear`, and a negative count would poison
  /// every later `retain()`.
  func release() {
    guard count > 0 else { return }
    count -= 1
    if count == 0 { onChange(false) }
  }
}

extension View {
  /// Retains `gate` for as long as this view is on screen.
  func liveSampling(_ gate: LiveSamplingGate) -> some View {
    onAppear { gate.retain() }
      .onDisappear { gate.release() }
  }
}
