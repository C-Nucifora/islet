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
      Section("General") {
        Toggle("Hide from screen recordings", isOn: $hideFromRecording)
      }
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .fixedSize()
  }
}
