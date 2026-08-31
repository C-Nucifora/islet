import Combine
import Foundation

/// The persisted enablement state shared by Settings and every event-source lifecycle owner.
///
/// Disabled IDs are stored instead of enabled IDs so sources added by a later release start with
/// their declared default without rewriting choices for sources that already exist. Unknown IDs
/// are retained for the same reason when an older release reads preferences written by a newer one.
@MainActor
final class EventSourcePreferences: ObservableObject {
  nonisolated static let storageKey = "disabledEventSources"
  nonisolated static let defaultDisabledSourceIDs = ["airdropOut", "airdropIn", "focus", "vpn"]
  static let shared = EventSourcePreferences(defaults: .standard)

  @Published private(set) var disabledSourceIDs: [String]

  private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults

    let stored = defaults.stringArray(forKey: Self.storageKey)
    let normalized = Self.normalized(stored ?? Self.defaultDisabledSourceIDs)
    disabledSourceIDs = normalized

    // Repair duplicate or malformed persisted values once, before the bus starts any observer.
    if stored != normalized {
      persist(normalized)
    }
  }

  func isEnabled(_ sourceID: String) -> Bool {
    !disabledSourceIDs.contains(sourceID)
  }

  /// Re-reads a successful legacy import that had to write raw `UserDefaults` values. Normal app
  /// mutations and settings-file imports stay on the typed methods below.
  func reloadFromDefaults() {
    let stored = defaults.stringArray(forKey: Self.storageKey)
    let normalized = Self.normalized(stored ?? Self.defaultDisabledSourceIDs)
    if normalized != disabledSourceIDs {
      disabledSourceIDs = normalized
    }
    if stored != normalized {
      persist(normalized)
    }
  }

  /// Updates one ID without rebuilding the list from the catalogue. This preserves choices for
  /// every other source, including IDs this version does not know about.
  @discardableResult
  func setEnabled(_ enabled: Bool, for sourceID: String) -> Bool {
    var updated = disabledSourceIDs
    if enabled {
      updated.removeAll { $0 == sourceID }
    } else if !updated.contains(sourceID) {
      updated.append(sourceID)
    }
    return replaceDisabledSourceIDs(updated)
  }

  /// Used by validated settings imports. All other writes should go through `setEnabled` so one
  /// toggle cannot overwrite a newer choice for another source.
  @discardableResult
  func replaceDisabledSourceIDs(_ sourceIDs: [String]) -> Bool {
    let normalized = Self.normalized(sourceIDs)
    guard normalized != disabledSourceIDs else { return false }
    disabledSourceIDs = normalized
    persist(normalized)
    return true
  }

  /// Forces the current domain to disk before AppKit finishes terminating the process.
  @discardableResult
  func flush() -> Bool {
    defaults.synchronize()
  }

  private func persist(_ sourceIDs: [String]) {
    defaults.set(sourceIDs, forKey: Self.storageKey)
    defaults.synchronize()
  }

  private static func normalized(_ sourceIDs: [String]) -> [String] {
    var seen = Set<String>()
    return sourceIDs.compactMap { sourceID in
      let trimmed = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
      return !trimmed.isEmpty && seen.insert(trimmed).inserted ? trimmed : nil
    }
  }
}
