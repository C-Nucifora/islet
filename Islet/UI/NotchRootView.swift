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

  private var compactChangeAnimation: Animation {
    Motion.compactChange(hudVisible: hud.hud != nil)
  }

  /// Slot widths as layout should use them: zero whenever no compact content is drawn, so neither
  /// the offset nor the body size can carry a stale measurement from a slot that isn't on screen.
  private var effectiveCompact: (leading: CGFloat, trailing: CGFloat) {
    compactVisible ? (compactLeadingWidth, compactTrailingWidth) : (0, 0)
  }

  /// Horizontal offset that lines the island's notch cut-out up with the hardware notch.
  ///
  /// `vm.actualPanelFrame` — the frame the window really has — NOT `vm.panelFrame`, the frame we
  /// asked for. The island is drawn centred in the real window, so aligning it against the request
  /// maps any divergence 1:1 onto a horizontal shift that no hover ever clears: `targetPanelFrame`
  /// returns the same value for `.closed` and `.peek`, so hovering republishes nothing.
  private var islandOffset: CGFloat {
    vm.geometry.islandOffset(
      inPanel: vm.actualPanelFrame,
      compactLeading: effectiveCompact.leading,
      compactTrailing: effectiveCompact.trailing)
  }

  /// Size of the black shape body, EXCLUDING the top-flare ears.
  private var bodySize: CGSize {
    let notch = vm.geometry.notchSize
    let width = vm.geometry.islandBodyWidth(
      compactLeading: effectiveCompact.leading, compactTrailing: effectiveCompact.trailing)
    switch vm.state {
    case .closed:
      return CGSize(width: width, height: notch.height + Metrics.closedOversize)
    case .peek:
      return CGSize(
        width: width,
        height: notch.height + Metrics.peekGrowth + Metrics.barrierStretch * vm.barrierProgress)
    case .expanded:
      return CGSize(width: vm.expandedWidth, height: vm.expandedHeight)
    }
  }

  var body: some View {
    ZStack(alignment: .top) {
      content
        // Compact content is left unconstrained horizontally. Constraining it to `bodySize.width`
        // — which is itself derived from the slots' measured widths — makes each measurement the
        // next layout pass's proposal, so flexible content (a sneak's track title) creeps out to
        // its real width a few points per frame, resizing the panel the whole way. The black
        // shape is sized from the measurement regardless: that's the mask, below.
        .frame(
          width: compactVisible ? nil : bodySize.width, height: bodySize.height, alignment: .top
        )
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
        .offset(x: islandOffset)
        // Only the expanded island is interactive via SwiftUI; collapsed clicks pass through
        // to windows beneath (hover/click detection is monitor-driven).
        .allowsHitTesting(vm.state.isExpanded)

    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .animation(
      Motion.gated(vm.state.isExpanded ? Motion.opening : Motion.closing), value: vm.state
    )
    .animation(Motion.gated(compactChangeAnimation), value: slotIdentity)
    .animation(Motion.gated(compactChangeAnimation), value: compactVisible)
    .animation(Motion.gated(compactChangeAnimation), value: compactLeadingWidth)
    .animation(Motion.gated(compactChangeAnimation), value: compactTrailingWidth)
    // The panel is only as wide as the island, so it has to know how wide the slots rendered.
    .onChange(of: compactLeadingWidth, initial: true) { _, _ in syncPanelWidths() }
    .onChange(of: compactTrailingWidth) { _, _ in syncPanelWidths() }
    .onChange(of: compactVisible) { _, _ in syncPanelWidths() }
    .preferredColorScheme(.dark)
  }

  private func syncPanelWidths() {
    vm.updateCompactWidths(
      leading: effectiveCompact.leading, trailing: effectiveCompact.trailing)
  }

  /// Identity of the compact slot subtree. The HUD and each sneak get their own, so SwiftUI
  /// cross-fades between them instead of mutating one subtree in place.
  private var slotIdentity: String {
    if hud.hud != nil { return "hud" }
    if let sneak = sneaks.current { return "sneak-\(sneak.id.uuidString)" }
    let activityIDs = center.activeActivities.map(\.id)
    if !activityIDs.isEmpty { return "activities-\(activityIDs.joined(separator: "|"))" }
    if !reminders.reminders.isEmpty { return "reminders-\(reminders.reminders.count)" }
    return "idle"
  }

  /// Accepts a slot measurement only from the subtree that is currently on screen.
  ///
  /// Both `onGeometryChange` closures live under `.id(slotIdentity)`. During a cross-fade the
  /// outgoing subtree is still alive and still reporting, and if it reports LAST its stale width
  /// wins — stranding a measurement for content that is no longer drawn and sizing the panel to it.
  /// Each closure captures the identity it was built with; `slotIdentity` here reads the live
  /// observed objects, so an outgoing subtree's write no longer matches and is dropped.
  private func applySlotWidth(_ width: CGFloat, leading: Bool, from identity: String) {
    guard identity == slotIdentity else { return }
    if leading {
      compactLeadingWidth = width
    } else {
      compactTrailingWidth = width
    }
  }

  @ViewBuilder private var content: some View {
    if vm.state.isExpanded {
      ZStack {
        // The switcher (tabs + gear) sits in the notch band, flanking the hardware notch, and the
        // content fills the rest — so nothing is wasted below the notch.
        ExpandedContainerView(notchSize: vm.geometry.notchSize, vm: vm)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Media keys can arrive while the island is open. Keep their feedback above expanded
        // content so replacing the system OSD never produces an invisible change.
        if let snapshot = hud.hud {
          ExpandedHUDOverlay(snapshot: snapshot)
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
            .zIndex(2)
        }
      }
      .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .top)))
    } else if let slots = compactContent {
      let identity = slotIdentity
      HStack(spacing: 0) {
        // The measured width already includes the padding — don't add it a second time, or the
        // shape (and the panel sized from it) gains 12pt of dead space per flank.
        slots.leading
          .padding(.leading, 6)
          .onGeometryChange(for: CGFloat.self, of: \.size.width) {
            applySlotWidth($0, leading: true, from: identity)
          }
        Spacer().frame(width: vm.geometry.notchSize.width)
        slots.trailing
          .padding(.trailing, 6)
          .onGeometryChange(for: CGFloat.self, of: \.size.width) {
            applySlotWidth($0, leading: false, from: identity)
          }
      }
      .frame(height: vm.geometry.notchSize.height)
      .id(identity)
      .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    } else {
      Color.clear
    }
  }
}

private struct ExpandedHUDOverlay: View {
  let snapshot: HUDSnapshot

  var body: some View {
    HStack(spacing: 10) {
      HUDIconView(snapshot: snapshot)
      HUDBarView(snapshot: snapshot)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
    .background(.black.opacity(0.88), in: Capsule())
    .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
    .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(snapshot.kind == .volume ? "Volume" : "Brightness")
    .accessibilityValue("\(Int((snapshot.level * 100).rounded())) percent")
  }
}
