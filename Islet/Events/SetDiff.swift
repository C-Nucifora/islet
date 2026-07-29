import Foundation

/// What appeared and what disappeared between two snapshots.
///
/// USB devices, displays, Bluetooth peripherals and network interfaces are all the same question,
/// and four hand-rolled versions of it is three opportunities to get the first-read case wrong.
///
/// Deliberately actor-free: pure logic, so tests call it synchronously.
enum SetDiff {
  /// Results preserve the order of the array they came from, so callers can render device names in
  /// the order the system reported them rather than in hash order.
  static func changes<T: Hashable>(from old: [T], to new: [T]) -> (added: [T], removed: [T]) {
    let oldSet = Set(old)
    let newSet = Set(new)
    var seenAdded: Set<T> = []
    var seenRemoved: Set<T> = []
    let added = new.filter { !oldSet.contains($0) && seenAdded.insert($0).inserted }
    let removed = old.filter { !newSet.contains($0) && seenRemoved.insert($0).inserted }
    return (added, removed)
  }

  /// Compares by identity rather than by value: a device whose *description* changed — a USB device
  /// renegotiating its speed, a display renaming itself — is the same device, and must not produce a
  /// removal followed by an addition.
  static func changes<T: Identifiable>(from old: [T], to new: [T]) -> (added: [T], removed: [T])
  where T.ID: Hashable {
    let oldIDs = Set(old.map(\.id))
    let newIDs = Set(new.map(\.id))
    var seenAdded: Set<T.ID> = []
    var seenRemoved: Set<T.ID> = []
    let added = new.filter { !oldIDs.contains($0.id) && seenAdded.insert($0.id).inserted }
    let removed = old.filter { !newIDs.contains($0.id) && seenRemoved.insert($0.id).inserted }
    return (added, removed)
  }
}
