import Defaults
import SwiftUI

@MainActor
enum NotchHosting {
  static func view(for viewModel: NotchViewModel) -> NotchHostingContainer {
    NotchHostingContainer(viewModel: viewModel)
  }
}

/// Clips one fixed-size SwiftUI renderer to the adaptive NSPanel frame. AppKit may resize this
/// container, but it never changes the hosting view's proposed size. This separation avoids the
/// `_postWindowNeedsUpdateConstraints` exception caused by resizing NSHostingView itself.
@MainActor
final class NotchHostingContainer: NSView {
  let hostingView: NSHostingView<NotchRootView>
  private let renderingFrame: CGRect

  init(viewModel: NotchViewModel) {
    hostingView = NSHostingView(rootView: NotchRootView(vm: viewModel))
    renderingFrame = viewModel.renderingFrame
    super.init(frame: CGRect(origin: .zero, size: viewModel.panelFrame.size))
    wantsLayer = true
    layer?.masksToBounds = true
    hostingView.sizingOptions = []
    hostingView.autoresizingMask = []
    addSubview(hostingView)
    alignRenderer(toWindowFrame: viewModel.panelFrame)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func alignRenderer(toWindowFrame windowFrame: CGRect) {
    hostingView.frame = CGRect(
      x: renderingFrame.minX - windowFrame.minX,
      y: renderingFrame.minY - windowFrame.minY,
      width: renderingFrame.width,
      height: renderingFrame.height)
  }
}

struct CompactHUDSlot: View {
  let alignment: Alignment
  let underlying: AnyView
  let hud: AnyView

  var body: some View {
    ZStack(alignment: alignment) {
      underlying.opacity(0).accessibilityHidden(true)
      hud
    }
  }
}

struct NotchRootView: View {
  @ObservedObject var vm: NotchViewModel
  @ObservedObject private var center = ActivityCenter.shared
  @ObservedObject private var sneaks = SneakQueue.shared
  @ObservedObject private var hud = HUDController.shared
  @ObservedObject private var reminders = RemindersProvider.shared
  @ObservedObject private var keepAwake = KeepAwakeManager.shared
  @Default(.appTheme) private var appTheme
  @Default(.batteryGraphStyle) private var batteryGraphStyle
  @State private var compactLeadingWidth: CGFloat = 0
  @State private var compactTrailingWidth: CGFloat = 0

