import MapKit
import SwiftUI

struct ReminderAdvancedEditorView: View {
  @Binding var alarms: [ReminderAlarmValue]
  @Binding var recurrenceRules: [ReminderRecurrenceValue]
  let opaqueAlarmCount: Int
  let opaqueRecurrenceCount: Int
  @State private var alertEditor: AlertSelection?
  @State private var repeatEditor: RepeatSelection?

  private struct AlertSelection: Identifiable {
    let id = UUID()
    let index: Int?
    let value: ReminderAlarmValue
  }
  private struct RepeatSelection: Identifiable {
    let id = UUID()
    let index: Int?
    let value: ReminderRecurrenceValue
  }

  var body: some View {
    DisclosureGroup("Alerts") {
      VStack(alignment: .leading) {
        ForEach(alarms.indices, id: \.self) { index in
          HStack {
            Button(ReminderAlarmPresentation.title(alarms[index])) {
              alertEditor = AlertSelection(index: index, value: alarms[index])
            }
            Spacer()
            Button("Remove alert", systemImage: "minus.circle") { alarms.remove(at: index) }
              .labelStyle(.iconOnly)
              .accessibilityLabel("Remove alert \(index + 1)")
          }
        }
        Button("Add alert") { alertEditor = AlertSelection(index: nil, value: .relative(-900)) }
        if opaqueAlarmCount > 0 {
          Text("\(opaqueAlarmCount) alerts require Reminders. Islet will preserve them.").font(
            .caption)
        }
      }.padding(.top, 6)
    }
    DisclosureGroup("Repeat") {
      VStack(alignment: .leading) {
        ForEach(recurrenceRules.indices, id: \.self) { index in
          HStack {
            Button(recurrenceRules[index].frequency.title) {
              repeatEditor = RepeatSelection(index: index, value: recurrenceRules[index])
            }
            Spacer()
            Button("Remove repeat rule", systemImage: "minus.circle") {
              recurrenceRules.remove(at: index)
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Remove repeat rule \(index + 1)")
          }
        }
        Button("Add repeat rule") {
          repeatEditor = RepeatSelection(index: nil, value: .init(frequency: .weekly))
        }
        Text("Repeating reminders need a due date.").font(.caption).foregroundStyle(.secondary)
        if opaqueRecurrenceCount > 0 {
          Text("\(opaqueRecurrenceCount) repeat rules require Reminders. Islet will preserve them.")
            .font(.caption)
        }
      }.padding(.top, 6)
    }
    Text("Use Open in Reminders for tags, flags, subtasks, attachments, and sharing.")
      .font(.caption).foregroundStyle(.secondary)
      .sheet(item: $alertEditor) { selection in
        ReminderAlarmEditor(value: selection.value) { value in
          if let index = selection.index, alarms.indices.contains(index) {
            alarms[index] = value
          } else {
            alarms.append(value)
          }
          alertEditor = nil
        }
      }
      .sheet(item: $repeatEditor) { selection in
        ReminderRecurrenceEditor(value: selection.value) { value in
          if let index = selection.index, recurrenceRules.indices.contains(index) {
            recurrenceRules[index] = value
          } else {
            recurrenceRules.append(value)
          }
          repeatEditor = nil
        }
      }
  }

}

enum ReminderAlarmPresentation {
  static func title(_ value: ReminderAlarmValue) -> String {
    switch value {
    case .absolute(let date): date.formatted(date: .abbreviated, time: .shortened)
    case .relative(let offset):
      String(localized: "\((offset / 60).formatted()) minutes from due time")
    case .location(let title, _, _, _, let onArrival):
      onArrival ? String(localized: "Arrive at \(title)") : String(localized: "Leave \(title)")
    }
  }
}

private struct ReminderAlarmEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State private var kind = 0
  @State private var date = Date()
  @State private var minutes: Double = -15
  @State private var place = ""
  @State private var latitude: Double = 0
  @State private var longitude: Double = 0
  @State private var radius: Double = 100
  @State private var onArrival = true
  @State private var query = ""
  @State private var results: [MKMapItem] = []
  @State private var searching = false
  @State private var error: String?
  let value: ReminderAlarmValue
  let onSave: (ReminderAlarmValue) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Alert").font(.headline)
      Form {
        Picker("Trigger", selection: $kind) {
          Text("Date and time").tag(0)
          Text("Relative to due time").tag(1)
          Text("Location").tag(2)
        }
        if kind == 0 { DatePicker("Alert date", selection: $date) }
        if kind == 1 {
          TextField("Minutes from due time", value: $minutes, format: .number)
          Text("Use a negative number for an early alert, or 0 for the due time.").font(.caption)
        }
        if kind == 2 {
          HStack {
            TextField("Search for a place", text: $query)
            Button("Search") { Task { await search() } }.disabled(searching || query.isEmpty)
          }
          ForEach(results.indices, id: \.self) { index in
            Button(results[index].name ?? String(localized: "Place \(index + 1)")) {
              let result = results[index]
              place = result.name ?? query
              latitude = result.location.coordinate.latitude
              longitude = result.location.coordinate.longitude
              results = []
            }
          }
          TextField("Location name", text: $place)
          TextField("Latitude", value: $latitude, format: .number)
          TextField("Longitude", value: $longitude, format: .number)
          TextField("Radius in meters", value: $radius, format: .number)
          Picker("Notify when", selection: $onArrival) {
            Text("Arriving").tag(true)
            Text("Leaving").tag(false)
          }
        }
      }
      if let error { Text(error).foregroundStyle(.orange).font(.caption) }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Use alert") { save() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20).frame(width: 450)
    .onAppear {
      switch value {
      case .absolute(let value):
        kind = 0
        date = value
      case .relative(let value):
        kind = 1
        minutes = value / 60
      case .location(let title, let lat, let lon, let r, let arrival):
        kind = 2
        place = title
        latitude = lat
        longitude = lon
        radius = r
        onArrival = arrival
      }
    }
  }

  private func save() {
    let edited: ReminderAlarmValue
    switch kind {
    case 0: edited = .absolute(date)
    case 1: edited = .relative(minutes * 60)
    default:
      edited = .location(
        title: place, latitude: latitude, longitude: longitude, radius: radius, onArrival: onArrival
      )
    }
    do {
      _ = try ReminderAdvancedCodec.alarm(from: edited)
      onSave(edited)
    } catch { self.error = error.localizedDescription }
  }

  private func search() async {
    searching = true
    defer { searching = false }
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    do {
      results = Array(try await MKLocalSearch(request: request).start().mapItems.prefix(5))
      error =
        results.isEmpty
        ? String(localized: "No matching places. Try a street address or enter coordinates.") : nil
    } catch {
      self.error =
        String(
          localized:
            "Place search failed. Try again or enter coordinates. \(error.localizedDescription)")
    }
  }
}

