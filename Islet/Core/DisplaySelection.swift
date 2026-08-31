import AppKit

struct DisplaySnapshot: Equatable {
  let stableID: String
  let legacyRuntimeID: String?
  let name: String
  let isBuiltin: Bool
  let isMain: Bool
  let mirrorGroupID: String
}

struct DisplayChoice: Equatable, Identifiable {
  let id: String
  let name: String
}

struct ScreenManagerDisplayTransition: Equatable {
  let panelIDs: [String]
  let addedIDs: Set<String>
  let removedIDs: Set<String>
}

struct ScreenManagerDisplayState {
  private(set) var panelIDs: [String] = []

  mutating func reconcile(
    showOnAllDisplays: Bool, storedPreference: String, displays: [DisplaySnapshot]
  ) -> ScreenManagerDisplayTransition {
    let nextIDs = DisplaySelection.targetIDs(
      showOnAllDisplays: showOnAllDisplays,
      storedPreference: storedPreference,
      displays: displays)
    let previous = Set(panelIDs)
    let next = Set(nextIDs)
    panelIDs = nextIDs
    return ScreenManagerDisplayTransition(
      panelIDs: nextIDs,
      addedIDs: next.subtracting(previous),
      removedIDs: previous.subtracting(next))
  }

  mutating func reset() {
    panelIDs = []
  }
}

enum DisplaySelection {
  private static let legacyPrefixes = ["display:", "uuid:"]

  static func stableID(from rawUUID: String) -> String? {
    UUID(uuidString: rawUUID)?.uuidString
  }

  static func snapshots(from screens: [NSScreen] = NSScreen.screens) -> [DisplaySnapshot] {
    screens.compactMap { screen -> DisplaySnapshot? in
      guard
        let displayID = screen.displayID,
        let stableID = screen.displayUUID.flatMap(Self.stableID)
      else { return nil }

      let mirroredDisplayID = CGDisplayMirrorsDisplay(displayID)
      let mirrorGroupID: String
      if mirroredDisplayID != kCGNullDirectDisplay,
        let mirroredUUID = CGDisplayCreateUUIDFromDisplayID(mirroredDisplayID)?.takeRetainedValue(),
        let mirroredStableID = Self.stableID(
          from: CFUUIDCreateString(nil, mirroredUUID) as String)
      {
        mirrorGroupID = mirroredStableID
      } else {
        mirrorGroupID = stableID
      }

      return DisplaySnapshot(
        stableID: stableID,
        legacyRuntimeID: String(displayID),
        name: screen.localizedName,
        isBuiltin: screen.isBuiltin,
        isMain: displayID == CGMainDisplayID(),
        mirrorGroupID: mirrorGroupID)
    }
  }

  static func choices(from displays: [DisplaySnapshot]) -> [DisplayChoice] {
    let unique = uniqueDisplays(displays)
    let groups = Dictionary(grouping: unique, by: normalizedName)
    let nameCounts = groups.mapValues(\.count)
    let duplicateIndexes = Dictionary(
      uniqueKeysWithValues: groups.flatMap { _, group in
        group.sorted { $0.stableID < $1.stableID }.enumerated().map { displayIndex, display in
          (display.stableID, displayIndex + 1)
        }
      })

    return unique.map { display in
      let name = cleanName(display.name)
      let normalized = normalizedName(display)
      if nameCounts[normalized, default: 0] > 1 {
        return DisplayChoice(
          id: display.stableID,
          name: "\(name) \(duplicateIndexes[display.stableID, default: 1])")
      }
      return DisplayChoice(id: display.stableID, name: name)
    }
  }

  /// Returns the stable UUID represented by a current or older preference shape.
  static func resolvedPreferredID(
    storedPreference: String, displays: [DisplaySnapshot]
  ) -> String? {
    let raw = storedPreference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }

    if let canonical = stableID(from: raw) { return canonical }
    var legacyValue = raw
    for prefix in legacyPrefixes where raw.lowercased().hasPrefix(prefix) {
      legacyValue = String(raw.dropFirst(prefix.count))
      if let canonical = stableID(from: legacyValue) { return canonical }
      break
    }

    let unique = uniqueDisplays(displays)
    if let runtimeMatch = unique.first(where: { $0.legacyRuntimeID == legacyValue }) {
      return runtimeMatch.stableID
    }

    let nameMatches = unique.filter {
      cleanName($0.name).compare(
        legacyValue, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
    return nameMatches.count == 1 ? nameMatches[0].stableID : nil
  }

  /// A migration is written only when the older value can be mapped without guessing. An
  /// unavailable or ambiguous preference stays untouched so a later reconnect can resolve it.
  static func migratedPreference(
    storedPreference: String, displays: [DisplaySnapshot]
  ) -> String? {
    guard
      let resolved = resolvedPreferredID(
        storedPreference: storedPreference, displays: displays),
      resolved != storedPreference
    else { return nil }
    return resolved
  }

  static func targetIDs(
    showOnAllDisplays: Bool, storedPreference: String, displays: [DisplaySnapshot]
  ) -> [String] {
    let unique = uniqueDisplays(displays)
    guard !unique.isEmpty else { return [] }

    if showOnAllDisplays {
      var seenMirrorGroups: Set<String> = []
      return unique.compactMap { display in
        guard seenMirrorGroups.insert(display.mirrorGroupID).inserted else { return nil }
        return display.stableID
      }
    }

    if let preferredID = resolvedPreferredID(
      storedPreference: storedPreference, displays: unique),
      unique.contains(where: { $0.stableID == preferredID })
    {
      return [preferredID]
    }
    if let builtin = unique.first(where: \.isBuiltin) { return [builtin.stableID] }
    if let main = unique.first(where: \.isMain) { return [main.stableID] }
    return [unique[0].stableID]
  }

  static func actionTargetID(
    showOnAllDisplays: Bool, storedPreference: String, displays: [DisplaySnapshot],
    displayUnderPointerID: String?
  ) -> String? {
    let targets = targetIDs(
      showOnAllDisplays: showOnAllDisplays,
      storedPreference: storedPreference,
      displays: displays)
    if showOnAllDisplays, let displayUnderPointerID, targets.contains(displayUnderPointerID) {
      return displayUnderPointerID
    }
    return targets.first
  }

  private static func uniqueDisplays(_ displays: [DisplaySnapshot]) -> [DisplaySnapshot] {
    var seen: Set<String> = []
    return displays.filter { seen.insert($0.stableID).inserted }
  }

  private static func normalizedName(_ display: DisplaySnapshot) -> String {
    cleanName(display.name).folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }

  private static func cleanName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Display" : trimmed
  }
}
