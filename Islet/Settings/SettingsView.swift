import Defaults
import SwiftUI

struct SettingsView: View {
  @Default(.interactionMode) private var mode
  @Default(.hoverExpandDelay) private var expandDelay
  @Default(.hoverCollapseTimeout) private var collapseTimeout
  @Default(.hapticsEnabled) private var haptics
  @Default(.hideFromScreenRecording) private var hideFromRecording
  @Default(.mediaSourceMode) private var sourceMode
  @Default(.mediaPriorityList) private var priorityList
  @State private var newBundleID = ""
  @Default(.batteryEnabled) private var batteryEnabled
  @Default(.hudEnabled) private var hudEnabled
  @Default(.hudStyle) private var hudStyle
  @State private var hudTrusted = HUDController.shared.isAccessibilityTrusted
  @Default(.calendarEnabled) private var calendarEnabled
  @Default(.calendarLeadMinutes) private var calendarLeadMinutes
  @Default(.remindersEnabled) private var remindersEnabled
  @Default(.airpodsEnabled) private var airpodsEnabled
  @Default(.showOnAllDisplays) private var showOnAllDisplays
  @Default(.hideInFullscreen) private var hideInFullscreen
  @Default(.launchAtLogin) private var launchAtLogin
  @Default(.activityOrder) private var activityOrder
  @Default(.disabledActivities) private var disabledActivities
  @Default(.clipboardEnabled) private var clipboardEnabled
  @Default(.portsEnabled) private var portsEnabled
  @Default(.systemEnabled) private var systemEnabled
  @Default(.systemAlwaysVisible) private var systemAlwaysVisible
  @Default(.metricStyles) private var metricStyles
  @Default(.disabledEventSources) private var disabledEventSources
  @Default(.continuityEnabled) private var continuityEnabled
  @Default(.continuityAlwaysVisible) private var continuityAlwaysVisible
  @Default(.continuitySneaks) private var continuitySneaks

  private func enabled(_ id: String) -> Binding<Bool> {
    Binding(
      get: { !disabledActivities.contains(id) },
      set: { on in
        if on {
          disabledActivities.removeAll { $0 == id }
        } else if !disabledActivities.contains(id) {
          disabledActivities.append(id)
        }
      })
  }

  private func styleBinding(_ kind: SystemMetricKind) -> Binding<MetricDisplayStyle> {
    Binding(
      get: { MetricDisplayStyle.resolve(metricStyles[kind.rawValue]) },
      set: { metricStyles[kind.rawValue] = $0.rawValue })
  }

  /// Writes through the bus rather than straight to Defaults, so toggling a source actually starts
  /// or stops its observation instead of only silencing it.
  private func eventSourceEnabled(_ id: String) -> Binding<Bool> {
    Binding(
      get: { !disabledEventSources.contains(id) },
      set: { on in SystemEventBus.shared.setEnabled(on, for: id) })
  }

