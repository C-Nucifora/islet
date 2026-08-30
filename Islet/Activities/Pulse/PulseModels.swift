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

  var destination: PulseActionDestination? { try? PulseActionDestination.validate(url) }
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

enum PulseRevision {
  /// JSON integers above 2^53 - 1 are not represented exactly by every provider runtime.
  static let maximum: UInt64 = 9_007_199_254_740_991

  static func validate(_ value: UInt64?) throws {
    guard let value else { return }
    guard value <= maximum else { throw PulseValidationError.invalidRevision }
  }
}

struct PulseItem: Equatable, Identifiable, Sendable {
  struct ID: Equatable, Hashable, Sendable {
    let normalizedSource: String
    let providerIdentifier: String

    init(source: String, providerIdentifier: String) throws {
      normalizedSource = try PulseItem.normalizedSourceKey(source)
      self.providerIdentifier = try PulseItem.normalizedIdentifier(providerIdentifier)
    }

    var stableIdentifier: String {
      "\(normalizedSource.utf8.count):\(normalizedSource)\(providerIdentifier)"
    }
  }

  static let maximumIdentifierLength = 128
  static let maximumActionURLLength = 2_048

  let id: ID
  let providerIdentity: PulseProviderIdentity
  var providerIdentifier: String
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
    providerIdentity suppliedProviderIdentity: PulseProviderIdentity? = nil,
    staleTimeout: TimeInterval = PulseStalenessPolicy.defaultTimeout,
    symbolAvailability: (String) -> Bool? = PulseSymbolValidator.platformAvailability
  ) throws {
    providerIdentifier = try Self.normalizedIdentifier(payload.id)
    source = try Self.normalizedSource(payload.source)
    id = try ID(source: source, providerIdentifier: providerIdentifier)
    providerIdentity =
      try suppliedProviderIdentity
      ?? PulseProviderIdentity(credentialID: "source-local", source: source)
    guard providerIdentity.sourceKey == id.normalizedSource else {
      throw PulseValidationError.unsafeProviderIdentity
    }
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
      let id = try Self.cleanIdentity(
        action.id, field: "action id", byteLimit: Self.maximumIdentifierLength)
      let title = try Self.clean(action.title, field: "action title", limit: 60)
      _ = try PulseActionDestination.validate(action.url)
      return PulseAction(id: id, title: title, url: action.url)
    }
    guard Set(actions.map(\.id)).count == actions.count else {
      throw PulseValidationError.duplicateActionID
    }
  }

  static func normalizedIdentifier(_ value: String) throws -> String {
    try cleanIdentity(value, field: "id", byteLimit: maximumIdentifierLength)
  }

  static func normalizedSource(_ value: String) throws -> String {
    try cleanIdentity(value, field: "source", byteLimit: 80)
  }

  static func normalizedSourceKey(_ value: String) throws -> String {
    try normalizedSource(value).lowercased()
  }

  private static func clean(_ value: String, field: String, limit: Int) throws -> String {
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.isEmpty else { throw PulseValidationError.empty(field) }
    guard result.count <= limit else { throw PulseValidationError.tooLong(field, limit) }
    return result
  }

  private static func cleanIdentity(_ value: String, field: String, byteLimit: Int) throws
    -> String
  {
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.isEmpty else { throw PulseValidationError.empty(field) }
    guard result.utf8.count <= byteLimit else {
      throw PulseValidationError.tooLongUTF8(field, byteLimit)
    }
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
  case tooLongUTF8(String, Int)
  case invalidProgress
  case invalidAccentHex
  case expired
  case providerSetStale
  case tooManyActions
  case duplicateActionID
  case unsafeActionURL
  case invalidRevision
  case unsafeProviderIdentity

  var errorDescription: String? {
    switch self {
    case .empty(let field): "\(field) must not be empty"
    case .tooLong(let field, let limit): "\(field) exceeds \(limit) characters"
    case .tooLongUTF8(let field, let limit): "\(field) exceeds \(limit) UTF-8 bytes"
    case .invalidProgress: "progress must be a finite number from 0 through 1"
    case .invalidAccentHex: "accentHex must use #RRGGBB format"
    case .expired: "expiresAt is already in the past"
    case .providerSetStale: "stale is an Islet-managed state"
    case .tooManyActions: "an activity may expose at most three actions"
    case .duplicateActionID: "action ids must be unique within an activity"
    case .unsafeActionURL:
      "action URLs must use an unambiguous HTTP or HTTPS host without credentials or controls"
    case .invalidRevision: "revision must be an integer from 0 through \(PulseRevision.maximum)"
    case .unsafeProviderIdentity: "the action provider identity does not match its source"
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

enum PulseHistoryResult: String, Codable, Sendable {
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

/// A bounded audit record. A validated provider-local identifier may be retained for session-only
/// presentation, but persistence and export remove it. Titles, subtitles, action labels and URLs,
/// tokens, unvalidated identifiers, and error text are never copied into history.
struct PulseHistoryEntry: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let date: Date
  let operation: PulseOperation
  let source: String?
  let providerIdentifier: String?
  let state: PulseState?
  let priority: PulsePriority?
  let result: PulseHistoryResult
}

enum PulseCapability: String, CaseIterable, Identifiable, Sendable {
  case events
  case persistentActivities
  case progress
  case webActions

  var id: Self { self }
  var title: String {
    switch self {
    case .events: "Events"
    case .persistentActivities: "Persistent activities"
    case .progress: "Progress"
    case .webActions: "Web links"
    }
  }
  var symbol: String {
    switch self {
    case .events: "sparkles"
    case .persistentActivities: "rectangle.stack.fill"
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
  let documentationLinks: [PulseProviderDocumentationLink]

  init(
    id: String, name: String, summary: String, symbol: String, sourceIDs: Set<String>,
    capabilities: Set<PulseCapability>, setupHint: String,
    documentationLinks: [PulseProviderDocumentationLink] = []
  ) {
    self.id = id
    self.name = name
    self.summary = summary
    self.symbol = symbol
    self.sourceIDs = sourceIDs
    self.capabilities = capabilities
    self.setupHint = setupHint
    self.documentationLinks = documentationLinks
  }

  static let gallery: [Self] = [
    .init(
      id: "shortcuts", name: "Shortcuts", summary: "Publish events without writing code.",
      symbol: "square.stack.3d.up.fill", sourceIDs: ["shortcuts"],
      capabilities: [.events, .progress],
      setupHint: "Import a starter shortcut or add an Islet action.",
      documentationLinks: PulseProviderDocumentationLink.shortcutStarterKit),
    .init(
      id: "cli", name: "Pulse CLI", summary: "Send progress and alerts from local scripts.",
      symbol: "terminal.fill", sourceIDs: ["cli"],
      capabilities: [.events, .persistentActivities, .progress, .webActions],
      setupHint: "Run Tools/islet-pulse.swift from this project."),
    .init(
      id: "github-actions", name: "GitHub workflow watcher",
      summary: "Shows GitHub run status observed on this Mac.",
      symbol: "shippingbox.fill", sourceIDs: ["github-actions", "github"],
      capabilities: [.events, .persistentActivities, .progress, .webActions],
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
      capabilities: [.events, .persistentActivities, .progress, .webActions],
      setupHint: "Use a stable source name from your local automation."),
  ]
}

struct PulseProviderDocumentationLink: Identifiable, Equatable, Sendable {
  let title: String
  let url: URL

  var id: String { url.absoluteString }

  static let shortcutStarterKit: [Self] = [
    link("Transient event", "01-transient-event"),
    link("Progress task", "02-progress-task"),
    link("Failed task", "03-failed-task"),
    link("Guarded completion", "04-guarded-completion"),
    link("Focus profile", "05-focus-profile"),
    link("Focus timer", "06-focus-timer"),
  ]

  private static func link(_ title: String, _ filename: String) -> Self {
    let baseURL =
      "https://raw.githubusercontent.com/C-Nucifora/islet/main/Integrations/Pulse/shortcuts"
    return Self(title: title, url: URL(string: "\(baseURL)/\(filename).shortcut")!)
  }
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
    case .seen: "Seen before"
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
  /// to select the provider namespace. An unscoped end is rejected when more than one source owns
  /// the identifier.
  var source: String? = nil
  /// Optional ordering value scoped to the normalized source and provider-local identifier.
  /// Once a stream sends one, every later command for that identity must include a larger value.
  var revision: UInt64? = nil
}

enum PulseErrorCode: String, Codable, Sendable {
  case featureDisabled
  case unauthorized
  case credentialRevoked
  case permissionDenied
  case requestIDRequired
  case replayedRequest
  case invalidCommand
  case validationFailed
  case sourceRevoked
  case identifierConflict
  case sourceMismatch
  case ambiguousIdentifier
  case messageTooLarge
  case commandLimitExceeded
  case rateLimited
  case capacityExceeded
  case staleRevision
  case revisionRequired
  case generationEnded
}

struct PulseResponse: Codable, Equatable, Sendable {
  var ok: Bool
  var id: String?
  var error: String?
  var warning: String? = nil
  var errorCode: PulseErrorCode? = nil
  var requestID: String? = nil
  /// Whole seconds to wait before retrying a throttled command. This is the local protocol's
  /// equivalent of HTTP's `Retry-After` response header.
  var retryAfter: Int? = nil

  static func success(
    id: String? = nil, warning: String? = nil, requestID: String? = nil
  ) -> Self {
    .init(ok: true, id: id, error: nil, warning: warning, requestID: requestID)
  }

  static func failure(
    _ error: String, code: PulseErrorCode = .validationFailed, requestID: String? = nil,
    retryAfter: Int? = nil
  ) -> Self {
    .init(
      ok: false, id: nil, error: error, warning: nil, errorCode: code, requestID: requestID,
      retryAfter: retryAfter)
  }
}

/// Rolling-window protection with enough detail for a sender to retry at the right time.
struct PulseRateLimiter: Sendable {
  let limit: Int
  let window: TimeInterval
  private(set) var acceptedTimes: [TimeInterval] = []

  init(limit: Int = 512, window: TimeInterval = 60) {
    self.limit = max(1, limit)
    self.window = window.isFinite && window > 0 ? window : 60
  }

  mutating func accepts(_ now: TimeInterval) -> Bool {
    guard retryAfter(at: now) == nil else { return false }
    acceptedTimes.append(now)
    return true
  }

  mutating func retryAfter(at now: TimeInterval) -> Int? {
    discardExpired(at: now)
    guard acceptedTimes.count >= limit, let firstAccepted = acceptedTimes.first else { return nil }
    return max(1, Int(ceil(firstAccepted + window - now)))
  }

  mutating func discardExpired(at now: TimeInterval) {
    if let last = acceptedTimes.last, now < last {
      acceptedTimes.removeAll(keepingCapacity: true)
      return
    }
    let cutoff = now - window
    acceptedTimes.removeAll { $0 <= cutoff }
  }

  var isEmpty: Bool { acceptedTimes.isEmpty }
}

enum PulseRateLimitScope: Equatable, Sendable {
  case provider
  case process
}

enum PulseRateLimitResult: Equatable, Sendable {
  case accepted
  case rateLimited(scope: PulseRateLimitScope, retryAfter: Int)
}

/// Tracks authenticated provider buckets separately, then applies a bounded process-wide ceiling
/// after a provider has spare capacity. Empty windows are discarded and the state count is capped,
/// so provider churn cannot turn this into an unbounded dictionary.
struct PulseProviderRateLimiters: Sendable {
  static let defaultProviderLimit = 512
  static let defaultProcessLimit = 2_048
  static let defaultWindow: TimeInterval = 60
  static let defaultMaximumProviderStates = 256

  private struct ProviderState: Sendable {
    var limiter: PulseRateLimiter
    var lastAcceptedAt: TimeInterval
  }

  private let providerLimit: Int
  private let window: TimeInterval
  private let maximumProviderStates: Int
  private var processLimiter: PulseRateLimiter
  private var providers: [String: ProviderState] = [:]

  init(
    providerLimit: Int = Self.defaultProviderLimit,
    processLimit: Int = Self.defaultProcessLimit,
    window: TimeInterval = Self.defaultWindow,
    maximumProviderStates: Int = Self.defaultMaximumProviderStates
  ) {
    self.providerLimit = max(1, providerLimit)
    self.window = window.isFinite && window > 0 ? window : Self.defaultWindow
    self.maximumProviderStates = max(1, maximumProviderStates)
    processLimiter = PulseRateLimiter(limit: processLimit, window: self.window)
  }

  var trackedProviderCount: Int { providers.count }

  mutating func admit(providerID: String, at now: TimeInterval) -> PulseRateLimitResult {
    cleanup(at: now)

    var provider =
      providers[providerID]
      ?? ProviderState(
        limiter: PulseRateLimiter(limit: providerLimit, window: window), lastAcceptedAt: now)
    if let retryAfter = provider.limiter.retryAfter(at: now) {
      providers[providerID] = provider
      return .rateLimited(scope: .provider, retryAfter: retryAfter)
    }
    if let retryAfter = processLimiter.retryAfter(at: now) {
      if providers[providerID] != nil { providers[providerID] = provider }
      return .rateLimited(scope: .process, retryAfter: retryAfter)
    }

    if providers[providerID] == nil { makeRoomForProvider() }
    _ = provider.limiter.accepts(now)
    provider.lastAcceptedAt = now
    providers[providerID] = provider
    _ = processLimiter.accepts(now)
    return .accepted
  }

  mutating func removeProvider(_ providerID: String) {
    providers[providerID] = nil
  }

  private mutating func cleanup(at now: TimeInterval) {
    processLimiter.discardExpired(at: now)
    for providerID in Array(providers.keys) {
      providers[providerID]?.limiter.discardExpired(at: now)
    }
    providers = providers.filter { !$0.value.limiter.isEmpty }
  }

  private mutating func makeRoomForProvider() {
    while providers.count >= maximumProviderStates,
      let oldest = providers.min(by: { $0.value.lastAcceptedAt < $1.value.lastAcceptedAt })?.key
    {
      providers[oldest] = nil
    }
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
    "token", "operation", "activity", "id", "requestID", "source", "revision",
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
    if let rawRevision = command["revision"] {
      guard !(rawRevision is Bool), let revision = rawRevision as? NSNumber,
        revision.doubleValue.isFinite,
        revision.doubleValue.rounded(.towardZero) == revision.doubleValue,
        revision.doubleValue >= 0, revision.doubleValue <= Double(PulseRevision.maximum)
      else {
        throw PulseWireValidationError.invalidField("command.revision")
      }
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
