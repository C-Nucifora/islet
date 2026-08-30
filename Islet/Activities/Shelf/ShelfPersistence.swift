import Foundation

enum ShelfSameFileDuplicatePolicy: String, CaseIterable, Codable, Identifiable, Sendable {
  case reuseExisting
  case keepBoth

  var id: Self { self }
  var title: String {
    switch self {
    case .reuseExisting: "Reuse existing copy"
    case .keepBoth: "Keep both"
    }
  }
}

enum ShelfSameNameDuplicatePolicy: String, CaseIterable, Codable, Identifiable, Sendable {
  case keepBoth
  case reuseExisting

  var id: Self { self }
  var title: String {
    switch self {
    case .keepBoth: "Keep both with a number"
    case .reuseExisting: "Reuse existing name"
    }
  }
}

enum ShelfExpiryRule: String, CaseIterable, Codable, Identifiable, Sendable {
  case never
  case oneHour
  case oneDay
  case oneWeek

  var id: Self { self }
  var title: String {
    switch self {
    case .never: "Never"
    case .oneHour: "After 1 hour"
    case .oneDay: "After 1 day"
    case .oneWeek: "After 1 week"
    }
  }

  var interval: TimeInterval? {
    switch self {
    case .never: nil
    case .oneHour: 60 * 60
    case .oneDay: 24 * 60 * 60
    case .oneWeek: 7 * 24 * 60 * 60
    }
  }
}

struct ShelfStack: Identifiable, Equatable, Codable, Sendable {
  let id: UUID
  var name: String
  var expiryRule: ShelfExpiryRule
}

struct ShelfOriginIdentity: Hashable, Codable, Sendable {
  let standardizedPath: String
  let resourceIdentifier: String?

  static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs.resourceIdentifier, rhs.resourceIdentifier) {
    case (.some(let lhsIdentifier), .some(let rhsIdentifier)):
      lhsIdentifier == rhsIdentifier
    case (.none, .none):
      lhs.standardizedPath == rhs.standardizedPath
    default:
      false
    }
  }

  func hash(into hasher: inout Hasher) {
    if let resourceIdentifier {
      hasher.combine(0)
      hasher.combine(resourceIdentifier)
    } else {
      hasher.combine(1)
      hasher.combine(standardizedPath)
    }
  }

  static func read(from url: URL) -> ShelfOriginIdentity {
    let identifier = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
      .fileResourceIdentifier
    return ShelfOriginIdentity(
      standardizedPath: url.standardizedFileURL.path,
      resourceIdentifier: identifier.map { String(describing: $0) })
  }
}

struct ShelfItemRecord: Identifiable, Equatable, Codable, Sendable {
  let id: UUID
  let fileName: String
  var stackID: UUID
  let importedAt: Date
  var expiresAt: Date?
  let origin: ShelfOriginIdentity?
}

struct ShelfPendingImport: Identifiable, Equatable, Codable, Sendable {
  let id: UUID
  let fileName: String
  let stackID: UUID
  let importedAt: Date
  let expiresAt: Date?
  let origin: ShelfOriginIdentity
}

struct ShelfManifest: Equatable, Codable, Sendable {
  static let currentVersion = 1

  var version = currentVersion
  var stacks: [ShelfStack]
  var items: [ShelfItemRecord]
  var pendingImports: [ShelfPendingImport]
  var sameFilePolicy: ShelfSameFileDuplicatePolicy
  var sameNamePolicy: ShelfSameNameDuplicatePolicy

  static func empty(defaultStack: ShelfStack) -> ShelfManifest {
    ShelfManifest(
      stacks: [defaultStack], items: [], pendingImports: [],
      sameFilePolicy: .reuseExisting, sameNamePolicy: .keepBoth)
  }
}

enum ShelfManifestStore {
  static let fileName = ".islet-shelf.json"

  static func load(from url: URL) -> Result<ShelfManifest?, Error> {
    Result {
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(ShelfManifest.self, from: Data(contentsOf: url))
    }
  }

  static func save(_ manifest: ShelfManifest, to url: URL) async -> Result<Void, Error> {
    await Task.detached(priority: .utility) {
      Result {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: url, options: [.atomic])
      }
    }.value
  }
}
