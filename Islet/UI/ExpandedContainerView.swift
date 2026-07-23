import SwiftUI

/// The expanded island: a slim switcher row (one chip per active activity, plus a Home chip for
/// the calendar/reminders dashboard and a Settings gear) above the selected content.
struct ExpandedContainerView: View {
  /// The physical notch's size, so the switcher can flank it in the top band.
  let notchSize: CGSize
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
        .padding(.horizontal, 12)
    }
  }

  private var switcherBar: some View {
    HStack(spacing: 6) {
      ForEach(tabs, id: \.id) { tab in
        let selected = tab.id == effectiveSelection
        Button {
          Haptics.perform(.alignment)
          selection = tab.id
        } label: {
          Image(systemName: tab.icon)
            .font(.caption)
            .frame(width: 26, height: 20)
            .background(
              RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(selected ? 0.22 : 0.06))
            )
            .foregroundStyle(selected ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.id == Self.homeTab ? "Home" : ActivityCatalog.name(for: tab.id))
      }
      // Gap for the physical notch, keeping tabs in the left ear and the gear in the right ear.
      Spacer(minLength: notchSize.width)
      Button {
        Haptics.perform()
        SettingsOpener.open()
      } label: {
        Image(systemName: "gearshape.fill")
          .font(.caption)
          .frame(width: 26, height: 20)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Settings")
    }
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
