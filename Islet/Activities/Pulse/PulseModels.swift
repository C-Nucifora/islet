import AppKit
import Foundation

enum PulsePriority: String, Codable, CaseIterable, Comparable, Sendable {
  case low
  case normal
  case high
  case critical

  private var rank: Int {
    switch self {
    case .low: 0
    case .normal: 1
    case .high: 2
    case .critical: 3
    }
  }

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

enum PulseState: String, Codable, Sendable {
  case active
  case progress
  case needsAction
  case succeeded
  case failed
  case cancelled
  /// Set by Islet after provider silence. Providers cannot set this state directly.
  case stale

  var receivesStaleDeadline: Bool {
    switch self {
    case .active, .progress, .needsAction: true
    case .succeeded, .failed, .cancelled, .stale: false
    }
  }
}

struct PulseStalenessPolicy: Equatable, Sendable {
  static let defaultTimeout: TimeInterval = 5 * 60
  static let defaultRetention: TimeInterval = 60 * 60

  let timeout: TimeInterval
  let retention: TimeInterval

  init(
    timeout: TimeInterval = Self.defaultTimeout,
    retention: TimeInterval = Self.defaultRetention
  ) {
    self.timeout = Self.validInterval(timeout, fallback: Self.defaultTimeout)
    self.retention = Self.validInterval(retention, fallback: Self.defaultRetention)
  }

  private static func validInterval(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
    value.isFinite && value > 0 ? value : fallback
  }
}

struct PulseAction: Codable, Equatable, Identifiable, Sendable {
  var id: String
  var title: String
  var url: URL

  init(id: String = UUID().uuidString, title: String, url: URL) {
    self.id = id
    self.title = title
    self.url = url
  }
}

/// The deliberately small wire payload accepted from local providers. Optional presentation fields
/// are normalised by `PulseItem.init(payload:now:)`, keeping the provider protocol forwards-compatible.
struct PulsePayload: Codable, Equatable, Sendable {
  var id: String
  var source: String
  var title: String
  var subtitle: String?
  var symbol: String?
  var accentHex: String?
  var progress: Double?
  var state: PulseState?
  var priority: PulsePriority?
  var expiresAt: Date?
  var actions: [PulseAction]?
}

struct PulseItem: Equatable, Identifiable, Sendable {
  static let maximumIdentifierLength = 128
  static let maximumActionURLLength = 2_048

  var id: String
  var source: String
  var title: String
  var subtitle: String?
  var symbol: String
  let symbolWarning: PulseSymbolWarning?
  var accentHex: String?
  var progress: Double?
  var state: PulseState
  var priority: PulsePriority
  var createdAt: Date
  var updatedAt: Date
  var expiresAt: Date?
  var staleAt: Date?
  var staleRemovalAt: Date?
  var isStaleKept: Bool
  var actions: [PulseAction]

