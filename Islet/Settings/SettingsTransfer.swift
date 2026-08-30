import Defaults
import Foundation

struct SettingsTransferSnapshot: Equatable {
  var appTheme: AppTheme
  var batteryGraphStyle: BatteryGraphStyle
  var mediaSourceMode: MediaSourceMode
  var mediaPriorityList: [String]
  var excludedAudioOnlySourceBundleIdentifiers: [String]
  var interactionMode: InteractionMode
  var hoverCollapseTimeout: Double
  var hapticsEnabled: Bool
  var hapticStrength: HapticStrength
  var barrierPushDistance: Double
  var energyMode: EnergyMode
  var allowDisplaySleep: Bool
  var keepAwakeWithLidClosed: Bool
  var keepAwakeLowBatteryThreshold: Int
  var hideFromScreenRecording: Bool
  var hudEnabled: Bool
  var hudStyle: HUDStyle
  var calendarEnabled: Bool
  var calendarLeadMinutes: Int
  var remindersEnabled: Bool
  var showOnAllDisplays: Bool
  var hideInFullscreen: Bool
  var launchAtLogin: Bool
  var activityOrder: [String]
  var disabledActivities: [String]
  var disabledEventSources: [String]
  var systemAlwaysVisible: Bool
  var systemAutoPresentCPU: Bool
  var systemAutoPresentThermal: Bool
  var systemAutoPresentMemoryPressure: Bool
  var systemAutoPresentLowDiskSpace: Bool
  var systemAutoPresentDiskThroughput: Bool
  var systemAutoPresentNetworkThroughput: Bool
  var metricStyles: [String: String]
  var processAttributionEnabled: Bool
  var processCPUThreshold: Double
  var processMemoryThreshold: Double
  var processDiskThresholdMBPerSecond: Double
  var processNetworkThresholdMBPerSecond: Double
  var continuityAlwaysVisible: Bool
  var continuitySneaks: Bool
  var pulseStaleTimeout: Double
}

struct SettingsTransferPatch: Equatable {
  var appTheme: AppTheme?
  var batteryGraphStyle: BatteryGraphStyle?
  var mediaSourceMode: MediaSourceMode?
  var mediaPriorityList: [String]?
  var excludedAudioOnlySourceBundleIdentifiers: [String]?
  var interactionMode: InteractionMode?
  var hoverCollapseTimeout: Double?
  var hapticsEnabled: Bool?
  var hapticStrength: HapticStrength?
  var barrierPushDistance: Double?
  var energyMode: EnergyMode?
  var allowDisplaySleep: Bool?
  var keepAwakeWithLidClosed: Bool?
  var keepAwakeLowBatteryThreshold: Int?
  var hideFromScreenRecording: Bool?
  var hudEnabled: Bool?
  var hudStyle: HUDStyle?
  var calendarEnabled: Bool?
  var calendarLeadMinutes: Int?
  var remindersEnabled: Bool?
  var showOnAllDisplays: Bool?
  var hideInFullscreen: Bool?
  var launchAtLogin: Bool?
  var activityOrder: [String]?
  var disabledActivities: [String]?
  var disabledEventSources: [String]?
  var systemAlwaysVisible: Bool?
  var systemAutoPresentCPU: Bool?
  var systemAutoPresentThermal: Bool?
  var systemAutoPresentMemoryPressure: Bool?
  var systemAutoPresentLowDiskSpace: Bool?
  var systemAutoPresentDiskThroughput: Bool?
  var systemAutoPresentNetworkThroughput: Bool?
  var metricStyles: [String: String]?
  var processAttributionEnabled: Bool?
  var processCPUThreshold: Double?
  var processMemoryThreshold: Double?
  var processDiskThresholdMBPerSecond: Double?
  var processNetworkThresholdMBPerSecond: Double?
  var continuityAlwaysVisible: Bool?
  var continuitySneaks: Bool?
  var pulseStaleTimeout: Double?

