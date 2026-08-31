import Foundation

enum T3EnvironmentResolver {
  static func resolve(
    _ candidates: [T3EnvironmentSnapshot]
  ) -> [T3EnvironmentSnapshot] {
    var winners: [LogicalKey: T3EnvironmentSnapshot] = [:]
    for candidate in candidates {
      let key = logicalKey(for: candidate)
      guard let winner = winners[key] else {
        winners[key] = candidate
        continue
      }
      if isPreferred(candidate, over: winner) { winners[key] = candidate }
    }
    return winners.values.sorted(by: isOrderedBefore)
  }

  private enum LogicalKey: Hashable {
    case environment(String)
    case provisionalLocal
  }

  private static func logicalKey(for candidate: T3EnvironmentSnapshot) -> LogicalKey {
    if candidate.source == .local, candidate.id == "local" { return .provisionalLocal }
    return .environment(candidate.logicalEnvironmentID)
  }

  private static func isPreferred(
    _ candidate: T3EnvironmentSnapshot,
    over winner: T3EnvironmentSnapshot
  ) -> Bool {
    let candidateRank = preferenceRank(candidate)
    let winnerRank = preferenceRank(winner)
    if candidateRank != winnerRank { return candidateRank < winnerRank }
    return candidate.id < winner.id
  }

  private static func preferenceRank(_ candidate: T3EnvironmentSnapshot) -> Int {
    let connectionOffset = candidate.state == .connected ? 0 : 3
    return connectionOffset + sourceRank(candidate.source)
  }

  private static func sourceRank(_ source: T3EnvironmentSource) -> Int {
    switch source {
    case .local: 0
    case .connect: 1
    case .manual: 2
    }
  }

  private static func isOrderedBefore(
    _ lhs: T3EnvironmentSnapshot,
    _ rhs: T3EnvironmentSnapshot
  ) -> Bool {
    if lhs.isLocal != rhs.isLocal { return lhs.isLocal }
    let labelOrder = lhs.label.localizedCaseInsensitiveCompare(rhs.label)
    if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
    if lhs.logicalEnvironmentID != rhs.logicalEnvironmentID {
      return lhs.logicalEnvironmentID < rhs.logicalEnvironmentID
    }
    return lhs.id < rhs.id
  }
}