  init(
    payload: PulsePayload, now: Date, previous: PulseItem? = nil,
    staleTimeout: TimeInterval = PulseStalenessPolicy.defaultTimeout,
    symbolAvailability: (String) -> Bool? = PulseSymbolValidator.platformAvailability
  ) throws {
    id = try Self.clean(payload.id, field: "id", limit: Self.maximumIdentifierLength)
    source = try Self.clean(payload.source, field: "source", limit: 80)
    title = try Self.clean(payload.title, field: "title", limit: 180)
    if let raw = payload.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
      guard raw.count <= 240 else { throw PulseValidationError.tooLong("subtitle", 240) }
      subtitle = raw
    } else {
      subtitle = nil
    }
    let normalizedSymbol = try PulseSymbolValidator.normalize(
      payload.symbol, availability: symbolAvailability)
    symbol = normalizedSymbol.name
    symbolWarning = normalizedSymbol.warning
    if let rawAccent = payload.accentHex {
      let candidate = rawAccent.trimmingCharacters(in: .whitespacesAndNewlines)
      guard Self.isValidAccentHex(candidate) else { throw PulseValidationError.invalidAccentHex }
      accentHex = candidate.uppercased()
    } else {
      accentHex = nil
    }
    if let value = payload.progress {
      guard value.isFinite, (0...1).contains(value) else {
        throw PulseValidationError.invalidProgress
      }
      progress = value
    } else {
      progress = nil
    }
    state = payload.state ?? (progress == nil ? .active : .progress)
    guard state != .stale else { throw PulseValidationError.providerSetStale }
    priority = payload.priority ?? .normal
    createdAt = previous?.createdAt ?? now
    updatedAt = now
    expiresAt = payload.expiresAt
    guard (expiresAt ?? now) >= now else { throw PulseValidationError.expired }
    let timeout = PulseStalenessPolicy(timeout: staleTimeout).timeout
    staleAt = state.receivesStaleDeadline ? now.addingTimeInterval(timeout) : nil
    staleRemovalAt = nil
    isStaleKept = false
    let incomingActions = payload.actions ?? []
    guard incomingActions.count <= 3 else { throw PulseValidationError.tooManyActions }
    actions = try incomingActions.map { action in
      let id = try Self.clean(
        action.id, field: "action id", limit: Self.maximumIdentifierLength)
      let title = try Self.clean(action.title, field: "action title", limit: 60)
      let urlString = action.url.absoluteString
      guard urlString.count <= Self.maximumActionURLLength else {
        throw PulseValidationError.tooLong("action URL", Self.maximumActionURLLength)
      }
      guard
        let components = URLComponents(url: action.url, resolvingAgainstBaseURL: false),
        let scheme = components.scheme?.lowercased(),
        ["http", "https"].contains(scheme),
        components.host?.isEmpty == false,
        components.user == nil,
        components.password == nil
      else { throw PulseValidationError.unsafeActionURL }
      return PulseAction(id: id, title: title, url: action.url)
    }
    guard Set(actions.map(\.id)).count == actions.count else {
      throw PulseValidationError.duplicateActionID
    }
  }

  static func normalizedIdentifier(_ value: String) throws -> String {
    try clean(value, field: "id", limit: maximumIdentifierLength)
  }

  static func normalizedSource(_ value: String) throws -> String {
    try clean(value, field: "source", limit: 80)
  }

  private static func clean(_ value: String, field: String, limit: Int) throws -> String {
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.isEmpty else { throw PulseValidationError.empty(field) }
    guard result.count <= limit else { throw PulseValidationError.tooLong(field, limit) }
    return result
  }

  private static func isValidAccentHex(_ value: String) -> Bool {
    guard value.count == 7, value.first == "#" else { return false }
    return value.dropFirst().unicodeScalars.allSatisfy { scalar in
      (48...57).contains(scalar.value) || (65...70).contains(scalar.value)
        || (97...102).contains(scalar.value)
    }
  }
}

struct PulseNormalizedSymbol: Equatable, Sendable {
  let name: String
  let warning: PulseSymbolWarning?
}

/// Pulse payloads use SF Symbol names. Keep the fallback in one place so every rejected name
/// renders a known-good icon instead of a blank image.
enum PulseSymbolValidator {
  static let fallbackSymbol = "waveform.path.ecg"

  static func normalize(
    _ rawSymbol: String?, availability: (String) -> Bool? = platformAvailability
  ) throws -> PulseNormalizedSymbol {
    guard let rawSymbol else {
      return PulseNormalizedSymbol(name: fallbackSymbol, warning: nil)
    }

    let candidate = rawSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else {
      return PulseNormalizedSymbol(name: fallbackSymbol, warning: .empty)
    }
    guard candidate.count <= 80 else { throw PulseValidationError.tooLong("symbol", 80) }
    guard let isAvailable = availability(candidate) else {
      return PulseNormalizedSymbol(name: fallbackSymbol, warning: .platformUnavailable)
    }
    guard isAvailable else {
      return PulseNormalizedSymbol(name: fallbackSymbol, warning: .invalid)
    }
    return PulseNormalizedSymbol(name: candidate, warning: nil)
  }

  static func platformAvailability(of symbolName: String) -> Bool? {
    NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) != nil
  }
}

enum PulseSymbolWarning: LocalizedError, Equatable, Sendable {
  case empty
  case invalid
  case platformUnavailable

