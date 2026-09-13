import AppKit
import EventKit
import SwiftUI

struct ReminderManagedList: Identifiable, Equatable {
  let id: String
  let sourceID: String
  let sourceTitle: String
  let title: String
  let colorHex: String?
  let isImmutable: Bool
}

struct ReminderListEdit {
  let baseline: ReminderManagedList?
  let sourceID: String
  let title: String
  let color: NSColor

  func validate(current: ReminderManagedList?) throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ReminderWriteError.eventKit(String(localized: "Enter a list name."))
    }
    if let baseline {
      guard let current else { throw ReminderWriteError.missingList }
      guard current == baseline else { throw ReminderWriteError.changedElsewhere }
      guard !current.isImmutable else {
        throw ReminderWriteError.eventKit(
          String(
            localized:
              "This account does not allow changes to this list. Open Reminders to manage it."))
      }
      guard sourceID == current.sourceID else { throw ReminderWriteError.missingList }
    }
  }
}

@MainActor
final class ReminderListManager {
  struct Source: Identifiable {
    let id: String
    let title: String
  }
  enum Outcome {
    case saved(ReminderManagedList, message: String? = nil)
    case uncertain(String)
  }
  private let store: EKEventStore
  private let readback: EKEventStore
  private(set) var isPending = false
  private var pendingListID: String?

  init(store: EKEventStore = EKEventStore(), readback: EKEventStore = EKEventStore()) {
    self.store = store
    self.readback = readback
  }