  func applying(to snapshot: SettingsTransferSnapshot) -> SettingsTransferSnapshot {
    var result = snapshot
    if let appTheme { result.appTheme = appTheme }
    if let batteryGraphStyle { result.batteryGraphStyle = batteryGraphStyle }
    if let mediaSourceMode { result.mediaSourceMode = mediaSourceMode }
    if let mediaPriorityList { result.mediaPriorityList = mediaPriorityList }
    if let excludedAudioOnlySourceBundleIdentifiers {
      result.excludedAudioOnlySourceBundleIdentifiers = excludedAudioOnlySourceBundleIdentifiers
    }
    if let interactionMode { result.interactionMode = interactionMode }
    if let hoverCollapseTimeout { result.hoverCollapseTimeout = hoverCollapseTimeout }
    if let hapticsEnabled { result.hapticsEnabled = hapticsEnabled }
    if let hapticStrength { result.hapticStrength = hapticStrength }
    if let barrierPushDistance { result.barrierPushDistance = barrierPushDistance }
    if let energyMode { result.energyMode = energyMode }
    if let allowDisplaySleep { result.allowDisplaySleep = allowDisplaySleep }
    if let keepAwakeWithLidClosed {
      result.keepAwakeWithLidClosed = keepAwakeWithLidClosed
    }
    if let keepAwakeLowBatteryThreshold {
      result.keepAwakeLowBatteryThreshold = keepAwakeLowBatteryThreshold
    }
    if let hideFromScreenRecording { result.hideFromScreenRecording = hideFromScreenRecording }
    if let hudEnabled { result.hudEnabled = hudEnabled }
    if let hudStyle { result.hudStyle = hudStyle }
    if let calendarEnabled { result.calendarEnabled = calendarEnabled }
    if let calendarLeadMinutes { result.calendarLeadMinutes = calendarLeadMinutes }
    if let remindersEnabled { result.remindersEnabled = remindersEnabled }
    if let showOnAllDisplays { result.showOnAllDisplays = showOnAllDisplays }
    if let hideInFullscreen { result.hideInFullscreen = hideInFullscreen }
    if let launchAtLogin { result.launchAtLogin = launchAtLogin }
    if let activityOrder { result.activityOrder = activityOrder }
    if let disabledActivities { result.disabledActivities = disabledActivities }
    if let disabledEventSources { result.disabledEventSources = disabledEventSources }
    if let systemAlwaysVisible { result.systemAlwaysVisible = systemAlwaysVisible }
    if let systemAutoPresentCPU { result.systemAutoPresentCPU = systemAutoPresentCPU }
    if let systemAutoPresentThermal { result.systemAutoPresentThermal = systemAutoPresentThermal }
    if let systemAutoPresentMemoryPressure {
      result.systemAutoPresentMemoryPressure = systemAutoPresentMemoryPressure
    }
    if let systemAutoPresentLowDiskSpace {
      result.systemAutoPresentLowDiskSpace = systemAutoPresentLowDiskSpace
    }
    if let systemAutoPresentDiskThroughput {
      result.systemAutoPresentDiskThroughput = systemAutoPresentDiskThroughput
    }
    if let systemAutoPresentNetworkThroughput {
      result.systemAutoPresentNetworkThroughput = systemAutoPresentNetworkThroughput
    }
    if let metricStyles { result.metricStyles = metricStyles }
    if let processAttributionEnabled {
      result.processAttributionEnabled = processAttributionEnabled
    }
    if let processCPUThreshold { result.processCPUThreshold = processCPUThreshold }
    if let processMemoryThreshold { result.processMemoryThreshold = processMemoryThreshold }
    if let processDiskThresholdMBPerSecond {
      result.processDiskThresholdMBPerSecond = processDiskThresholdMBPerSecond
    }
    if let processNetworkThresholdMBPerSecond {
      result.processNetworkThresholdMBPerSecond = processNetworkThresholdMBPerSecond
    }
    if let continuityAlwaysVisible { result.continuityAlwaysVisible = continuityAlwaysVisible }
    if let continuitySneaks { result.continuitySneaks = continuitySneaks }
    if let pulseStaleTimeout { result.pulseStaleTimeout = pulseStaleTimeout }
    return result
  }
}

struct SettingsTransferChange: Equatable, Identifiable {
  let key: String
  let title: String
  let oldValue: String
  let newValue: String

  var id: String { key }
}

struct SettingsTransferPreview: Identifiable {
  let id = UUID()
  let sourceVersion: Int
  let patch: SettingsTransferPatch
  let result: SettingsTransferSnapshot
  let changes: [SettingsTransferChange]
  let ignoredKeys: [String]

  var importedSettingCount: Int { SettingsTransfer.portableKeys.count - missingKeyCount }

  private var missingKeyCount: Int {
    SettingsTransfer.portableKeys.reduce(into: 0) { count, key in
      if !SettingsTransfer.contains(key, in: patch) { count += 1 }
    }
  }
}

enum SettingsTransferError: LocalizedError {
  case corruptDocument
  case documentTooLarge
  case wrongFormat
  case unsupportedVersion(Int)
  case missingSettings
  case invalidValue(key: String, expected: String)

  var errorDescription: String? {
    switch self {
    case .corruptDocument:
      String(localized: "The file is not valid JSON.")
    case .documentTooLarge:
      String(localized: "The settings file is larger than 1 MB.")
    case .wrongFormat:
      String(localized: "The file is not an Islet settings export.")
    case .unsupportedVersion(let version):
      String(localized: "This export uses unsupported settings version \(version).")
    case .missingSettings:
      String(localized: "The export does not contain a settings object.")
    case .invalidValue(let key, let expected):
      String(localized: "\(key) has the wrong value. Expected \(expected).")
    }
  }
}

enum SettingsTransfer {
  static let currentVersion = 2
  static let formatIdentifier = "dev.islet.settings"
  static let maximumDocumentBytes = 1_048_576
  static let maximumListItems = 256
  static let maximumTextBytes = 1_024

  static let portableKeys: [String] = [
    "activityOrder", "allowDisplaySleep", "appTheme", "barrierPushDistance", "batteryGraphStyle",
    "calendarEnabled", "calendarLeadMinutes", "continuityAlwaysVisible", "continuitySneaks",
    "disabledActivities", "disabledEventSources", "energyMode",
    "excludedAudioOnlySourceBundleIdentifiers", "hapticStrength", "hapticsEnabled",
    "hideFromScreenRecording", "hideInFullscreen", "hoverCollapseTimeout", "hudEnabled",
    "hudStyle", "interactionMode", "keepAwakeLowBatteryThreshold", "keepAwakeWithLidClosed",
    "launchAtLogin",
    "mediaPriorityList", "mediaSourceMode", "metricStyles", "pulseStaleTimeout", "remindersEnabled",
    "showOnAllDisplays", "systemAlwaysVisible", "systemAutoPresentCPU",
    "systemAutoPresentDiskThroughput", "systemAutoPresentLowDiskSpace",
    "systemAutoPresentMemoryPressure", "systemAutoPresentNetworkThroughput",
    "systemAutoPresentThermal", "processAttributionEnabled", "processCPUThreshold",
    "processDiskThresholdMBPerSecond", "processMemoryThreshold",
    "processNetworkThresholdMBPerSecond",
  ]