  var errorDescription: String? {
    switch self {
    case .empty: "symbol was empty; using waveform.path.ecg"
    case .invalid: "symbol is not available on this macOS version; using waveform.path.ecg"
    case .platformUnavailable:
      "symbol validation is unavailable on this platform; using waveform.path.ecg"
    }
  }
}

enum PulseValidationError: LocalizedError, Equatable {
  case empty(String)
  case tooLong(String, Int)
  case invalidProgress
  case invalidAccentHex
  case expired
  case providerSetStale
  case tooManyActions
  case duplicateActionID
  case unsafeActionURL

  var errorDescription: String? {
    switch self {
    case .empty(let field): "\(field) must not be empty"
    case .tooLong(let field, let limit): "\(field) exceeds \(limit) characters"
    case .invalidProgress: "progress must be a finite number from 0 through 1"
    case .invalidAccentHex: "accentHex must use #RRGGBB format"
    case .expired: "expiresAt is already in the past"
    case .providerSetStale: "stale is an Islet-managed state"
    case .tooManyActions: "an activity may expose at most three actions"
    case .duplicateActionID: "action ids must be unique within an activity"
    case .unsafeActionURL: "action URLs must be http or https URLs without credentials"
    }
  }
}

enum PulseOperation: String, Codable, Sendable {
  case show
  case update
  case end
  case event
}

/// Persisted delivery rules. Providers still receive a successful response when a rule
/// suppresses an item, which lets focus modes remain an Islet concern rather than something each
/// integration has to understand.
enum PulseDeliveryProfile: String, CaseIterable, Codable, Identifiable, Sendable {
  case everything
  case focused
  case criticalOnly
  case paused

  var id: Self { self }

  var title: String {
    switch self {
    case .everything: "Everything"
    case .focused: "Focus"
    case .criticalOnly: "Critical only"
    case .paused: "Paused"
    }
  }

  var detail: String {
    switch self {
    case .everything: "Show every provider update"
    case .focused: "Show high-priority, failed, stale, and needs-action updates"
    case .criticalOnly: "Show only critical and failed updates"
    case .paused: "Keep the API available without showing new items"
    }
  }

  func allows(_ item: PulseItem) -> Bool {
    switch self {
    case .everything: true
    case .focused:
      item.priority >= .high || item.state == .failed || item.state == .needsAction
        || item.state == .stale
    case .criticalOnly:
      item.priority == .critical || item.state == .failed
    case .paused: false
    }
  }
}

enum PulseSourcePolicy: String, CaseIterable, Identifiable, Sendable {
  case allowed
  case muted
  case revoked

  var id: Self { self }
  var title: String {
    switch self {
    case .allowed: "Allow"
    case .muted: "Mute"
    case .revoked: "Revoke"
    }
  }

  var detail: String {
    switch self {
    case .allowed: "Accept and show matching updates"
    case .muted: "Accept state without showing it"
    case .revoked: "Reject updates from this source"
    }
  }
}

enum PulseHistoryResult: String, Sendable {
  case shown
  case updated
  case ended
  case dismissed
  case expired
  case stale
  case kept
  case suppressed
  case rejected
  case evicted

  var title: String {
    switch self {
    case .shown: "Shown"
    case .updated: "Updated"
    case .ended: "Ended"
    case .dismissed: "Dismissed"
    case .expired: "Expired"
    case .stale: "Stale"
    case .kept: "Kept"
    case .suppressed: "Filtered"
    case .rejected: "Rejected"
    case .evicted: "Evicted"
    }
  }
}

/// A deliberately payload-free audit record. Payload IDs, titles, subtitles, action labels/URLs,
/// tokens, and error text are never copied into history. The routing source and state metadata are
/// retained for provider health. The list is memory-only and disappears when Islet quits.
struct PulseHistoryEntry: Identifiable, Equatable, Sendable {
  let id: UUID
  let date: Date
  let operation: PulseOperation
  let source: String?
  let state: PulseState?
  let priority: PulsePriority?
  let result: PulseHistoryResult
}

enum PulseCapability: String, CaseIterable, Identifiable, Sendable {
  case events
  case progress
  case webActions