private struct ReminderRecurrenceEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State private var edited: ReminderRecurrenceValue
  @State private var weekdays = ""
  @State private var monthDays = ""
  @State private var months = ""
  @State private var weeks = ""
  @State private var yearDays = ""
  @State private var positions = ""
  @State private var endKind = 0
  @State private var endDate = Date()
  @State private var count = 10
  @State private var error: String?
  let onSave: (ReminderRecurrenceValue) -> Void

  init(value: ReminderRecurrenceValue, onSave: @escaping (ReminderRecurrenceValue) -> Void) {
    _edited = State(initialValue: value)
    self.onSave = onSave
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Repeat rule").font(.headline)
      Form {
        Picker("Frequency", selection: $edited.frequency) {
          ForEach(ReminderRecurrenceValue.Frequency.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        TextField("Every", value: $edited.interval, format: .number)
        Picker("Ends", selection: $endKind) {
          Text("Never").tag(0)
          Text("On date").tag(1)
          Text("After occurrences").tag(2)
        }
        if endKind == 1 { DatePicker("End date", selection: $endDate) }
        if endKind == 2 { TextField("Occurrences", value: $count, format: .number) }
        DisclosureGroup("Custom selectors") {
          Text("Separate numbers with commas. Negative numbers count back from the end.").font(
            .caption)
          TextField("Weekdays", text: $weekdays)
          Text(
            "1 is Sunday, 7 is Saturday. Use day:ordinal for an ordinal weekday, such as 2:-1 for the last Monday."
          ).font(.caption)
          TextField("Days of month, 1 to 31", text: $monthDays)
          TextField("Months, 1 to 12", text: $months)
          TextField("Weeks of year, 1 to 53", text: $weeks)
          TextField("Days of year, 1 to 366", text: $yearDays)
          TextField("Set positions, 1 to 366", text: $positions)
        }
      }
      if let error { Text(error).foregroundStyle(.orange).font(.caption) }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Use repeat rule") { save() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20).frame(width: 470)
    .onAppear {
      weekdays = edited.weekdays.map { "\($0.day):\($0.ordinal)" }.joined(separator: ",")
      monthDays = text(edited.monthDays)
      months = text(edited.months)
      weeks = text(edited.weeks)
      yearDays = text(edited.yearDays)
      positions = text(edited.positions)
      switch edited.end {
      case .never: endKind = 0
      case .date(let date):
        endKind = 1
        endDate = date
      case .count(let value):
        endKind = 2
        count = value
      }
    }
  }

  private func text(_ values: [Int]) -> String { values.map(String.init).joined(separator: ",") }
  private func integers(_ value: String) throws -> [Int] {
    if value.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
    return try value.split(separator: ",", omittingEmptySubsequences: false).map {
      guard let number = Int($0.trimmingCharacters(in: .whitespaces)) else {
        throw ReminderAdvancedCodec.invalidRecurrence
      }
      return number
    }
  }
  private func save() {
    do {
      var value = edited
      value.weekdays =
        try weekdays.trimmingCharacters(in: .whitespaces).isEmpty
        ? []
        : weekdays.split(separator: ",", omittingEmptySubsequences: false).map {
          let parts = $0.split(separator: ":", omittingEmptySubsequences: false)
          guard (1...2).contains(parts.count),
            let day = Int(parts[0].trimmingCharacters(in: .whitespaces))
          else { throw ReminderAdvancedCodec.invalidRecurrence }
          let ordinal = parts.count == 1 ? 0 : Int(parts[1].trimmingCharacters(in: .whitespaces))
          guard let ordinal else { throw ReminderAdvancedCodec.invalidRecurrence }
          return .init(day: day, ordinal: ordinal)
        }
      value.monthDays = try integers(monthDays)
      value.months = try integers(months)
      value.weeks = try integers(weeks)
      value.yearDays = try integers(yearDays)
      value.positions = try integers(positions)
      value.end = endKind == 0 ? .never : endKind == 1 ? .date(endDate) : .count(count)
      _ = try ReminderAdvancedCodec.recurrence(from: value)
      onSave(value)
    } catch { self.error = error.localizedDescription }
  }
}
