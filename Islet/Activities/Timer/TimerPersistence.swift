import Defaults
import Foundation

struct TimerSessionSnapshot: Codable, Equatable {
  static let schemaVersion = 1

  let version: Int
  let savedAt: Date
  let label: String?
  let duration: TimeInterval
  let deadline: Date?
  let isPaused: Bool
  let pausedRemaining: TimeInterval?
  let completionIdentifier: String?
  let completedAt: Date?

  init(
    savedAt: Date,
    label: String?,
    duration: TimeInterval,
    deadline: Date?,
    isPaused: Bool,
    pausedRemaining: TimeInterval?,
    completionIdentifier: String? = nil,
    completedAt: Date? = nil
  ) {
    version = Self.schemaVersion
    self.savedAt = savedAt
    self.label = label
    self.duration = duration
    self.deadline = deadline
    self.isPaused = isPaused
    self.pausedRemaining = pausedRemaining
    self.completionIdentifier = completionIdentifier
    self.completedAt = completedAt
  }
}

struct TimerPresetSnapshot: Codable, Equatable {
  static let schemaVersion = 1

  let version: Int
  let duration: TimeInterval
  let label: String?

  init(duration: TimeInterval, label: String?) {
    version = Self.schemaVersion
    self.duration = duration
    self.label = label
  }
}

enum TimerSessionRestoration: Equatable {
  case none
  case running(TimerSessionSnapshot)
  case paused(TimerSessionSnapshot)
  case completed(TimerSessionSnapshot)
  case discard
}

struct TimerPersistenceStore {
  let readSessionData: () -> Data?
  let writeSessionData: (Data?) -> Void
  let readPresetData: () -> Data?
  let writePresetData: (Data?) -> Void

  @MainActor
  static var defaults: Self {
    Self(
      readSessionData: { Defaults[.timerSessionData] },
      writeSessionData: { Defaults[.timerSessionData] = $0 },
      readPresetData: { Defaults[.timerLastPresetData] },
      writePresetData: { Defaults[.timerLastPresetData] = $0 })
  }
}

enum TimerPersistence {
  /// An unfinished timer older than this is more likely abandoned state than a countdown the user
  /// still expects to see. Explicit completed records remain until the user acknowledges them.
  static let maximumRecordAge: TimeInterval = 30 * 24 * 60 * 60
  static let maximumFutureClockSkew: TimeInterval = 5 * 60

  static func encode(_ session: TimerSessionSnapshot) -> Data? {
    try? JSONEncoder().encode(session)
  }

  static func encode(_ preset: TimerPresetSnapshot) -> Data? {
    try? JSONEncoder().encode(preset)
  }

  static func restoration(from data: Data?, now: Date) -> TimerSessionRestoration {
    guard let data else { return .none }
    guard
      now.timeIntervalSinceReferenceDate.isFinite,
      let session = try? JSONDecoder().decode(TimerSessionSnapshot.self, from: data),
      session.version == TimerSessionSnapshot.schemaVersion,
      session.savedAt.timeIntervalSinceReferenceDate.isFinite,
      session.savedAt <= now.addingTimeInterval(maximumFutureClockSkew),
      isValidDuration(session.duration)
    else {
      return .discard
    }

    if session.completionIdentifier != nil || session.completedAt != nil {
      guard
        !session.isPaused,
        session.pausedRemaining == nil,
        let deadline = session.deadline,
        deadline.timeIntervalSinceReferenceDate.isFinite,
        let identifier = session.completionIdentifier,
        !identifier.isEmpty,
        let completedAt = session.completedAt,
        completedAt.timeIntervalSinceReferenceDate.isFinite,
        deadline <= completedAt,
        completedAt <= now.addingTimeInterval(maximumFutureClockSkew)
      else {
        return .discard
      }
      return .completed(session)
    }

    guard now.timeIntervalSince(session.savedAt) <= maximumRecordAge else {
      return .discard
    }

    if session.isPaused {
      guard
        session.deadline == nil,
        let remaining = session.pausedRemaining,
        remaining.isFinite,
        remaining > 0,
        remaining <= session.duration
      else {
        return .discard
      }
      return .paused(session)
    }

    guard
      session.pausedRemaining == nil,
      let deadline = session.deadline,
      deadline.timeIntervalSinceReferenceDate.isFinite
    else {
      return .discard
    }
    let remainingWhenSaved = deadline.timeIntervalSince(session.savedAt)
    guard remainingWhenSaved > 0, remainingWhenSaved <= session.duration else {
      return .discard
    }
    return deadline <= now ? .completed(session) : .running(session)
  }

  static func preset(from data: Data?) -> TimerPresetSnapshot? {
    guard
      let data,
      let preset = try? JSONDecoder().decode(TimerPresetSnapshot.self, from: data),
      preset.version == TimerPresetSnapshot.schemaVersion,
      isValidDuration(preset.duration)
    else {
      return nil
    }
    return preset
  }

  @MainActor
  static func restoreSession(
    from store: TimerPersistenceStore,
    now: Date
  ) -> TimerSessionRestoration {
    let result = restoration(from: store.readSessionData(), now: now)
    switch result {
    case .discard:
      store.writeSessionData(nil)
    case .none, .running, .paused, .completed:
      break
    }
    return result
  }

  @MainActor
  static func restorePreset(from store: TimerPersistenceStore) -> TimerPresetSnapshot? {
    let data = store.readPresetData()
    guard let preset = preset(from: data) else {
      if data != nil { store.writePresetData(nil) }
      return nil
    }
    return preset
  }

  private static func isValidDuration(_ duration: TimeInterval) -> Bool {
    guard let validated = TimerLogic.validatedDuration(duration) else { return false }
    return validated == duration
  }
}