  var id: Self { self }
  var title: String {
    switch self {
    case .events: "Events"
    case .progress: "Progress"
    case .webActions: "Web links"
    }
  }
  var symbol: String {
    switch self {
    case .events: "sparkles"
    case .progress: "chart.bar.fill"
    case .webActions: "link"
    }
  }
}

/// Gallery metadata is bundled with Islet; providers remain out of process and require no plug-in
/// loading. `sourceIDs` are the stable wire-protocol sources used to compute local health.
struct PulseProviderDescriptor: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let summary: String
  let symbol: String
  let sourceIDs: Set<String>
  let capabilities: Set<PulseCapability>
  let setupHint: String

  static let gallery: [Self] = [
    .init(
      id: "shortcuts", name: "Shortcuts", summary: "Publish events without writing code.",
      symbol: "square.stack.3d.up.fill", sourceIDs: ["shortcuts"],
      capabilities: [.events], setupHint: "Add the Publish an Islet Pulse Event action."),
    .init(
      id: "cli", name: "Pulse CLI", summary: "Send progress and alerts from local scripts.",
      symbol: "terminal.fill", sourceIDs: ["cli"],
      capabilities: [.events, .progress, .webActions],
      setupHint: "Run Tools/islet-pulse.swift from this project."),
    .init(
      id: "github-actions", name: "GitHub workflow watcher",
      summary: "Shows GitHub run status observed on this Mac.",
      symbol: "shippingbox.fill", sourceIDs: ["github-actions", "github"],
      capabilities: [.events, .progress, .webActions],
      setupHint: "Run the watcher after gh auth login; Islet never receives your GitHub token."),
    .init(
      id: "xcode", name: "Xcode builds",
      summary: "Shows local xcodebuild and test progress.",
      symbol: "hammer.fill", sourceIDs: ["xcode"],
      capabilities: [.events, .progress, .webActions],
      setupHint: "Wrap xcodebuild with Tools/islet-xcode-pulse.swift."),
    .init(
      id: "chrome-downloads", name: "Chrome downloads",
      summary: "Shows browser download progress without retaining URLs or paths.",
      symbol: "arrow.down.circle.fill", sourceIDs: ["chrome-downloads"],
      capabilities: [.events, .progress, .webActions],
      setupHint: "Install the example Chrome extension and its local native host."),
    .init(
      id: "rclone", name: "rclone transfers",
      summary: "Shows file copies and uploads from rclone's loopback control API.",
      symbol: "arrow.up.arrow.down.circle.fill", sourceIDs: ["rclone"],
      capabilities: [.events, .progress, .webActions],
      setupHint: "Run the example provider beside an rclone process with RC enabled."),
    .init(
      id: "developer-tools", name: "Developer tools", summary: "Build, test, and agent status.",
      symbol: "wrench.and.screwdriver.fill", sourceIDs: ["build", "tests", "agent"],
      capabilities: [.events, .progress, .webActions],
      setupHint: "Use a stable source name from your local automation."),
  ]
}

enum PulseProviderHealth: Equatable, Sendable {
  case active(Int)
  case needsAttention(Int)
  case seen(Date)
  case neverSeen

  var summary: String {
    switch self {
    case .active(let count): "Active (\(count))"
    case .needsAttention(let count): "Needs attention (\(count))"
    case .seen: "Seen this session"
    case .neverSeen: "Not connected yet"
    }
  }
}

struct PulseProviderStatus: Identifiable, Equatable, Sendable {
  var id: String { descriptor.id }
  let descriptor: PulseProviderDescriptor
  let health: PulseProviderHealth
}

struct PulseCommand: Codable, Sendable {
  var token: String
  var operation: PulseOperation
  var activity: PulsePayload?
  var id: String?
  /// Optional correlation identifier. Multi-command clients should always set this and match it
  /// against the response instead of relying on response order.
  var requestID: String? = nil
  /// Optional source guard for `end`. Older clients may omit it, but providers should include it
  /// so an accidental identifier collision cannot end another source's item.
  var source: String? = nil
}

enum PulseErrorCode: String, Codable, Sendable {
  case featureDisabled
  case unauthorized
  case invalidCommand
  case validationFailed
  case sourceRevoked
  case identifierConflict
  case sourceMismatch
  case messageTooLarge
  case commandLimitExceeded
  case rateLimited
  case capacityExceeded
}