  static let excludedPreferenceKeys: Set<String> = [
    "activityEnablementMigrationVersion", "batteryEnabled", "clipboardEnabled",
    "clipboardClearHistoryOnPause", "clipboardExcludedBundleIdentifiers",
    "clipboardManuallyPaused", "clipboardPausedFocusIdentifiers", "clipboardPausedLoginSession",
    "clipboardPausedUntil",
    "commandPaletteRecentResultIDs", "commandPaletteShortcut", "contextManualOverride",
    "contextRules", "continuityEnabled", "hiddenCalendarIDs",
    "onboardingVersion", "portsEnabled", "pulseEnabled", "pulseHistoryMaximumEntries",
    "pulseHistoryPersistenceEnabled", "pulseHistoryRetentionDays", "pulseRevisionStateData",
    "systemEnabled", "t3CodeEnabled", "t3RemoteEnvironments",
  ]

  static func exportData(
    snapshot: SettingsTransferSnapshot, exportedAt: Date = Date()
  ) throws -> Data {
    let document: [String: Any] = [
      "format": formatIdentifier,
      "version": currentVersion,
      "exportedAt": ISO8601DateFormatter().string(from: exportedAt),
      "settings": dictionary(from: snapshot),
    ]
    return try JSONSerialization.data(
      withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
  }

  static func preview(
    data: Data, current: SettingsTransferSnapshot
  ) throws -> SettingsTransferPreview {
    guard data.count <= maximumDocumentBytes else {
      throw SettingsTransferError.documentTooLarge
    }
    let rawObject: Any
    do {
      rawObject = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw SettingsTransferError.corruptDocument
    }
    guard let document = rawObject as? [String: Any] else {
      throw SettingsTransferError.wrongFormat
    }
    guard let version = integer(document["version"]), version >= 1 else {
      throw SettingsTransferError.wrongFormat
    }
    guard version <= currentVersion else {
      throw SettingsTransferError.unsupportedVersion(version)
    }

    let rawSettings: [String: Any]
    if version == 1 {
      guard let preferences = document["preferences"] as? [String: Any] else {
        throw SettingsTransferError.missingSettings
      }
      rawSettings = migrateVersionOne(preferences)
    } else {
      guard document["format"] as? String == formatIdentifier else {
        throw SettingsTransferError.wrongFormat
      }
      guard let settings = document["settings"] as? [String: Any] else {
        throw SettingsTransferError.missingSettings
      }
      rawSettings = settings
    }

    let ignored = rawSettings.keys.filter { !portableKeys.contains($0) }.sorted()
    let patch = try decodePatch(rawSettings)
    let result = patch.applying(to: current)
    return SettingsTransferPreview(
      sourceVersion: version, patch: patch, result: result,
      changes: changes(from: current, to: result), ignoredKeys: ignored)
  }

  static func apply(
    _ preview: SettingsTransferPreview, using apply: (SettingsTransferPatch) -> Void
  ) {
    apply(preview.patch)
  }

  fileprivate static func contains(_ key: String, in patch: SettingsTransferPatch) -> Bool {
    switch key {
    case "appTheme": patch.appTheme != nil
    case "batteryGraphStyle": patch.batteryGraphStyle != nil
    case "mediaSourceMode": patch.mediaSourceMode != nil
    case "mediaPriorityList": patch.mediaPriorityList != nil
    case "excludedAudioOnlySourceBundleIdentifiers":
      patch.excludedAudioOnlySourceBundleIdentifiers != nil
    case "interactionMode": patch.interactionMode != nil
    case "hoverCollapseTimeout": patch.hoverCollapseTimeout != nil
    case "hapticsEnabled": patch.hapticsEnabled != nil
    case "hapticStrength": patch.hapticStrength != nil
    case "barrierPushDistance": patch.barrierPushDistance != nil
    case "energyMode": patch.energyMode != nil
    case "allowDisplaySleep": patch.allowDisplaySleep != nil
    case "keepAwakeWithLidClosed": patch.keepAwakeWithLidClosed != nil
    case "keepAwakeLowBatteryThreshold": patch.keepAwakeLowBatteryThreshold != nil
    case "hideFromScreenRecording": patch.hideFromScreenRecording != nil
    case "hudEnabled": patch.hudEnabled != nil
    case "hudStyle": patch.hudStyle != nil
    case "calendarEnabled": patch.calendarEnabled != nil
    case "calendarLeadMinutes": patch.calendarLeadMinutes != nil
    case "remindersEnabled": patch.remindersEnabled != nil
    case "showOnAllDisplays": patch.showOnAllDisplays != nil
    case "hideInFullscreen": patch.hideInFullscreen != nil
    case "launchAtLogin": patch.launchAtLogin != nil
    case "activityOrder": patch.activityOrder != nil
    case "disabledActivities": patch.disabledActivities != nil
    case "disabledEventSources": patch.disabledEventSources != nil
    case "systemAlwaysVisible": patch.systemAlwaysVisible != nil
    case "systemAutoPresentCPU": patch.systemAutoPresentCPU != nil
    case "systemAutoPresentThermal": patch.systemAutoPresentThermal != nil
    case "systemAutoPresentMemoryPressure": patch.systemAutoPresentMemoryPressure != nil
    case "systemAutoPresentLowDiskSpace": patch.systemAutoPresentLowDiskSpace != nil
    case "systemAutoPresentDiskThroughput": patch.systemAutoPresentDiskThroughput != nil
    case "systemAutoPresentNetworkThroughput": patch.systemAutoPresentNetworkThroughput != nil
    case "metricStyles": patch.metricStyles != nil
    case "processAttributionEnabled": patch.processAttributionEnabled != nil
    case "processCPUThreshold": patch.processCPUThreshold != nil
    case "processMemoryThreshold": patch.processMemoryThreshold != nil
    case "processDiskThresholdMBPerSecond": patch.processDiskThresholdMBPerSecond != nil
    case "processNetworkThresholdMBPerSecond": patch.processNetworkThresholdMBPerSecond != nil
    case "continuityAlwaysVisible": patch.continuityAlwaysVisible != nil
    case "continuitySneaks": patch.continuitySneaks != nil
    case "pulseStaleTimeout": patch.pulseStaleTimeout != nil
    default: false
    }
  }

  private static func dictionary(from value: SettingsTransferSnapshot) -> [String: Any] {
    [
      "appTheme": value.appTheme.rawValue,
      "batteryGraphStyle": value.batteryGraphStyle.rawValue,
      "mediaSourceMode": value.mediaSourceMode.rawValue,
      "mediaPriorityList": value.mediaPriorityList,
      "excludedAudioOnlySourceBundleIdentifiers":
        value.excludedAudioOnlySourceBundleIdentifiers,
      "interactionMode": value.interactionMode.rawValue,
      "hoverCollapseTimeout": value.hoverCollapseTimeout,
      "hapticsEnabled": value.hapticsEnabled,
      "hapticStrength": value.hapticStrength.rawValue,
      "barrierPushDistance": value.barrierPushDistance,
      "energyMode": value.energyMode.rawValue,
      "allowDisplaySleep": value.allowDisplaySleep,
      "keepAwakeWithLidClosed": value.keepAwakeWithLidClosed,
      "keepAwakeLowBatteryThreshold": value.keepAwakeLowBatteryThreshold,
      "hideFromScreenRecording": value.hideFromScreenRecording,
      "hudEnabled": value.hudEnabled,
      "hudStyle": value.hudStyle.rawValue,
      "calendarEnabled": value.calendarEnabled,
      "calendarLeadMinutes": value.calendarLeadMinutes,
      "remindersEnabled": value.remindersEnabled,
      "showOnAllDisplays": value.showOnAllDisplays,
      "hideInFullscreen": value.hideInFullscreen,
      "launchAtLogin": value.launchAtLogin,
      "activityOrder": value.activityOrder,
      "disabledActivities": value.disabledActivities,
      "disabledEventSources": value.disabledEventSources,
      "systemAlwaysVisible": value.systemAlwaysVisible,
      "systemAutoPresentCPU": value.systemAutoPresentCPU,
      "systemAutoPresentThermal": value.systemAutoPresentThermal,
      "systemAutoPresentMemoryPressure": value.systemAutoPresentMemoryPressure,
      "systemAutoPresentLowDiskSpace": value.systemAutoPresentLowDiskSpace,
      "systemAutoPresentDiskThroughput": value.systemAutoPresentDiskThroughput,
      "systemAutoPresentNetworkThroughput": value.systemAutoPresentNetworkThroughput,
      "metricStyles": value.metricStyles,
      "processAttributionEnabled": value.processAttributionEnabled,
      "processCPUThreshold": value.processCPUThreshold,
      "processMemoryThreshold": value.processMemoryThreshold,
      "processDiskThresholdMBPerSecond": value.processDiskThresholdMBPerSecond,
      "processNetworkThresholdMBPerSecond": value.processNetworkThresholdMBPerSecond,
      "continuityAlwaysVisible": value.continuityAlwaysVisible,
      "continuitySneaks": value.continuitySneaks,
      "pulseStaleTimeout": value.pulseStaleTimeout,
    ]
  }

  private static func migrateVersionOne(_ preferences: [String: Any]) -> [String: Any] {
    let aliases = [
      "theme": "appTheme",
      "interaction": "interactionMode",
      "hiddenActivities": "disabledActivities",
      "disabledEvents": "disabledEventSources",
    ]
    var migrated = preferences
    for (oldKey, newKey) in aliases where migrated[newKey] == nil {
      migrated[newKey] = migrated.removeValue(forKey: oldKey)
    }
    return migrated
  }

  private static func decodePatch(_ values: [String: Any]) throws -> SettingsTransferPatch {
    var patch = SettingsTransferPatch()
    patch.appTheme = try enumeration("appTheme", in: values, type: AppTheme.self)
    patch.batteryGraphStyle = try enumeration(
      "batteryGraphStyle", in: values, type: BatteryGraphStyle.self)
    patch.mediaSourceMode = try enumeration(
      "mediaSourceMode", in: values, type: MediaSourceMode.self)
    patch.mediaPriorityList = try stringArray("mediaPriorityList", in: values, unique: true)
    if let exclusions = try stringArray(
      "excludedAudioOnlySourceBundleIdentifiers", in: values, unique: true,
      maximumItems: SourceFilter.maximumAudioOnlyExclusions)
    {
      patch.excludedAudioOnlySourceBundleIdentifiers =
        SourceFilter.migratedAudioOnlyExclusions(exclusions)
    }
    patch.interactionMode = try enumeration(
      "interactionMode", in: values, type: InteractionMode.self)
    patch.hoverCollapseTimeout = try number(
      "hoverCollapseTimeout", in: values, range: 0.2...3.0)
    patch.hapticsEnabled = try boolean("hapticsEnabled", in: values)
    patch.hapticStrength = try enumeration("hapticStrength", in: values, type: HapticStrength.self)
    patch.barrierPushDistance = try number(
      "barrierPushDistance", in: values,
      range: PushDistanceScale.minimum...PushDistanceScale.maximum)
    patch.energyMode = try enumeration("energyMode", in: values, type: EnergyMode.self)
    patch.allowDisplaySleep = try boolean("allowDisplaySleep", in: values)
    patch.keepAwakeWithLidClosed = try boolean("keepAwakeWithLidClosed", in: values)
    patch.keepAwakeLowBatteryThreshold = try allowedInteger(
      "keepAwakeLowBatteryThreshold", in: values, allowed: [0, 10, 20, 30])
    patch.hideFromScreenRecording = try boolean("hideFromScreenRecording", in: values)
    patch.hudEnabled = try boolean("hudEnabled", in: values)
    patch.hudStyle = try enumeration("hudStyle", in: values, type: HUDStyle.self)
    patch.calendarEnabled = try boolean("calendarEnabled", in: values)
    patch.calendarLeadMinutes = try allowedInteger(
      "calendarLeadMinutes", in: values, allowed: [0, 5, 10, 15, 30, 60])
    patch.remindersEnabled = try boolean("remindersEnabled", in: values)
    patch.showOnAllDisplays = try boolean("showOnAllDisplays", in: values)
    patch.hideInFullscreen = try boolean("hideInFullscreen", in: values)
    patch.launchAtLogin = try boolean("launchAtLogin", in: values)
    patch.activityOrder = try stringArray("activityOrder", in: values, unique: true)
    patch.disabledActivities = try stringArray("disabledActivities", in: values, unique: true)
    patch.disabledEventSources = try stringArray("disabledEventSources", in: values, unique: true)
    patch.systemAlwaysVisible = try boolean("systemAlwaysVisible", in: values)
    patch.systemAutoPresentCPU = try boolean("systemAutoPresentCPU", in: values)
    patch.systemAutoPresentThermal = try boolean("systemAutoPresentThermal", in: values)
    patch.systemAutoPresentMemoryPressure = try boolean(
      "systemAutoPresentMemoryPressure", in: values)
    patch.systemAutoPresentLowDiskSpace = try boolean("systemAutoPresentLowDiskSpace", in: values)
    patch.systemAutoPresentDiskThroughput = try boolean(
      "systemAutoPresentDiskThroughput", in: values)
    patch.systemAutoPresentNetworkThroughput = try boolean(
      "systemAutoPresentNetworkThroughput", in: values)
    patch.metricStyles = try stringDictionary("metricStyles", in: values)
    patch.processAttributionEnabled = try boolean("processAttributionEnabled", in: values)
    patch.processCPUThreshold = try number("processCPUThreshold", in: values, range: 0.5...1)
    patch.processMemoryThreshold = try number("processMemoryThreshold", in: values, range: 0.5...1)
    patch.processDiskThresholdMBPerSecond = try number(
      "processDiskThresholdMBPerSecond", in: values, range: 5...500)
    patch.processNetworkThresholdMBPerSecond = try number(
      "processNetworkThresholdMBPerSecond", in: values, range: 1...500)
    patch.continuityAlwaysVisible = try boolean("continuityAlwaysVisible", in: values)
    patch.continuitySneaks = try boolean("continuitySneaks", in: values)
    patch.pulseStaleTimeout = try allowedInteger(
      "pulseStaleTimeout", in: values, allowed: [60, 300, 900, 1_800, 3_600]
    ).map(Double.init)
    return patch
  }

  private static func enumeration<T: RawRepresentable>(
    _ key: String, in values: [String: Any], type: T.Type
  ) throws -> T? where T.RawValue == String {
    guard let raw = values[key] else { return nil }
    guard let string = raw as? String, let value = T(rawValue: string) else {
      throw SettingsTransferError.invalidValue(key: key, expected: "a supported name")
    }
    return value
  }

  private static func boolean(_ key: String, in values: [String: Any]) throws -> Bool? {
    guard let raw = values[key] else { return nil }
    guard CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID(), let value = raw as? Bool else {
      throw SettingsTransferError.invalidValue(key: key, expected: "true or false")
    }
    return value
  }

  private static func number(
    _ key: String, in values: [String: Any], range: ClosedRange<Double>
  ) throws -> Double? {
    guard let raw = values[key] else { return nil }
    guard CFGetTypeID(raw as CFTypeRef) != CFBooleanGetTypeID(), let number = raw as? NSNumber
    else {
      throw SettingsTransferError.invalidValue(key: key, expected: "a number in \(range)")
    }
    let value = number.doubleValue
    guard value.isFinite, range.contains(value) else {
      throw SettingsTransferError.invalidValue(key: key, expected: "a number in \(range)")
    }
    return value
  }

  private static func allowedInteger(
    _ key: String, in values: [String: Any], allowed: Set<Int>
  ) throws -> Int? {
    guard let raw = values[key] else { return nil }
    guard let value = integer(raw), allowed.contains(value) else {
      throw SettingsTransferError.invalidValue(
        key: key, expected: "one of \(allowed.sorted().map(String.init).joined(separator: ", "))")
    }
    return value
  }

  private static func integer(_ raw: Any?) -> Int? {
    guard let raw, CFGetTypeID(raw as CFTypeRef) != CFBooleanGetTypeID(),
      let number = raw as? NSNumber
    else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double.rounded() == double else { return nil }
    return number.intValue
  }

  private static func stringArray(
    _ key: String, in values: [String: Any], unique: Bool,
    maximumItems: Int = maximumListItems
  ) throws -> [String]? {
    guard let raw = values[key] else { return nil }
    guard let array = raw as? [Any], array.allSatisfy({ $0 is String }) else {
      throw SettingsTransferError.invalidValue(key: key, expected: "an array of text values")
    }
    let result = array.compactMap { $0 as? String }
    guard result.count <= maximumItems,
      result.allSatisfy({
        !$0.isEmpty && $0.lengthOfBytes(using: .utf8) <= maximumTextBytes
      }),
      !unique || Set(result).count == result.count
    else {
      throw SettingsTransferError.invalidValue(
        key: key,
        expected:
          "at most \(maximumItems) unique, non-empty text values up to \(maximumTextBytes) bytes each"
      )
    }
    return result
  }

  private static func stringDictionary(
    _ key: String, in values: [String: Any]
  ) throws -> [String: String]? {
    guard let raw = values[key] else { return nil }
    guard let dictionary = raw as? [String: Any],
      dictionary.values.allSatisfy({ $0 is String })
    else {
      throw SettingsTransferError.invalidValue(key: key, expected: "an object with text values")
    }
    let result = dictionary.compactMapValues { $0 as? String }
    let metricKeys = Set(SystemMetricKind.allCases.map(\.rawValue))
    let styleNames = Set(MetricDisplayStyle.allCases.map(\.rawValue))
    guard Set(result.keys).isSubset(of: metricKeys),
      result.values.allSatisfy(styleNames.contains)
    else {
      throw SettingsTransferError.invalidValue(key: key, expected: "known metric and style names")
    }
    return result
  }

  private static func changes(
    from old: SettingsTransferSnapshot, to new: SettingsTransferSnapshot
  ) -> [SettingsTransferChange] {
    var changes: [SettingsTransferChange] = []
    func add<T: Equatable>(_ key: String, _ title: String, _ old: T, _ new: T) {
      guard old != new else { return }
      changes.append(
        SettingsTransferChange(
          key: key, title: title, oldValue: summary(old), newValue: summary(new)))
    }
    add("activityOrder", "Activity order", old.activityOrder, new.activityOrder)
    add("appTheme", "Theme", old.appTheme.rawValue, new.appTheme.rawValue)
    add("barrierPushDistance", "Push distance", old.barrierPushDistance, new.barrierPushDistance)
    add(
      "batteryGraphStyle", "Battery graph", old.batteryGraphStyle.rawValue,
      new.batteryGraphStyle.rawValue)
    add("calendarEnabled", "Calendar", old.calendarEnabled, new.calendarEnabled)
    add(
      "calendarLeadMinutes", "Calendar countdown", old.calendarLeadMinutes, new.calendarLeadMinutes)
    add(
      "continuityAlwaysVisible", "iPhone idle visibility", old.continuityAlwaysVisible,
      new.continuityAlwaysVisible)
    add("continuitySneaks", "iPhone alerts", old.continuitySneaks, new.continuitySneaks)
    add("disabledActivities", "Hidden activities", old.disabledActivities, new.disabledActivities)
    add(
      "disabledEventSources", "Disabled events", old.disabledEventSources, new.disabledEventSources)
    add("energyMode", "Energy mode", old.energyMode.rawValue, new.energyMode.rawValue)
    add("allowDisplaySleep", "Allow display sleep", old.allowDisplaySleep, new.allowDisplaySleep)
    add(
      "keepAwakeWithLidClosed", "Keep awake with lid closed",
      old.keepAwakeWithLidClosed, new.keepAwakeWithLidClosed)
    add(
      "keepAwakeLowBatteryThreshold", "Keep-awake battery stop",
      old.keepAwakeLowBatteryThreshold, new.keepAwakeLowBatteryThreshold)
    add(
      "excludedAudioOnlySourceBundleIdentifiers", "Excluded audio-only sources",
      old.excludedAudioOnlySourceBundleIdentifiers,
      new.excludedAudioOnlySourceBundleIdentifiers)
    add(
      "hapticStrength", "Haptic strength", old.hapticStrength.rawValue, new.hapticStrength.rawValue)
    add("hapticsEnabled", "Haptics", old.hapticsEnabled, new.hapticsEnabled)
    add(
      "hideFromScreenRecording", "Screen recording privacy", old.hideFromScreenRecording,
      new.hideFromScreenRecording)
    add("hideInFullscreen", "Fullscreen visibility", old.hideInFullscreen, new.hideInFullscreen)
    add(
      "hoverCollapseTimeout", "Collapse delay", old.hoverCollapseTimeout, new.hoverCollapseTimeout)
    add("hudEnabled", "System HUD", old.hudEnabled, new.hudEnabled)
    add("hudStyle", "HUD style", old.hudStyle.rawValue, new.hudStyle.rawValue)
    add(
      "interactionMode", "Interaction", old.interactionMode.rawValue, new.interactionMode.rawValue)
    add("launchAtLogin", "Launch at login", old.launchAtLogin, new.launchAtLogin)
    add("mediaPriorityList", "Player order", old.mediaPriorityList, new.mediaPriorityList)
    add(
      "mediaSourceMode", "Primary player", old.mediaSourceMode.rawValue,
      new.mediaSourceMode.rawValue)
    add("metricStyles", "System metrics", old.metricStyles, new.metricStyles)
    add(
      "processAttributionEnabled", "Process attribution", old.processAttributionEnabled,
      new.processAttributionEnabled)
    add(
      "processCPUThreshold", "CPU process threshold", old.processCPUThreshold,
      new.processCPUThreshold)
    add(
      "processMemoryThreshold", "Memory process threshold", old.processMemoryThreshold,
      new.processMemoryThreshold)
    add(
      "processDiskThresholdMBPerSecond", "Disk process threshold",
      old.processDiskThresholdMBPerSecond, new.processDiskThresholdMBPerSecond)
    add(
      "processNetworkThresholdMBPerSecond", "Network process threshold",
      old.processNetworkThresholdMBPerSecond, new.processNetworkThresholdMBPerSecond)
    add("pulseStaleTimeout", "Pulse stale timeout", old.pulseStaleTimeout, new.pulseStaleTimeout)
    add("remindersEnabled", "Reminders", old.remindersEnabled, new.remindersEnabled)
    add("showOnAllDisplays", "Display placement", old.showOnAllDisplays, new.showOnAllDisplays)
    add(
      "systemAlwaysVisible", "System idle visibility", old.systemAlwaysVisible,
      new.systemAlwaysVisible)
    add(
      "systemAutoPresentCPU", "System CPU presence", old.systemAutoPresentCPU,
      new.systemAutoPresentCPU)
    add(
      "systemAutoPresentDiskThroughput", "System disk activity presence",
      old.systemAutoPresentDiskThroughput, new.systemAutoPresentDiskThroughput)
    add(
      "systemAutoPresentLowDiskSpace", "System low disk presence",
      old.systemAutoPresentLowDiskSpace, new.systemAutoPresentLowDiskSpace)
    add(
      "systemAutoPresentMemoryPressure", "System memory presence",
      old.systemAutoPresentMemoryPressure, new.systemAutoPresentMemoryPressure)
    add(
      "systemAutoPresentNetworkThroughput", "System network presence",
      old.systemAutoPresentNetworkThroughput, new.systemAutoPresentNetworkThroughput)
    add(
      "systemAutoPresentThermal", "System thermal presence", old.systemAutoPresentThermal,
      new.systemAutoPresentThermal)
    return changes
  }

  private static func summary<T>(_ value: T) -> String {
    switch value {
    case let value as Bool: value ? "On" : "Off"
    case let value as Double: value.formatted(.number.precision(.fractionLength(0...2)))
    case let value as [String]: value.isEmpty ? "None" : value.joined(separator: ", ")
    case let value as [String: String]:
      value.isEmpty
        ? "Default"
        : value.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
    default: String(describing: value)
    }
  }
}

@MainActor
enum SettingsTransferDefaults {
  static func snapshot() -> SettingsTransferSnapshot {
    SettingsTransferSnapshot(
      appTheme: Defaults[.appTheme], batteryGraphStyle: Defaults[.batteryGraphStyle],
      mediaSourceMode: Defaults[.mediaSourceMode], mediaPriorityList: Defaults[.mediaPriorityList],
      excludedAudioOnlySourceBundleIdentifiers:
        SourceFilter.migratedAudioOnlyExclusions(
          Defaults[.excludedAudioOnlySourceBundleIdentifiers]),
      interactionMode: Defaults[.interactionMode],
      hoverCollapseTimeout: Defaults[.hoverCollapseTimeout],
      hapticsEnabled: Defaults[.hapticsEnabled], hapticStrength: Defaults[.hapticStrength],
      barrierPushDistance: Defaults[.barrierPushDistance], energyMode: Defaults[.energyMode],
      allowDisplaySleep: Defaults[.allowDisplaySleep],
      keepAwakeWithLidClosed: Defaults[.keepAwakeWithLidClosed],
      keepAwakeLowBatteryThreshold: Defaults[.keepAwakeLowBatteryThreshold],
      hideFromScreenRecording: Defaults[.hideFromScreenRecording],
      hudEnabled: Defaults[.hudEnabled],
      hudStyle: Defaults[.hudStyle], calendarEnabled: Defaults[.calendarEnabled],
      calendarLeadMinutes: Defaults[.calendarLeadMinutes],
      remindersEnabled: Defaults[.remindersEnabled],
      showOnAllDisplays: Defaults[.showOnAllDisplays],
      hideInFullscreen: Defaults[.hideInFullscreen],
      launchAtLogin: Defaults[.launchAtLogin], activityOrder: Defaults[.activityOrder],
      disabledActivities: Defaults[.disabledActivities],
      disabledEventSources: EventSourcePreferences.shared.disabledSourceIDs,
      systemAlwaysVisible: Defaults[.systemAlwaysVisible],
      systemAutoPresentCPU: Defaults[.systemAutoPresentCPU],
      systemAutoPresentThermal: Defaults[.systemAutoPresentThermal],
      systemAutoPresentMemoryPressure: Defaults[.systemAutoPresentMemoryPressure],
      systemAutoPresentLowDiskSpace: Defaults[.systemAutoPresentLowDiskSpace],
      systemAutoPresentDiskThroughput: Defaults[.systemAutoPresentDiskThroughput],
      systemAutoPresentNetworkThroughput: Defaults[.systemAutoPresentNetworkThroughput],
      metricStyles: Defaults[.metricStyles],
      processAttributionEnabled: Defaults[.processAttributionEnabled],
      processCPUThreshold: Defaults[.processCPUThreshold],
      processMemoryThreshold: Defaults[.processMemoryThreshold],
      processDiskThresholdMBPerSecond: Defaults[.processDiskThresholdMBPerSecond],
      processNetworkThresholdMBPerSecond: Defaults[.processNetworkThresholdMBPerSecond],
      continuityAlwaysVisible: Defaults[.continuityAlwaysVisible],
      continuitySneaks: Defaults[.continuitySneaks],
      pulseStaleTimeout: Defaults[.pulseStaleTimeout])
  }

