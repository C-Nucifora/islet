import AppKit

struct DisplaySnapshot: Equatable {
  let stableID: String
  let legacyRuntimeID: String?
  let name: String
  let isBuiltin: Bool
  let isMain: Bool
  let mirrorGroupID: String
  let isUsable: Bool

  init(
    stableID: String, legacyRuntimeID: String?, name: String, isBuiltin: Bool, isMain: Bool,
    mirrorGroupID: String, isUsable: Bool = true
  ) {
    self.stableID = stableID
    self.legacyRuntimeID = legacyRuntimeID
    self.name = name
    self.isBuiltin = isBuiltin
    self.isMain = isMain
    self.mirrorGroupID = mirrorGroupID
    self.isUsable = isUsable
  }
}

struct ActionDisplayGeometry: Equatable {
  let stableID: String
  let bounds: CGRect
  let isMain: Bool
}

struct ActiveApplicationWindowSnapshot: Equatable {
  let ownerProcessIdentifier: pid_t
  let layer: Int
  let bounds: CGRect
}

enum ActiveApplicationDisplayResolver {
  /// Window Server returns windows from front to back. The first normal window owned by the active
  /// app decides the display. A spanning window uses its largest intersection, with main-display
  /// and stable-identifier tie breaks so equal overlaps never depend on screen enumeration order.
  static func targetID(
    processIdentifier: pid_t, windows: [ActiveApplicationWindowSnapshot],
    displays: [ActionDisplayGeometry]
  ) -> String? {
    guard processIdentifier > 0 else { return nil }

    for window in windows
    where window.ownerProcessIdentifier == processIdentifier && window.layer == 0
      && !window.bounds.isEmpty
    {
      let candidates = displays.compactMap {
        display -> (display: ActionDisplayGeometry, area: CGFloat)? in
        let intersection = window.bounds.intersection(display.bounds)
        guard !intersection.isNull, !intersection.isEmpty else { return nil }
        return (display, intersection.width * intersection.height)
      }
      .sorted { lhs, rhs in
        if lhs.area != rhs.area { return lhs.area > rhs.area }
        if lhs.display.isMain != rhs.display.isMain { return lhs.display.isMain }
        return lhs.display.stableID < rhs.display.stableID
      }

      if let target = candidates.first { return target.display.stableID }
    }
    return nil
  }
}

struct DisplayChoice: Equatable, Identifiable {
  let id: String
  let name: String
}

enum DisplaySelection {
  private static let legacyPrefixes = ["display:", "uuid:"]

  static func stableID(from rawUUID: String) -> String? {
    UUID(uuidString: rawUUID)?.uuidString
  }

  static func snapshots(from screens: [NSScreen] = NSScreen.screens) -> [DisplaySnapshot] {
    screens.compactMap(snapshot)
  }

  static func snapshot(from screen: NSScreen) -> DisplaySnapshot? {
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
      mirrorGroupID: mirrorGroupID,
      isUsable: CGDisplayIsOnline(displayID) != 0 && CGDisplayIsActive(displayID) != 0
        && CGDisplayIsAsleep(displayID) == 0)
  }

  static func choices(from displays: [DisplaySnapshot]) -> [DisplayChoice] {
    let unique = usableDisplays(displays)
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
    let unique = usableDisplays(displays)
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
    displayUnderPointerID: String?, activeApplicationDisplayID: String? = nil,
    hostedPanelIDs: Set<String>? = nil
  ) -> String? {
    let usable = usableDisplays(displays)
    let targets = targetIDs(
      showOnAllDisplays: showOnAllDisplays,
      storedPreference: storedPreference,
      displays: usable)
    let hosted = hostedPanelIDs ?? Set(targets)
    if hostedPanelIDs != nil, hosted != Set(targets) { return nil }
    let hostedTargets = targets.filter { hosted.contains($0) }
    guard !hostedTargets.isEmpty else { return nil }

    let byID = Dictionary(
      usable.map { ($0.stableID, $0) }, uniquingKeysWith: { first, _ in first })
    func hostedTarget(for candidateID: String?) -> String? {
      guard let candidateID, let candidate = byID[candidateID] else { return nil }
      if hostedTargets.contains(candidateID) { return candidateID }
      return hostedTargets.first {
        byID[$0]?.mirrorGroupID == candidate.mirrorGroupID
      }
    }

    let preferredID = resolvedPreferredID(
      storedPreference: storedPreference, displays: usable)
    let mainID = usable.filter(\.isMain).map(\.stableID).sorted().first
    var seen: Set<String> = []
    let candidates = [displayUnderPointerID, activeApplicationDisplayID, preferredID, mainID]
    for candidate in candidates {
      guard let candidate, seen.insert(candidate).inserted else { continue }
      if let target = hostedTarget(for: candidate) { return target }
    }

    // One-display mode has exactly one possible recipient. This covers #91's automatic built-in
    // fallback when no preferred display is configured, without adding an arbitrary fallback when
    // several panels exist.
    return hostedTargets.count == 1 ? hostedTargets[0] : nil
  }

  private static func usableDisplays(_ displays: [DisplaySnapshot]) -> [DisplaySnapshot] {
    uniqueDisplays(displays).filter(\.isUsable)
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
