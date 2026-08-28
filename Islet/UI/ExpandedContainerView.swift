import SwiftUI

/// The expanded island: a bounded switcher row above the selected content. Home and at most three
/// priority activities stay visible; everything else is available from an explicit overflow menu.
struct ExpandedContainerView: View {
  /// The physical notch's size, so the switcher can flank it in the top band.
  let notchSize: CGSize
  /// Height tiers are reported up to the view model, which owns the panel frame.
  let vm: NotchViewModel
  @ObservedObject private var center = ActivityCenter.shared
  @ObservedObject private var shelf = ShelfModel.shared
  /// nil selection means the dashboard ("Home"); otherwise an activity id.
  @State private var selection: String? = nil
  private static let homeTab = "\u{0000}home"  // sentinel id for the dashboard chip

  /// Tabs shown, left to right: Home, then each active activity.
  private var tabs: [(id: String, icon: String)] {
    [(Self.homeTab, "square.grid.2x2.fill")]
      + center.activeActivities.map { ($0.id, $0.tabIcon) }
  }

  /// The left ear has a hard physical width. Keep Home plus three activities at most, replacing
  /// the last priority slot with the current selection when it came from overflow.
  private var visibleTabs: [(id: String, icon: String)] {
    tabLayout.visibleIDs.compactMap { id in tabs.first { $0.id == id } }
  }

  private var overflowTabs: [(id: String, icon: String)] {
    tabLayout.overflowIDs.compactMap { id in tabs.first { $0.id == id } }
  }

  private var tabLayout: ActivityTabLayout.Result {
    ActivityTabLayout.split(
      tabIDs: tabs.map(\.id), selectedID: effectiveSelection,
      controlCapacity: ActivityTabLayout.controlCapacity(
        width: tabStripWidth, controlWidth: Self.chipWidth, spacing: Self.rowSpacing))
  }

  /// The effective selection: the stored one if still valid, else a sensible default
  /// (the media player when playing, otherwise the dashboard).
  private var effectiveSelection: String {
    let ids = tabs.map(\.id)
    // A file drag jumps straight to the shelf so you can drop onto it.
    if shelf.isDragActive, ids.contains("shelf") { return "shelf" }
    if let selection, ids.contains(selection) { return selection }
    // Default to a prominent active activity (running timer or media player); else the dashboard.
    if let primary = center.primaryActivity, primary.id == "timer" || primary.id == "nowPlaying" {
      return primary.id
    }
    return Self.homeTab
  }

  /// The height tier the selected tab wants. The dashboard always takes the base tier.
  private var selectedHeight: CGFloat {
    guard effectiveSelection != Self.homeTab,
      let activity = center.activeActivities.first(where: { $0.id == effectiveSelection })
    else { return Metrics.expandedSize.height }
    return activity.preferredExpandedHeight
  }

  var body: some View {
    ZStack(alignment: .top) {
      // Main content sits directly below the physical notch — reclaiming the space the switcher
      // row used to take.
      VStack(spacing: 0) {
        Spacer().frame(height: notchSize.height)
        content
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.horizontal, 14)
          .padding(.bottom, 12)
      }
      // Switcher tabs (left ear) and settings gear (right ear) live in the notch band, flanking
      // the hardware notch.
      switcherBar
        .frame(height: notchSize.height)
        .padding(.horizontal, Self.rowPadding)
    }
    .onChange(of: effectiveSelection, initial: true) { _, id in
      // Only the drawn island resizes; the panel already holds the tallest tier while expanded.
      // Making the panel follow this crashed the app — see NotchViewModel.targetPanelFrame.
      vm.setExpandedHeight(selectedHeight)
    }
  }

  private static let chipWidth: CGFloat = 20
  private static let chipHeight: CGFloat = 20
  private static let rowSpacing: CGFloat = 4
  private static let rowPadding: CGFloat = 12

  /// Width the bounded switcher gets in the left ear. Five compact controls (Home, three tabs and
  /// overflow) require 116pt, fitting the 126pt reference ear without crossing the physical notch.
  private var tabStripWidth: CGFloat {
    ActivityTabLayout.leftStripWidth(
      containerWidth: Metrics.expandedSize.width, horizontalPadding: Self.rowPadding,
      notchWidth: notchSize.width, spacing: Self.rowSpacing, minimum: Self.chipWidth)
  }

  private var switcherBar: some View {
    HStack(spacing: Self.rowSpacing) {
      HStack(spacing: Self.rowSpacing) {
        ForEach(visibleTabs, id: \.id) { tab in
          tabButton(tab)
        }
        if !overflowTabs.isEmpty {
          Menu {
            ForEach(overflowTabs, id: \.id) { tab in
              Button {
                Haptics.perform(.alignment)
                selection = tab.id
              } label: {
                Label(ActivityCatalog.name(for: tab.id), systemImage: tab.icon)
              }
            }
          } label: {
            Image(systemName: "ellipsis")
              .font(.caption.weight(.semibold))
              .frame(width: Self.chipWidth, height: Self.chipHeight)
              .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
              .foregroundStyle(.secondary)
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .accessibilityLabel("More activities")
          .accessibilityHint("Shows \(overflowTabs.count) additional activities")
        }
      }
      .frame(width: tabStripWidth, alignment: .leading)
      // Gap for the physical notch, keeping tabs in the left ear and the gear in the right ear.
      Spacer(minLength: notchSize.width)
      Button {
        Haptics.perform()
        SettingsOpener.open()
      } label: {
        Image(systemName: "gearshape.fill")
          .font(.caption)
          .frame(width: Self.chipWidth, height: Self.chipHeight)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Settings")
    }
  }

  private func tabButton(_ tab: (id: String, icon: String)) -> some View {
    let selected = tab.id == effectiveSelection
    return Button {
      Haptics.perform(.alignment)
      selection = tab.id
    } label: {
      Image(systemName: tab.icon)
        .font(.caption)
        .frame(width: Self.chipWidth, height: Self.chipHeight)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(.white.opacity(selected ? 0.22 : 0.06))
        )
        .foregroundStyle(selected ? .white : .secondary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(tab.id == Self.homeTab ? "Home" : ActivityCatalog.name(for: tab.id))
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  @ViewBuilder private var content: some View {
    if effectiveSelection == Self.homeTab {
      IdleDashboardView()
    } else if let activity = center.activeActivities.first(where: {
      $0.id == effectiveSelection
    }) {
      activity.expandedView
    } else {
      IdleDashboardView()
    }
  }
}
