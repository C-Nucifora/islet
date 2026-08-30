import AppKit

/// Everything ScreenManager needs to host one island, detached from NSScreen identity. Tests feed
/// synthetic descriptors into ScreenTopologyController, so display changes never require hardware.
struct ScreenDescriptor: Equatable {
  let snapshot: DisplaySnapshot
  let hardwareIdentity: DisplayHardwareIdentity?
  let geometry: NotchGeometry

  var id: String { snapshot.stableID }
  var managedDisplay: ManagedDisplay {
    ManagedDisplay(id: id, hardwareIdentity: hardwareIdentity)
  }

  /// Names and main-display status affect selection and Settings, but do not require a new panel.
  func requiresPanelReplacement(comparedTo previous: ScreenDescriptor) -> Bool {
    geometry != previous.geometry || hardwareIdentity != previous.hardwareIdentity
  }
}

@MainActor
protocol ScreenDescriptorProviding: AnyObject {
  func currentDescriptors() -> [ScreenDescriptor]
}

/// Converts AppKit's current screens to stable, testable descriptors. Notch readings are used only
/// for the built-in display. Every external display receives a centred synthetic notch at its top
/// edge, even if AppKit reports transient safe-area values during display reconfiguration.
@MainActor
final class AppKitScreenDescriptorProvider: ScreenDescriptorProviding {
  private var stickiness = NotchStickiness()

  func currentDescriptors() -> [ScreenDescriptor] {
    NSScreen.screens.compactMap { screen in
      guard let snapshot = DisplaySelection.snapshot(from: screen) else { return nil }
      let raw = screen.notchReading
      let reading = stickiness.resolve(
        displayUUID: snapshot.stableID, isBuiltin: screen.isBuiltin, reading: raw)
      if screen.isBuiltin, reading != raw {
        let kept =
          "safeAreaTop \(reading.safeAreaTop) aux \(reading.auxLeftWidth)/\(reading.auxRightWidth)"
        Log.app.notice(
          "Display \(snapshot.stableID, privacy: .public) reported no notch; keeping \(kept, privacy: .public)"
        )
      }
      return ScreenDescriptor(
        snapshot: snapshot,
        hardwareIdentity: screen.displayHardwareIdentity,
        geometry: DisplayGeometryPolicy.geometry(
          screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
          isBuiltin: screen.isBuiltin, notchReading: reading))
    }
  }
}

enum DisplayGeometryPolicy {
  static func geometry(
    screenFrame: CGRect, visibleFrame: CGRect, isBuiltin: Bool,
    notchReading: NotchStickiness.Reading
  ) -> NotchGeometry {
    let reading =
      isBuiltin
      ? notchReading
      : NotchStickiness.Reading(safeAreaTop: 0, auxLeftWidth: 0, auxRightWidth: 0)
    return NotchGeometry(
      screenFrame: screenFrame,
      safeAreaTop: reading.safeAreaTop,
      auxLeftWidth: reading.auxLeftWidth,
      auxRightWidth: reading.auxRightWidth,
      menuBarHeight: screenFrame.maxY - visibleFrame.maxY)
  }
}

struct ScreenTopologyTransition: Equatable {
  let descriptors: [ScreenDescriptor]
  let addedIDs: Set<String>
  let removedIDs: Set<String>
  let reconfiguredIDs: Set<String>

  var panelIDs: [String] { descriptors.map(\.id) }
  var replacementIDs: Set<String> { addedIDs.union(reconfiguredIDs) }
}

/// Stable-ID topology diffing. The provider is injected so the entire connect, disconnect,
/// duplicate-notification and arrangement-change path can run against synthetic screens.
@MainActor
struct ScreenTopologyController {
  let provider: any ScreenDescriptorProviding
  private var previousByID: [String: ScreenDescriptor] = [:]

  init(provider: any ScreenDescriptorProviding) {
    self.provider = provider
  }

  mutating func reconcile(
    showOnAllDisplays: Bool, storedPreference: String
  ) -> ScreenTopologyTransition {
    reconcile(
      showOnAllDisplays: showOnAllDisplays,
      storedPreference: storedPreference,
      descriptors: provider.currentDescriptors())
  }

  mutating func reconcile(
    showOnAllDisplays: Bool, storedPreference: String, descriptors supplied: [ScreenDescriptor]
  ) -> ScreenTopologyTransition {
    var seen: Set<String> = []
    let unique = supplied.filter { seen.insert($0.id).inserted }
    let byID = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, $0) })
    let targetIDs = DisplaySelection.targetIDs(
      showOnAllDisplays: showOnAllDisplays,
      storedPreference: storedPreference,
      displays: unique.map(\.snapshot))
    let targets = targetIDs.compactMap { byID[$0] }
    let nextByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
    let previousIDs = Set(previousByID.keys)
    let nextIDs = Set(nextByID.keys)
    let retainedIDs = previousIDs.intersection(nextIDs)
    let reconfiguredIDs = Set(
      retainedIDs.filter { id in
        guard let previous = previousByID[id], let next = nextByID[id] else { return false }
        return next.requiresPanelReplacement(comparedTo: previous)
      })

    previousByID = nextByID
    return ScreenTopologyTransition(
      descriptors: targets,
      addedIDs: nextIDs.subtracting(previousIDs),
      removedIDs: previousIDs.subtracting(nextIDs),
      reconfiguredIDs: reconfiguredIDs)
  }

  mutating func reset() {
    previousByID = [:]
  }
}
