import AppKit
import Carbon.HIToolbox
import Defaults
import Foundation

struct GlobalShortcut: Codable, Equatable, Sendable, Defaults.Serializable {
  struct Modifiers: OptionSet, Codable, Equatable, Sendable {
    let rawValue: UInt32

    static let command = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)

    static let shortcutModifiers: Self = [.command, .option, .control, .shift]
  }

  static let `default` = Self(keyCode: UInt32(kVK_Space), key: "Space", modifiers: .option)

  let keyCode: UInt32
  let key: String
  let modifiers: Modifiers

  var displayName: String {
    var result = ""
    if modifiers.contains(.control) { result += "⌃" }
    if modifiers.contains(.option) { result += "⌥" }
    if modifiers.contains(.shift) { result += "⇧" }
    if modifiers.contains(.command) { result += "⌘" }
    return result + key
  }

  var carbonModifiers: UInt32 {
    var result: UInt32 = 0
    if modifiers.contains(.command) { result |= UInt32(cmdKey) }
    if modifiers.contains(.option) { result |= UInt32(optionKey) }
    if modifiers.contains(.control) { result |= UInt32(controlKey) }
    if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
    return result
  }

  init(keyCode: UInt32, key: String, modifiers: Modifiers) {
    self.keyCode = keyCode
    self.key = key
    self.modifiers = modifiers.intersection(.shortcutModifiers)
  }

  init(event: NSEvent) {
    self.init(
      keyCode: UInt32(event.keyCode),
      key: Self.keyName(for: event),
      modifiers: Self.modifiers(from: event.modifierFlags))
  }

  private static func modifiers(from flags: NSEvent.ModifierFlags) -> Modifiers {
    var result: Modifiers = []
    if flags.contains(.command) { result.insert(.command) }
    if flags.contains(.option) { result.insert(.option) }
    if flags.contains(.control) { result.insert(.control) }
    if flags.contains(.shift) { result.insert(.shift) }
    return result
  }

  private static func keyName(for event: NSEvent) -> String {
    switch Int(event.keyCode) {
    case kVK_Space: return "Space"
    case kVK_Return: return "Return"
    case kVK_Tab: return "Tab"
    case kVK_Delete: return "Delete"
    case kVK_ForwardDelete: return "Forward Delete"
    case kVK_LeftArrow: return "←"
    case kVK_RightArrow: return "→"
    case kVK_DownArrow: return "↓"
    case kVK_UpArrow: return "↑"
    case kVK_Home: return "Home"
    case kVK_End: return "End"
    case kVK_PageUp: return "Page Up"
    case kVK_PageDown: return "Page Down"
    default:
      let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespaces)
      if let characters, !characters.isEmpty { return characters.uppercased() }
      return "Key " + String(event.keyCode)
    }
  }
}

enum GlobalShortcutValidationError: LocalizedError, Equatable {
  case modifierKeyRequired
  case unsupportedKey

  var errorDescription: String? {
    switch self {
    case .modifierKeyRequired: "Use Command, Option, or Control with another key."
    case .unsupportedKey: "Choose a letter, number, Space, arrow, or function key."
    }
  }
}

enum GlobalShortcutValidator {
  private static let supportedKeyCodes: Set<Int> = [
    kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
    kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
    kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
    kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
    kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
    kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    kVK_Space, kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow,
    kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
    kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
    kVK_F20,
  ]

  static func validate(_ shortcut: GlobalShortcut) -> GlobalShortcutValidationError? {
    let primaryModifiers: GlobalShortcut.Modifiers = [.command, .option, .control]
    guard !shortcut.modifiers.intersection(primaryModifiers).isEmpty else {
      return .modifierKeyRequired
    }
    guard supportedKeyCodes.contains(Int(shortcut.keyCode)) else { return .unsupportedKey }
    return nil
  }
}

enum GlobalShortcutRegistrationStatus: Equatable {
  case disabled
  case registered
  case conflict
  case invalid(GlobalShortcutValidationError)
  case failed(OSStatus)

  var message: String {
    switch self {
    case .disabled: "Off"
    case .registered: "Ready"
    case .conflict: "That shortcut is already registered by another app."
    case .invalid(let error): error.localizedDescription
    case .failed(let status): "macOS could not register this shortcut (error \(status))."
    }
  }
}

protocol GlobalShortcutRegistering: AnyObject {
  func register(_ shortcut: GlobalShortcut, handler: @escaping @MainActor () -> Void) -> OSStatus
  func unregister()
}

final class CarbonGlobalShortcutRegistrar: GlobalShortcutRegistering, @unchecked Sendable {
  private static let signature: OSType = 0x4953_4C54  // ISLT
  private static let identifier: UInt32 = 1
  private var hotKey: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  private var action: (@MainActor () -> Void)?

  func register(_ shortcut: GlobalShortcut, handler: @escaping @MainActor () -> Void) -> OSStatus {
    unregister()
    action = handler
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let installStatus = InstallEventHandler(
      GetApplicationEventTarget(), Self.callback, 1, &eventType,
      Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    guard installStatus == noErr else {
      action = nil
      return installStatus
    }

    let identifier = EventHotKeyID(signature: Self.signature, id: Self.identifier)
    let status = RegisterEventHotKey(
      shortcut.keyCode, shortcut.carbonModifiers, identifier, GetApplicationEventTarget(), 0,
      &hotKey)
    if status != noErr { unregister() }
    return status
  }

  func unregister() {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    if let eventHandler { RemoveEventHandler(eventHandler) }
    hotKey = nil
    eventHandler = nil
    action = nil
  }

  deinit { unregister() }

  private static let callback: EventHandlerUPP = { _, _, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let registrar = Unmanaged<CarbonGlobalShortcutRegistrar>.fromOpaque(userData)
      .takeUnretainedValue()
    MainActor.assumeIsolated { registrar.action?() }
    return noErr
  }
}

@MainActor
final class GlobalShortcutManager: ObservableObject {
  static let shared = GlobalShortcutManager()

  @Published private(set) var status: GlobalShortcutRegistrationStatus = .disabled
  private let registrar: GlobalShortcutRegistering
  private var observation: Defaults.Observation?

  init(registrar: GlobalShortcutRegistering = CarbonGlobalShortcutRegistrar()) {
    self.registrar = registrar
  }

  func start() {
    guard observation == nil else { return }
    observation = Defaults.observe(.commandPaletteShortcut) { [weak self] change in
      Task { @MainActor in self?.register(change.newValue) }
    }
    register(Defaults[.commandPaletteShortcut])
  }

  func stop() {
    observation = nil
    registrar.unregister()
    status = .disabled
  }

  func register(_ shortcut: GlobalShortcut?) {
    registrar.unregister()
    guard let shortcut else {
      status = .disabled
      return
    }
    if let error = GlobalShortcutValidator.validate(shortcut) {
      status = .invalid(error)
      return
    }

    let registrationStatus = registrar.register(shortcut) {
      QuickActionsOpener.open()
    }
    switch registrationStatus {
    case noErr: status = .registered
    case OSStatus(eventHotKeyExistsErr): status = .conflict
    default: status = .failed(registrationStatus)
    }
  }
}
