import Foundation

enum NotchState: Equatable {
  case closed
  case peek
  case expanded(pinned: Bool)

  var isExpanded: Bool { if case .expanded = self { true } else { false } }
}

enum NotchEvent: Equatable {
  case hoverEntered, hoverExited, pushThresholdCrossed
  case collapseTimeoutElapsed
  case clickedNotch, clickedInsideExpanded, clickedOutside
}

enum InteractionMode: String, CaseIterable, Codable {
  case hover, clickToPin
}

enum NotchStateMachine {
  static func transition(
    from state: NotchState, on event: NotchEvent,
    mode: InteractionMode, preventAutoClose: Bool = false
  ) -> NotchState {
    switch (state, event) {
    case (.closed, .hoverEntered): return .peek
    case (.peek, .hoverExited): return .closed
    case (.peek, .pushThresholdCrossed):
      return mode == .hover ? .expanded(pinned: false) : .peek
    case (.closed, .clickedNotch), (.peek, .clickedNotch):
      return .expanded(pinned: true)
    case (.expanded, .clickedNotch):
      return .closed
    case (.expanded(false), .collapseTimeoutElapsed):
      return preventAutoClose ? state : .closed
    case (.expanded(false), .clickedInsideExpanded):
      return .expanded(pinned: true)
    case (.expanded, .clickedOutside):
      return preventAutoClose ? state : .closed
    default:
      return state
    }
  }
}