  func lists() -> [ReminderManagedList] {
    guard EventKitPermissionState(EKEventStore.authorizationStatus(for: .reminder)).canRead else {
      return []
    }
    return store.calendars(for: .reminder).map(Self.record).sorted {
      $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
  }

  func sources() -> [Source] {
    store.sources.filter { $0.sourceType != .subscribed && $0.sourceType != .birthdays }
      .map { Source(id: $0.sourceIdentifier, title: $0.title) }
  }

  func defaultSourceID() -> String? {
    store.defaultCalendarForNewReminders()?.source.sourceIdentifier
  }

  func save(_ edit: ReminderListEdit) throws -> Outcome {
    guard !isPending else { throw ReminderWriteError.commitStatusUnknown }
    guard EventKitPermissionState(EKEventStore.authorizationStatus(for: .reminder)).canRead else {
      throw ReminderWriteError.permissionDenied
    }
    store.reset()
    let existing = edit.baseline.flatMap { baseline in
      store.calendars(for: .reminder).first { $0.calendarIdentifier == baseline.id }
    }
    try edit.validate(current: existing.map(Self.record))
    let calendar: EKCalendar
    if let existing {
      calendar = existing
    } else {
      guard let source = store.sources.first(where: { $0.sourceIdentifier == edit.sourceID }) else {
        throw ReminderWriteError.eventKit(
          String(localized: "That account is no longer available. Choose another account."))
      }
      calendar = EKCalendar(for: .reminder, eventStore: store)
      calendar.source = source
    }
    let title = edit.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if edit.baseline?.title != title { calendar.title = title }
    let colorHex = ColorHex.string(from: edit.color.cgColor)
    if edit.baseline?.colorHex != colorHex { calendar.cgColor = edit.color.cgColor }
    do {
      try store.saveCalendar(calendar, commit: false)
      guard calendar.title == title, ColorHex.string(from: calendar.cgColor) == colorHex else {
        throw ReminderWriteError.eventKit(
          String(localized: "This account does not support the requested list name or color."))
      }
    } catch {
      store.reset()
      throw ReminderWriteError.eventKit(
        String(
          localized:
            "The list was not saved. This account may not allow list creation or editing. \(error.localizedDescription)"
        ))
    }
    do { try store.commit() } catch {
      store.reset()
      isPending = true
      pendingListID = calendar.calendarIdentifier
      return .uncertain(
        String(
          localized:
            "The account did not confirm the list save. Open Reminders to check before creating or saving it again."
        ))
    }
    readback.reset()
    guard
      let actual = readback.calendars(for: .reminder).first(where: {
        $0.calendarIdentifier == calendar.calendarIdentifier
      })
    else {
      isPending = true
      pendingListID = calendar.calendarIdentifier
      return .uncertain(
        String(
          localized:
            "The list save is awaiting confirmation. Open Reminders to check it before trying again."
        ))
    }
    let record = Self.record(actual)
    guard record.title == title, record.colorHex == colorHex else {
      return .saved(
        record,
        message:
          "The account saved a different list name or color. The saved values are shown here.")
    }
    return .saved(record)
  }

  func reconcilePending() -> ReminderManagedList? {
    guard isPending, let id = pendingListID else { return nil }
    readback.reset()
    guard
      let actual = readback.calendars(for: .reminder).first(where: { $0.calendarIdentifier == id })
    else { return nil }
    isPending = false
    pendingListID = nil
    return Self.record(actual)
  }

  private static func record(_ calendar: EKCalendar) -> ReminderManagedList {
    ReminderManagedList(
      id: calendar.calendarIdentifier, sourceID: calendar.source?.sourceIdentifier ?? "",
      sourceTitle: calendar.source?.title ?? "", title: calendar.title,
      colorHex: ColorHex.string(from: calendar.cgColor), isImmutable: calendar.isImmutable)
  }
}

struct ReminderListManagerView: View {
  @Environment(\.dismiss) private var dismiss
  let manager: ReminderListManager
  @State private var lists: [ReminderManagedList] = []
  @State private var sources: [ReminderListManager.Source] = []
  @State private var selectedID: String?
  @State private var selectingSavedList = false
  @State private var baseline: ReminderManagedList?
  @State private var title = ""
  @State private var sourceID = ""
  @State private var color = Color.blue
  @State private var message: String?
  @State private var pending = false
  let onChange: () -> Void
  let openReminders: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Reminder lists").font(.headline)
      Picker("List", selection: $selectedID) {
        Text("New list").tag(String?.none)
        ForEach(lists) { Text("\($0.title), \($0.sourceTitle)").tag(Optional($0.id)) }
      }
      .disabled(pending)
      Form {
        TextField("Name", text: $title)
        Picker("Account", selection: $sourceID) {
          ForEach(sources) { Text($0.title).tag($0.id) }
        }.disabled(baseline != nil)
        ColorPicker("Color", selection: $color, supportsOpacity: false)
      }.disabled(pending || baseline?.isImmutable == true)
      if baseline?.isImmutable == true {
        Text("This account does not allow changes to this list.").font(.caption)
      }
      Text(
        "Create and edit plain lists here. Manage sharing, Smart Lists, groups, and list deletion in Reminders."
      )
      .font(.caption).foregroundStyle(.secondary)
      if let message { Text(message).font(.caption).foregroundStyle(.orange) }
      HStack {
        Button("Open in Reminders", action: openReminders)
        if pending { Button("Reload lists") { reconcile() } }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(baseline == nil ? String(localized: "Create list") : String(localized: "Save list"))
        { save() }
        .keyboardShortcut(.defaultAction)
        .disabled(
          pending || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || sourceID.isEmpty || baseline?.isImmutable == true)
      }
    }
    .padding(20).frame(width: 470)
    .onAppear {
      lists = manager.lists()
      sources = manager.sources()
      pending = manager.isPending
      if pending {
        message =
          String(
            localized:
              "A list save is still unconfirmed. Open Reminders to review it before making further list changes."
          )
      }
      sourceID = manager.defaultSourceID() ?? sources.first?.id ?? ""
    }
    .onChange(of: selectedID) { _, id in
      if selectingSavedList {
        selectingSavedList = false
        return
      }
      baseline = lists.first { $0.id == id }
      title = baseline?.title ?? ""
      sourceID = baseline?.sourceID ?? manager.defaultSourceID() ?? sources.first?.id ?? ""
      color = baseline?.colorHex.flatMap { Color(isletHex: $0) } ?? .blue
      message = nil
    }
  }

  private func reconcile() {
    guard let actual = manager.reconcilePending() else {
      message =
        String(
          localized:
            "The list save is still unconfirmed. Check the account in Reminders, then reload again."
        )
      return
    }
    lists = manager.lists()
    selectingSavedList = selectedID != actual.id
    selectedID = actual.id
    baseline = actual
    title = actual.title
    color = actual.colorHex.flatMap { Color(isletHex: $0) } ?? .blue
    pending = false
    message = String(localized: "The account confirmed the list. Its saved values are shown here.")
    onChange()
  }

  private func save() {
    do {
      switch try manager.save(
        ReminderListEdit(
          baseline: baseline, sourceID: sourceID, title: title, color: NSColor(color)))
      {
      case .saved(let actual, let notice):
        lists = manager.lists()
        selectingSavedList = selectedID != actual.id
        selectedID = actual.id
        baseline = actual
        title = actual.title
        color = actual.colorHex.flatMap { Color(isletHex: $0) } ?? .blue
        message = notice
        onChange()
      case .uncertain(let detail):
        pending = true
        message = detail
        onChange()
      }
    } catch { message = error.localizedDescription }
  }
}