  static func apply(_ patch: SettingsTransferPatch) {
    if let value = patch.appTheme { Defaults[.appTheme] = value }
    if let value = patch.batteryGraphStyle { Defaults[.batteryGraphStyle] = value }
    if let value = patch.mediaSourceMode { Defaults[.mediaSourceMode] = value }
    if let value = patch.mediaPriorityList { Defaults[.mediaPriorityList] = value }
    if let value = patch.excludedAudioOnlySourceBundleIdentifiers {
      Defaults[.excludedAudioOnlySourceBundleIdentifiers] = value
    }
    if let value = patch.interactionMode { Defaults[.interactionMode] = value }
    if let value = patch.hoverCollapseTimeout { Defaults[.hoverCollapseTimeout] = value }
    if let value = patch.hapticsEnabled { Defaults[.hapticsEnabled] = value }
    if let value = patch.hapticStrength { Defaults[.hapticStrength] = value }
    if let value = patch.barrierPushDistance { Defaults[.barrierPushDistance] = value }
    if let value = patch.energyMode { Defaults[.energyMode] = value }
    if let value = patch.allowDisplaySleep { Defaults[.allowDisplaySleep] = value }
    if let value = patch.keepAwakeWithLidClosed {
      Defaults[.keepAwakeWithLidClosed] = value
    }
    if let value = patch.keepAwakeLowBatteryThreshold {
      Defaults[.keepAwakeLowBatteryThreshold] = value
    }
    if let value = patch.hideFromScreenRecording { Defaults[.hideFromScreenRecording] = value }
    if let value = patch.hudEnabled { Defaults[.hudEnabled] = value }
    if let value = patch.hudStyle { Defaults[.hudStyle] = value }
    if let value = patch.calendarEnabled { Defaults[.calendarEnabled] = value }
    if let value = patch.calendarLeadMinutes { Defaults[.calendarLeadMinutes] = value }
    if let value = patch.remindersEnabled { Defaults[.remindersEnabled] = value }
    if let value = patch.showOnAllDisplays { Defaults[.showOnAllDisplays] = value }
    if let value = patch.hideInFullscreen { Defaults[.hideInFullscreen] = value }
    if let value = patch.launchAtLogin { Defaults[.launchAtLogin] = value }
    if let value = patch.activityOrder { Defaults[.activityOrder] = value }
    if let value = patch.disabledActivities { Defaults[.disabledActivities] = value }
    if let value = patch.disabledEventSources {
      EventSourcePreferences.shared.replaceDisabledSourceIDs(value)
    }
    if let value = patch.systemAlwaysVisible { Defaults[.systemAlwaysVisible] = value }
    if let value = patch.systemAutoPresentCPU { Defaults[.systemAutoPresentCPU] = value }
    if let value = patch.systemAutoPresentThermal { Defaults[.systemAutoPresentThermal] = value }
    if let value = patch.systemAutoPresentMemoryPressure {
      Defaults[.systemAutoPresentMemoryPressure] = value
    }
    if let value = patch.systemAutoPresentLowDiskSpace {
      Defaults[.systemAutoPresentLowDiskSpace] = value
    }
    if let value = patch.systemAutoPresentDiskThroughput {
      Defaults[.systemAutoPresentDiskThroughput] = value
    }
    if let value = patch.systemAutoPresentNetworkThroughput {
      Defaults[.systemAutoPresentNetworkThroughput] = value
    }
    if let value = patch.metricStyles { Defaults[.metricStyles] = value }
    if let value = patch.processAttributionEnabled { Defaults[.processAttributionEnabled] = value }
    if let value = patch.processCPUThreshold { Defaults[.processCPUThreshold] = value }
    if let value = patch.processMemoryThreshold { Defaults[.processMemoryThreshold] = value }
    if let value = patch.processDiskThresholdMBPerSecond {
      Defaults[.processDiskThresholdMBPerSecond] = value
    }
    if let value = patch.processNetworkThresholdMBPerSecond {
      Defaults[.processNetworkThresholdMBPerSecond] = value
    }
    if let value = patch.continuityAlwaysVisible { Defaults[.continuityAlwaysVisible] = value }
    if let value = patch.continuitySneaks { Defaults[.continuitySneaks] = value }
    if let value = patch.pulseStaleTimeout { Defaults[.pulseStaleTimeout] = value }
  }
}
