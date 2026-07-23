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

  var body: some View {
    Form {
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
        Picker("Source", selection: $sourceMode) {
          Text("Whatever is playing").tag(MediaSourceMode.auto)
          Text("Prioritized players").tag(MediaSourceMode.prioritized)
        }
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