struct PulseResponse: Codable, Equatable, Sendable {
  var ok: Bool
  var id: String?
  var error: String?
  var warning: String? = nil
  var errorCode: PulseErrorCode? = nil
  var requestID: String? = nil

  static func success(
    id: String? = nil, warning: String? = nil, requestID: String? = nil
  ) -> Self {
    .init(ok: true, id: id, error: nil, warning: warning, requestID: requestID)
  }

  static func failure(
    _ error: String, code: PulseErrorCode = .validationFailed, requestID: String? = nil
  ) -> Self {
    .init(ok: false, id: nil, error: error, warning: nil, errorCode: code, requestID: requestID)
  }
}

/// Token-wide rolling-window protection. The per-connection cap bounds a single socket; this cap
/// also prevents a noisy local provider from resetting its allowance by reconnecting repeatedly.
struct PulseRateLimiter: Sendable {
  let limit: Int
  let window: TimeInterval
  private(set) var acceptedTimes: [TimeInterval] = []

  init(limit: Int = 512, window: TimeInterval = 60) {
    self.limit = limit
    self.window = window
  }

  mutating func accepts(_ now: TimeInterval) -> Bool {
    if let last = acceptedTimes.last, now < last {
      acceptedTimes.removeAll(keepingCapacity: true)
    }
    let cutoff = now - window
    acceptedTimes.removeAll { $0 <= cutoff }
    guard acceptedTimes.count < limit else { return false }
    acceptedTimes.append(now)
    return true
  }
}

enum PulseWireValidationError: LocalizedError, Equatable {
  case expectedObject(String)
  case invalidField(String)
  case unexpectedField(String)

  var errorDescription: String? {
    switch self {
    case .expectedObject(let path): "\(path) must be a JSON object"
    case .invalidField(let path): "invalid field: \(path)"
    case .unexpectedField(let path): "unexpected field: \(path)"
    }
  }
}

/// `Codable` intentionally ignores unknown keys, while the published schema disallows them. This
/// lightweight shape pass keeps the actual socket strict without ever copying payload values into
/// an error or diagnostic record.
enum PulseWireValidator {
  private static let commandFields: Set<String> = [
    "token", "operation", "activity", "id", "requestID", "source",
  ]
  private static let activityFields: Set<String> = [
    "id", "source", "title", "subtitle", "symbol", "accentHex", "progress", "state",
    "priority", "expiresAt", "actions",
  ]
  private static let actionFields: Set<String> = ["id", "title", "url"]

  static func validate(_ data: Data) throws {
    guard let command = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw PulseWireValidationError.expectedObject("command")
    }
    try rejectUnknown(in: command, allowed: commandFields, path: "command")
    if let requestID = command["requestID"] as? String,
      requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || requestID.count > PulseItem.maximumIdentifierLength
    {
      throw PulseWireValidationError.invalidField("command.requestID")
    }
    if let rawActivity = command["activity"] {
      guard let activity = rawActivity as? [String: Any] else {
        throw PulseWireValidationError.expectedObject("activity")
      }
      try rejectUnknown(in: activity, allowed: activityFields, path: "activity")
      if let rawActions = activity["actions"] as? [Any] {
        for (index, rawAction) in rawActions.enumerated() {
          guard let action = rawAction as? [String: Any] else {
            throw PulseWireValidationError.expectedObject("activity.actions[\(index)]")
          }
          try rejectUnknown(
            in: action, allowed: actionFields, path: "activity.actions[\(index)]")
        }
      }
    }
  }

  private static func rejectUnknown(
    in object: [String: Any], allowed: Set<String>, path: String
  ) throws {
    if let key = object.keys.filter({ !allowed.contains($0) }).sorted().first {
      throw PulseWireValidationError.unexpectedField("\(path).\(key)")
    }
  }
}

enum PulseWireCodec {
  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let standard = ISO8601DateFormatter()
      standard.formatOptions = [.withInternetDateTime]
      guard let date = fractional.date(from: value) ?? standard.date(from: value) else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "Invalid ISO 8601 date")
      }
      return date
    }
    return decoder
  }
}
