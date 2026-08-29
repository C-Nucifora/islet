import SwiftUI

/// Debug-menu activity for exercising compact/expanded rendering with no real source.
@MainActor
final class DemoActivity: NotchActivity, ObservableObject {
  let id = "demo"
  let priority = ActivityPriority.ambient
  @Published var isActive = false {
    didSet { activationDate = isActive ? Date() : nil }
  }
  private(set) var activationDate: Date?

  let tabIcon = "circle.dashed"
  var compactLeading: AnyView {
    AnyView(Circle().appThemeForeground(.interaction).frame(width: 16, height: 16))
  }

  var compactTrailing: AnyView {
    AnyView(Image(systemName: "waveform").appThemeForeground(.interaction).font(.caption))
  }

  var expandedView: AnyView {
    AnyView(Text("Demo activity").font(.title3).foregroundStyle(.white))
  }
}
