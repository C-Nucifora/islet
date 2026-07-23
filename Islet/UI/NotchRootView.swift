import SwiftUI

struct NotchRootView: View {
  @ObservedObject var vm: NotchViewModel
  @ObservedObject private var center = ActivityCenter.shared
  @ObservedObject private var sneaks = SneakQueue.shared
  @ObservedObject private var hud = HUDController.shared
  @ObservedObject private var reminders = RemindersProvider.shared
  @State private var compactLeadingWidth: CGFloat = 0
  @State private var compactTrailingWidth: CGFloat = 0

  /// Compact content precedence: HUD > in-flight sneak > primary activity > idle dashboard hint.
  private var compactContent: (leading: AnyView, trailing: AnyView)? {
    if !vm.state.isExpanded, let snapshot = hud.hud {
      return (AnyView(HUDIconView(snapshot: snapshot)), AnyView(HUDBarView(snapshot: snapshot)))
    }
    if !vm.state.isExpanded, let sneak = sneaks.current {
      return (sneak.leading, sneak.trailing)
    }
    if let primary = center.primaryActivity {
      // Combine statuses: primary in the flanks, other active activities as small trailing glyphs
      // (e.g. music playing shows the charging bolt alongside it).
      let secondary = Array(center.activeActivities.dropFirst())
      let trailing = AnyView(
        HStack(spacing: 5) {
          primary.compactTrailing
          ForEach(secondary, id: \.id) { activity in
            activity.compactLeading
          }
        })
      return (primary.compactLeading, trailing)
    }
    if !vm.state.isExpanded, !reminders.reminders.isEmpty {
      // Idle affordance: a small checklist badge so pending reminders are visible at a glance.
      return (
        AnyView(Image(systemName: "checklist").foregroundStyle(.orange).font(.caption2)),
        AnyView(
          Text("\(reminders.reminders.count)")
            .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.orange))
      )
    }
    return nil
  }

  private var radii: (top: CGFloat, bottom: CGFloat) {
    vm.state.isExpanded ? Metrics.expandedRadii : Metrics.closedRadii
  }

  private var compactVisible: Bool {
    !vm.state.isExpanded && compactContent != nil
  }

  /// Size of the black shape body, EXCLUDING the top-flare ears.
  private var bodySize: CGSize {
    let notch = vm.geometry.notchSize
    let compactExtra = compactVisible ? compactLeadingWidth + compactTrailingWidth : 0
    switch vm.state {
    case .closed:
      return CGSize(
        width: notch.width + Metrics.closedOversize * 2 + compactExtra,
        height: notch.height + Metrics.closedOversize)
    case .peek:
      return CGSize(
        width: notch.width + Metrics.closedOversize * 2 + compactExtra,
        height: notch.height + Metrics.peekGrowth)
    case .expanded:
      return Metrics.expandedSize
    }
  }

  var body: some View {
    ZStack(alignment: .top) {
      content
        .frame(width: bodySize.width, height: bodySize.height, alignment: .top)
        .background { Rectangle().fill(.black).padding(-50) }
        .mask {
          NotchShape(topRadius: radii.top, bottomRadius: radii.bottom)
            .frame(
              width: bodySize.width + radii.top * 2,
              height: bodySize.height
            )
            .padding(.horizontal, -0.5)
        }
        .shadow(color: .black.opacity(vm.state.isExpanded ? 0.8 : 0), radius: 16)
        .offset(x: compactVisible ? (compactTrailingWidth - compactLeadingWidth) / 2 : 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .animation(vm.state.isExpanded ? Metrics.opening : Metrics.closing, value: vm.state)
    .animation(Metrics.compact, value: compactVisible)
    .preferredColorScheme(.dark)
    .allowsHitTesting(vm.state.isExpanded)
  }

  @ViewBuilder private var content: some View {
    if vm.state.isExpanded {
      VStack(spacing: 0) {
        Spacer().frame(height: vm.geometry.notchSize.height)
        // The switcher exposes every active status plus the calendar/reminders dashboard
        // and a settings gear, so all of it is reachable from one expanded view.
        ExpandedContainerView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.horizontal, 14)
          .padding(.bottom, 12)
      }
      .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .top)))
    } else if let slots = compactContent {
      HStack(spacing: 0) {
        slots.leading
          .padding(.leading, 6)
          .onGeometryChange(for: CGFloat.self, of: \.size.width) {
            compactLeadingWidth = $0 + 6
          }
        Spacer().frame(width: vm.geometry.notchSize.width)
        slots.trailing
          .padding(.trailing, 6)
          .onGeometryChange(for: CGFloat.self, of: \.size.width) {
            compactTrailingWidth = $0 + 6
          }
      }
      .frame(height: vm.geometry.notchSize.height)
      .id(hud.hud == nil ? sneaks.current?.id.uuidString : "hud")
      .transition(.opacity)
    } else {
      Color.clear
    }
  }
}