  /// Content that should return after a temporary HUD leaves.
  private var underlyingCompactContent: (leading: AnyView, trailing: AnyView)? {
    if let sneak = sneaks.current {
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
          if keepAwake.isActive || keepAwake.hasUnreleasedAssertions {
            KeepAwakeCompactIcon(releasePending: !keepAwake.isActive)
          }
        })
      return (primary.compactLeading, trailing)
    }
    if keepAwake.isActive || keepAwake.hasUnreleasedAssertions {
      return (
        AnyView(KeepAwakeCompactIcon(releasePending: !keepAwake.isActive)),
        AnyView(
          Text(keepAwake.isActive ? keepAwake.statusText : "Release pending")
            .font(.caption.weight(.semibold)).monospacedDigit()
            .foregroundStyle(keepAwake.isActive ? Color.secondary : Color.orange)
            .accessibilityLabel(
              keepAwake.isActive
                ? "Keep awake, \(keepAwake.statusText) remaining"
                : "Keep-awake assertion release pending"))
      )
    }
    if !reminders.reminders.isEmpty {
      // Idle affordance: a small checklist badge so pending reminders are visible at a glance.
      return (
        AnyView(Image(systemName: "checklist").appThemeForeground(.reminders).font(.caption2)),
        AnyView(
          Text("\(reminders.reminders.count)")
            .font(.caption.weight(.semibold)).monospacedDigit()
            .appThemeForeground(.reminders))
      )
    }
    return nil
  }

  /// Compact content precedence: HUD > in-flight sneak > primary activity > idle dashboard hint.
  ///
  /// A HUD is temporary, so keep its underlying content in the layout at zero opacity. The slots
  /// then take the larger of the HUD and underlying widths. Pressing a media key cannot collapse
  /// an active activity's island only to grow it again when the HUD leaves.
  private var compactContent: (leading: AnyView, trailing: AnyView)? {
    guard let snapshot = hud.hud else { return underlyingCompactContent }
    guard let underlying = underlyingCompactContent else {
      return (AnyView(HUDIconView(snapshot: snapshot)), AnyView(HUDBarView(snapshot: snapshot)))
    }
    return (
      AnyView(
        CompactHUDSlot(
          alignment: .leading,
          underlying: underlying.leading,
          hud: AnyView(HUDIconView(snapshot: snapshot)))),
      AnyView(
        CompactHUDSlot(
          alignment: .trailing,
          underlying: underlying.trailing,
          hud: AnyView(HUDBarView(snapshot: snapshot))))
    )
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
  /// This positions the shape inside the real host frame while accounting for asymmetric compact
  /// slots and any temporary oversized frame held during a closing animation.
  private var islandOffset: CGFloat {
    vm.geometry.islandOffset(
      inPanel: vm.renderingFrame,
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

  private var shapeWidth: CGFloat {
    bodySize.width + radii.top * 2
  }

  private var islandShape: NotchShape {
    NotchShape(topRadius: radii.top, bottomRadius: radii.bottom)
  }

  var body: some View {
    ZStack(alignment: .top) {
      // Keep the black island alive across every state. Expanded and compact content cross-fade
      // inside this one animating shape instead of each state removing its own black backdrop.
      islandShape
        .fill(.black)
        .frame(width: shapeWidth, height: bodySize.height)
        .padding(.horizontal, -0.5)
        .shadow(color: .black.opacity(vm.state.isExpanded ? 0.8 : 0), radius: 16)

      content
        .mask {
          islandShape
            .frame(width: shapeWidth, height: bodySize.height)
            .padding(.horizontal, -0.5)
        }
    }
    .offset(x: islandOffset)
    // Only the expanded island is interactive via SwiftUI; collapsed clicks pass through to
    // windows beneath (hover/click detection is monitor-driven).
    .allowsHitTesting(vm.state.isExpanded)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .animation(
      Motion.gated(vm.state.isExpanded ? Motion.opening : Motion.closing), value: vm.state
    )
    .animation(Motion.gated(compactChangeAnimation), value: slotIdentity)
    .animation(Motion.gated(compactChangeAnimation), value: compactVisible)
    .animation(Motion.gated(compactChangeAnimation), value: compactLeadingWidth)
    .animation(Motion.gated(compactChangeAnimation), value: compactTrailingWidth)
    // The panel follows these widths, while the shape also animates the same change.
    .onChange(of: compactLeadingWidth, initial: true) { _, _ in syncPanelWidths() }
    .onChange(of: compactTrailingWidth) { _, _ in syncPanelWidths() }
    .onChange(of: compactVisible) { _, _ in syncPanelWidths() }
    .tint(appTheme.accentColor)
    .environment(\.appTheme, appTheme)
    .environment(\.batteryGraphStyle, batteryGraphStyle)
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
    if keepAwake.isActive { return "keep-awake" }
    if keepAwake.hasUnreleasedAssertions { return "keep-awake-release-pending" }
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

  private var content: some View {
    ZStack(alignment: .top) {
      compactLayer
        .opacity(vm.state.isExpanded ? 0 : 1)
        .zIndex(vm.state.isExpanded ? 0 : 1)

      if vm.state.isExpanded {
        expandedLayer
          .transition(.opacity)
          .zIndex(1)
      }
    }
  }

  private var expandedLayer: some View {
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
    .frame(width: vm.expandedWidth, height: vm.expandedHeight)
  }

  @ViewBuilder private var compactLayer: some View {
    if let slots = compactContent {
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
      .transition(.opacity)
    } else {
      Color.clear.frame(width: vm.geometry.notchSize.width, height: vm.geometry.notchSize.height)
    }
  }
}

private struct KeepAwakeCompactIcon: View {
  @Environment(\.appTheme) private var appTheme
  let releasePending: Bool

  var body: some View {
    Image(systemName: releasePending ? "exclamationmark.triangle.fill" : "cup.and.heat.waves.fill")
      .font(.caption2)
      .foregroundStyle(releasePending ? Color.orange : appTheme.color(for: .interaction))
      .accessibilityLabel(
        releasePending ? "Keep-awake assertion release pending" : "Keep awake active")
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
