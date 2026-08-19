import Foundation

/// A decoded Live Activity payload, normalised into a closed tree.
///
/// The blobs the daemon hands us (`ACActivityDescriptor.descriptorData`,
/// `ACActivityContent.contentData`) are the *owning app's* `Codable` types, so we never know the
/// schema — Uber's `ContentState` and the Clock's have nothing in common. Everything downstream
/// therefore reads the payload structurally rather than by type, and this is the shape it reads.
///
/// `Any` out of `JSONSerialization` would do the same job, but it is neither `Equatable` (so no
/// fixture assertions) nor `Sendable` (so it cannot cross the bridge's queue hop under Swift 6).
indirect enum PayloadValue: Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([PayloadValue])
  case object([String: PayloadValue])
  case null

  /// JSON first, then a property list, then give up.
  ///
  /// `ActivityKit` encodes `ContentState` with `JSONEncoder`, so JSON is the expected case; the
  /// plist branch is there because the daemon also carries system-originated activities, and a
  /// `nil` return is a real outcome we render around rather than an error to swallow loudly.
  static func decode(_ data: Data) -> PayloadValue? {
    guard !data.isEmpty else { return nil }
    if let json = try? JSONSerialization.jsonObject(
      with: data, options: [.fragmentsAllowed])
    {
      return convert(json)
    }
    if let plist = try? PropertyListSerialization.propertyList(
      from: data, options: [], format: nil)
    {
      return convert(plist)
    }
    return nil
  }

  private static func convert(_ any: Any) -> PayloadValue {
    switch any {
    case let v as String: return .string(v)
    case let v as NSNumber:
      // NSNumber erases Bool into a number; CFBoolean is the only way back.
      if CFGetTypeID(v) == CFBooleanGetTypeID() { return .bool(v.boolValue) }
      return .number(v.doubleValue)
    case let v as Date: return .number(v.timeIntervalSinceReferenceDate)
    case let v as [Any]: return .array(v.map(convert))
    case let v as [String: Any]: return .object(v.mapValues(convert))
    case is NSNull: return .null
    default: return .null
    }
  }
}

extension PayloadValue {
  var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  var numberValue: Double? {
    switch self {
    case .number(let d): return d
    // Some encoders stringify numbers; a countdown that arrives as "1786430090" is still a date.
    case .string(let s): return Double(s)
    default: return nil
    }
  }

  /// Every leaf in the tree, paired with the key it hung from and how deep it sat.
  ///
  /// Depth is what breaks ties: a `title` at the root of the payload beats a `title` buried three
  /// levels down inside some nested detail object.
  var leaves: [PayloadLeaf] {
    var out: [PayloadLeaf] = []
    collectLeaves(key: "", depth: 0, into: &out)
    return out
  }

  private func collectLeaves(key: String, depth: Int, into out: inout [PayloadLeaf]) {
    switch self {
    case .object(let dict):
      // Sorted so a payload's leaf order — and therefore every tie-break below — is deterministic
      // rather than dependent on dictionary hashing.
      for k in dict.keys.sorted() {
        dict[k]?.collectLeaves(key: k, depth: depth + 1, into: &out)
      }
    case .array(let items):
      for item in items { item.collectLeaves(key: key, depth: depth + 1, into: &out) }
    case .null:
      break
    default:
      out.append(PayloadLeaf(key: key, depth: depth, value: self))
    }
  }
}

struct PayloadLeaf: Equatable, Sendable {
  let key: String
  let depth: Int
  let value: PayloadValue
}