  var body: some View {
    Form {
      Section("System stats") {
        Toggle("System stats tab", isOn: $systemEnabled)
        if systemEnabled {
          Toggle("Always show the tab", isOn: $systemAlwaysVisible)
          Text(
            "Off: the tab appears only when the CPU stays above 80% for five seconds, or the Mac is thermally throttled."
          )
          .font(.caption2).foregroundStyle(.secondary)
          ForEach(SystemMetricKind.allCases, id: \.self) { kind in
            Picker(kind.displayName, selection: styleBinding(kind)) {
              ForEach(MetricDisplayStyle.allCases, id: \.self) { style in
                Text(style.displayName).tag(style)
              }
            }
          }
          Text("Thermal has no history, so the sparkline styles show its state as text.")
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
      Section("iPhone") {
        Toggle("iPhone Live Activities", isOn: $continuityEnabled)
        if continuityEnabled {
          Toggle("Always show the tab", isOn: $continuityAlwaysVisible)
          Toggle("Announce when one starts or ends", isOn: $continuitySneaks)
          Text(ContinuityMonitor.shared.availability.explanation)
            .font(.caption2).foregroundStyle(.secondary)
          Text(
            "Shows the same Live Activities macOS puts in the menu bar. Islet draws them itself, so how much detail it can show varies by app."
          )
          .font(.caption2).foregroundStyle(.secondary)
        }
      }
      Section("System events") {
        Text(
          "Islet shows a brief animation in the island when something happens. Turn a source off and Islet stops watching it entirely."
        )
        .font(.caption).foregroundStyle(.secondary)

        ForEach(SystemEventTier.allCases, id: \.rawValue) { tier in
          let ids = SourceCatalog.ids(in: tier)
          if !ids.isEmpty {
            Text(tier.label)
              .font(.caption.weight(.semibold))
              .foregroundStyle(tier == .heuristic ? .orange : .secondary)
            if tier == .heuristic {
              Text(
                "These are inferred rather than reported. AirDrop arrivals are noticed after the transfer finishes and cannot name the sender; a network tunnel may be iCloud Private Relay rather than a VPN."
              )
              .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(ids, id: \.self) { id in
              Toggle(isOn: eventSourceEnabled(id)) {
                Label(SourceCatalog.name(for: id), systemImage: SourceCatalog.icon(for: id))
              }
            }
          }
        }
      }
      Section("Menu order") {
        Text("Drag to reorder the tabs in the expanded island. Turn one off to hide it entirely.")
          .font(.caption).foregroundStyle(.secondary)
        List {
          ForEach(activityOrder, id: \.self) { id in
            Toggle(isOn: enabled(id)) {
              Label(ActivityCatalog.name(for: id), systemImage: ActivityCatalog.icon(for: id))
            }
          }
          .onMove { activityOrder.move(fromOffsets: $0, toOffset: $1) }
        }
        .frame(height: 216)
      }
      Section("Interaction") {
        Picker("Expand", selection: $mode) {
          Text("Hover").tag(InteractionMode.hover)
          Text("Click to pin").tag(InteractionMode.clickToPin)
        }
        if mode == .hover {
          LabeledContent(
            "Hover delay: \(expandDelay, format: .number.precision(.fractionLength(1)))s"
          ) {
            Slider(value: $expandDelay, in: 0.1...1.0, step: 0.1)
          }
          LabeledContent(
            "Collapse after: \(collapseTimeout, format: .number.precision(.fractionLength(1)))s"
          ) {
            Slider(value: $collapseTimeout, in: 0.2...3.0, step: 0.1)
          }
        }
        Toggle("Haptics", isOn: $haptics)
      }
      Section("Media") {
        Picker("Player order", selection: $sourceMode) {
          Text("Whatever is playing").tag(MediaSourceMode.auto)
          Text("My order").tag(MediaSourceMode.prioritized)
        }
        Text(
          "Every player is shown. This picks which one gets the big player when more than one is going; the rest appear as icons underneath."
        )
        .font(.caption).foregroundStyle(.secondary)
        if sourceMode == .prioritized {
          List {
            ForEach(priorityList, id: \.self) { Text($0).font(.callout.monospaced()) }
              .onMove { priorityList.move(fromOffsets: $0, toOffset: $1) }
              .onDelete { priorityList.remove(atOffsets: $0) }
          }
          .frame(height: 90)
          HStack {
            TextField("Bundle ID (e.g. com.spotify.client)", text: $newBundleID)
            Button("Add") {
              priorityList.append(newBundleID)
              newBundleID = ""
            }
            .disabled(newBundleID.isEmpty)
          }
        }
      }
      Section("Activities") {
        Toggle("Battery & charging", isOn: $batteryEnabled)
        Toggle("HUD replacement (volume & brightness)", isOn: $hudEnabled)
        if hudEnabled, !hudTrusted {
          HStack {
            Text("Needs Accessibility permission").foregroundStyle(.secondary)
            Spacer()
            Button("Grant…") {
              HUDController.shared.promptForAccessibility()
            }
          }
        }
        if hudEnabled {
          Picker("HUD style", selection: $hudStyle) {
            Text("Bar").tag(HUDStyle.bar)
            Text("Gauge").tag(HUDStyle.gauge)
          }
        }
        Toggle("Calendar", isOn: $calendarEnabled)
        if calendarEnabled {
          Stepper(
            "Countdown lead: \(calendarLeadMinutes) min", value: $calendarLeadMinutes,
            in: 5...60, step: 5)
        }
        Toggle("Reminders", isOn: $remindersEnabled)
        Toggle("Clipboard history", isOn: $clipboardEnabled)
        if clipboardEnabled {
          Text("Captures everything you copy (incl. passwords), kept only until you quit.")
            .font(.caption2).foregroundStyle(.secondary)
        }
        Toggle("Ports (what's plugged in)", isOn: $portsEnabled)
        Toggle("AirPods & audio devices", isOn: $airpodsEnabled)
        LabeledContent("Media adapter") {
          Text(AppState.nowPlaying.adapterStatus).foregroundStyle(.secondary)
        }
      }
      Section("General") {
        Toggle("Launch at login", isOn: $launchAtLogin)
        Toggle("Show on all displays", isOn: $showOnAllDisplays)
        Toggle("Hide when an app is fullscreen", isOn: $hideInFullscreen)
        Toggle("Hide from screen recordings", isOn: $hideFromRecording)
      }
    }
    .formStyle(.grouped)
    .frame(width: 440, height: 520)
  }
}
