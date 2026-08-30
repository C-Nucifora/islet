import SwiftUI

/// The expanded island: a switcher row above the selected content. Its width follows the live tab
/// count; overflow appears only when the available screen width cannot hold every activity.
struct ExpandedContainerView: View {
  /// The physical notch's size, so the switcher can flank it in the top band.
  let notchSize: CGSize
  /// Size tiers are reported to the view model, whose screen-clamped maximum width is observed.
  @ObservedObject var vm: NotchViewModel
  @ObservedObject private var center = ActivityCenter.shared
  @Environment(\.appTheme) private var appTheme
  private static let homeTab = ExpandedSelectionPolicy.homeID

  private var activities: [any NotchActivity] {
    center.expandedActivities(temporarilyIncluding: vm.temporarilyPresentedActivityID)
  }

  /// Tabs shown, left to right: Home, then active activities and persistent utility surfaces.
  private var tabs: [(id: String, icon: String)] {
    [(Self.homeTab, "square.grid.2x2.fill")]
      + activities.map { ($0.id, $0.tabIcon) }
  }

  /// Tabs that fit in the dynamically sized left ear. If the screen imposes a limit, the selected
  /// overflow tab replaces the last visible slot.
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
    return ExpandedSelectionPolicy.effectiveSelection(
      tabIDs: ids, storedSelection: vm.selectedActivityID,
      shelfPresentationActive: vm.isShelfDropTargeted,
      primaryActivityID: center.primaryActivity?.id)
  }

  /// The height tier the selected tab wants. Home uses the tall tier so three ranked rows and the
  /// overflow control remain clear of the physical notch.
  private var selectedHeight: CGFloat {
    guard effectiveSelection != Self.homeTab else { return Metrics.tallExpandedHeight }
    guard let activity = activities.first(where: { $0.id == effectiveSelection })
    else { return Metrics.expandedSize.height }
    return activity.preferredExpandedHeight
  }

  var body: some View {
    ZStack(alignment: .top) {
      // Declare the switcher before the selected content so native keyboard traversal follows the
      // same top-to-bottom order as the visible island.
      switcherBar
        .frame(height: notchSize.height)
        .padding(.horizontal, Self.rowPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity switcher")
        .accessibilitySortPriority(100)
      // Main content sits directly below the physical notch — reclaiming the space the switcher
      // row used to take.
      VStack(spacing: 0) {
        Spacer().frame(height: notchSize.height)
        content
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.horizontal, 14)
          .padding(.bottom, 12)
      }
    }
    .onChange(of: effectiveSelection, initial: true) { _, id in
      // Only the drawn island resizes; the panel already holds the tallest tier while expanded.
      // Making the panel follow this crashed the app — see NotchViewModel.targetPanelFrame.
      guard vm.state.isExpanded else { return }
      vm.setExpandedHeight(selectedHeight)
    }
    .onChange(of: vm.state.isExpanded) { _, isExpanded in
      if isExpanded { vm.setExpandedHeight(selectedHeight) }
    }
    .onChange(of: tabs.map(\.id), initial: true) { _, ids in
      vm.clearTemporaryPresentationIfUnavailable(
        availableActivityIDs: ids.filter { $0 != Self.homeTab })
      vm.setExpandedWidth(preferredExpandedWidth(tabCount: ids.count))
    }
  }

  private static let chipWidth = ActivityTabLayout.controlWidth
  private static let chipHeight: CGFloat = 20
  private static let rowSpacing = ActivityTabLayout.spacing
  private static let rowPadding = ActivityTabLayout.horizontalPadding

  /// Width the switcher gets from the same tab count that requests the island width. Reading the
  /// view model here creates a two-pass race on first presentation: the switcher can retain the
  /// collapsed-width capacity even after the island accepts the wider request.
  private var tabStripWidth: CGFloat {
    ActivityTabLayout.leftStripWidth(
      containerWidth: preferredExpandedWidth(tabCount: tabs.count),
      horizontalPadding: Self.rowPadding,
      notchWidth: notchSize.width, spacing: Self.rowSpacing, minimum: Self.chipWidth)
  }

  private func preferredExpandedWidth(tabCount: Int) -> CGFloat {
    ActivityTabLayout.preferredContainerWidth(
      tabCount: tabCount, notchWidth: notchSize.width,
      minimumWidth: Metrics.expandedSize.width, maximumWidth: vm.maximumExpandedWidth)
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
                vm.selectActivity(tab.id)
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
          .accessibilitySortPriority(90)
        }
      }
      .frame(width: tabStripWidth, alignment: .leading)
      // Gap for the physical notch, keeping tabs in the left ear and controls in the right ear.
      Spacer(minLength: notchSize.width)
      Button {
        QuickActionsOpener.open()
      } label: {
        Image(systemName: "bolt.fill")
          .font(.caption)
          .frame(width: Self.chipWidth, height: Self.chipHeight)
          .appThemeForeground(.interaction)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Quick Actions")
      .accessibilityHint("Opens the searchable action list")
      .accessibilitySortPriority(80)
      Button {
        SettingsOpener.open()
      } label: {
        Image(systemName: "gearshape.fill")
          .font(.caption)
          .frame(width: Self.chipWidth, height: Self.chipHeight)
          .appThemeForeground(.interaction)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Settings")
      .accessibilitySortPriority(70)
    }
  }

  private func tabButton(_ tab: (id: String, icon: String)) -> some View {
    let selected = tab.id == effectiveSelection
    return Button {
      vm.selectActivity(tab.id)
    } label: {
      Image(systemName: tab.icon)
        .font(.caption)
        .frame(width: Self.chipWidth, height: Self.chipHeight)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(selected ? appTheme.accentColor.opacity(0.24) : .white.opacity(0.06))
        )
        .overlay {
          RoundedRectangle(cornerRadius: 6)
            .stroke(selected ? Color.white.opacity(0.9) : .clear, lineWidth: 1)
        }
        .foregroundStyle(selected ? appTheme.accentColor : .secondary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(tab.id == Self.homeTab ? "Home" : ActivityCatalog.name(for: tab.id))
    .accessibilityValue(selected ? "Selected" : "Not selected")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  @ViewBuilder private var content: some View {
    Group {
      if effectiveSelection == Self.homeTab {
        IdleDashboardView(vm: vm) { vm.selectActivity($0) }
      } else if let activity = activities.first(where: {
        $0.id == effectiveSelection
      }) {
        activity.expandedView
          .environment(\.shelfDropTargeted, vm.isShelfDropTargeted)
      } else {
        IdleDashboardView(vm: vm) { vm.selectActivity($0) }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      effectiveSelection == Self.homeTab
        ? "Home" : "\(ActivityCatalog.name(for: effectiveSelection)) activity"
    )
    .accessibilitySortPriority(10)
  }
}
