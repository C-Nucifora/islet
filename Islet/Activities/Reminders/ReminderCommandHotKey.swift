import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

/// Registers the inactive-app entry point for reminder commands without event monitoring or
/// Accessibility permissions. Carbon delivers this public global-hotkey event to the app target.
@MainActor
protocol ReminderCommandHotKeyRegistering: AnyObject {
  func register(handler: @escaping @MainActor () -> Void) -> Bool
  func unregister()
}

@MainActor
final class ReminderCommandHotKey: ObservableObject {
  static let shared = ReminderCommandHotKey()

  @Published private(set) var isAvailable = false

  private let registration: any ReminderCommandHotKeyRegistering
  private let dispatch: @MainActor () -> Void

  init(
    registration: (any ReminderCommandHotKeyRegistering)? = nil,
    dispatch: @escaping @MainActor () -> Void = {
      NSApp.activate(ignoringOtherApps: true)
      ReminderCommandsWindow.shared.present(provider: RemindersProvider.shared)
    }
  ) {
    self.registration = registration ?? CarbonReminderCommandHotKeyRegistration()
    self.dispatch = dispatch
  }

  func start() {
    guard !isAvailable else { return }
    isAvailable = registration.register { [weak self] in self?.dispatch() }
    if !isAvailable {
      Log.app.error("Reminder command hotkey is unavailable")
    }
  }

  func stop() {
    guard isAvailable else { return }
    registration.unregister()
    isAvailable = false
  }
}

@MainActor
private final class CarbonReminderCommandHotKeyRegistration: ReminderCommandHotKeyRegistering {
  private static let signature: OSType = 0x4953_4C54  // ISLT
  private static let identifier: UInt32 = 1

  private var handler: (@MainActor () -> Void)?
  private var eventHandlerRef: EventHandlerRef?
  private var hotKeyRef: EventHotKeyRef?

  func register(handler: @escaping @MainActor () -> Void) -> Bool {
    guard eventHandlerRef == nil, hotKeyRef == nil else { return false }
    self.handler = handler

    var eventType = EventTypeSpec(
      eventClass: UInt32(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    var eventHandlerRef: EventHandlerRef?
    guard
      InstallEventHandler(
        GetApplicationEventTarget(), Self.handleEvent, 1, &eventType,
        Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef) == noErr,
      let eventHandlerRef
    else {
      self.handler = nil
      return false
    }

    var hotKeyRef: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(kVK_ANSI_R), UInt32(cmdKey | optionKey | shiftKey),
      EventHotKeyID(signature: Self.signature, id: Self.identifier), GetApplicationEventTarget(), 0,
      &hotKeyRef)
    guard status == noErr, let hotKeyRef else {
      RemoveEventHandler(eventHandlerRef)
      self.handler = nil
      return false
    }

    self.eventHandlerRef = eventHandlerRef
    self.hotKeyRef = hotKeyRef
    return true
  }

  func unregister() {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    hotKeyRef = nil
    eventHandlerRef = nil
    handler = nil
  }

  private static let handleEvent: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    guard
      GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID) == noErr,
      hotKeyID.signature == CarbonReminderCommandHotKeyRegistration.signature,
      hotKeyID.id == CarbonReminderCommandHotKeyRegistration.identifier
    else {
      return OSStatus(eventNotHandledErr)
    }

    let registration = Unmanaged<CarbonReminderCommandHotKeyRegistration>
      .fromOpaque(userData)
      .takeUnretainedValue()
    Task { @MainActor in registration.handler?() }
    return noErr
  }
}
