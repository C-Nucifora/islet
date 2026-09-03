import Foundation

enum LocalizedText {
  static func fileCount(_ count: Int) -> String {
    String(localized: "\(count) file", comment: "A count of files")
  }

  static func itemCount(_ count: Int) -> String {
    String(localized: "\(count) item", comment: "A count of items")
  }

  static func activityCount(_ count: Int) -> String {
    String(localized: "\(count) activity", comment: "A count of enabled activities")
  }

  static func agentCount(_ count: Int) -> String {
    String(localized: "\(count) agent", comment: "A count of T3 Code agents")
  }

  static func sourceCount(_ count: Int) -> String {
    String(localized: "\(count) source", comment: "A count of media sources")
  }

  static func minuteCount(_ count: Int) -> String {
    String(localized: "\(count) minute", comment: "A duration in whole minutes")
  }

  static func hourCount(_ count: Int) -> String {
    String(localized: "\(count) hour", comment: "A duration in whole hours")
  }

  static func secondCount(_ count: Int) -> String {
    String(localized: "\(count) second", comment: "A duration in whole seconds")
  }
}

enum LocalizedFormat {
  static func integer(
    _ value: Int, minimumDigits: Int = 1, locale: Locale = .current
  ) -> String {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumIntegerDigits = minimumDigits
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }

  static func percent(_ fraction: Double, locale: Locale = .current) -> String {
    fraction.formatted(
      .percent.precision(.fractionLength(0)).rounded(rule: .toNearestOrEven).locale(locale))
  }

  static func bytes(_ value: Int64, locale: Locale = .current) -> String {
    value.formatted(
      .byteCount(style: .file, allowedUnits: [.kb, .mb, .gb, .tb], spellsOutZero: false)
        .locale(locale))
  }

  static func number(
    _ value: Double, fractionDigits: ClosedRange<Int>, locale: Locale = .current
  ) -> String {
    value.formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
  }

  static func signedNumber(
    _ value: Double, fractionDigits: Int, locale: Locale = .current
  ) -> String {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    formatter.positivePrefix = formatter.plusSign
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }

  static func measurement<UnitType: Dimension>(
    _ value: Double, unit: UnitType, fractionDigits: ClosedRange<Int>,
    width: Measurement<UnitType>.FormatStyle.UnitWidth = .abbreviated,
    locale: Locale = .current
  ) -> String {
    Measurement(value: value, unit: unit).formatted(
      .measurement(
        width: width, usage: .asProvided,
        numberFormatStyle: .number.precision(.fractionLength(fractionDigits))
      )
      .locale(locale))
  }
}

enum Pseudolocalization {
  static let localeIdentifier = "en-XA"

  /// Deterministic expansion used to produce and verify the checked-in en-XA catalog.
  static func expand(_ source: String) -> String {
    let substitutions: [Character: Character] = [
      "A": "Å", "a": "å", "E": "Ë", "e": "ë", "I": "Ï", "i": "ï", "O": "Ø",
      "o": "ø", "U": "Û", "u": "û", "Y": "Ÿ", "y": "ÿ", "C": "Ç", "c": "ç",
      "N": "Ñ", "n": "ñ",
    ]
    var result = ""
    var index = source.startIndex
    while index < source.endIndex {
      if source[index] == "%", let end = formatSpecifierEnd(in: source, from: index) {
        result += source[index..<end]
        index = end
        continue
      }
      let character = source[index]
      result.append(substitutions[character] ?? character)
      index = source.index(after: index)
    }
    let padding = String(repeating: "~", count: source.count / 3 + 2)
    return "［\(result) \(padding)］"
  }

  /// Returns the end of a Foundation/printf format specifier so pseudolocalization never mutates
  /// argument syntax. This covers positional arguments, dynamic width/precision, length modifiers,
  /// object placeholders and every integer or floating-point conversion accepted by NSString.
  private static func formatSpecifierEnd(in source: String, from percent: String.Index)
    -> String.Index?
  {
    var index = source.index(after: percent)
    guard index < source.endIndex else { return nil }
    if source[index] == "%" { return source.index(after: index) }

    func consumeDigits(_ cursor: inout String.Index) {
      while cursor < source.endIndex, source[cursor].isNumber {
        cursor = source.index(after: cursor)
      }
    }

    let positionalStart = index
    consumeDigits(&index)
    if index < source.endIndex, source[index] == "$" {
      index = source.index(after: index)
    } else {
      index = positionalStart
    }

    while index < source.endIndex, "-+ #0'".contains(source[index]) {
      index = source.index(after: index)
    }

    if index < source.endIndex, source[index] == "*" {
      index = source.index(after: index)
      consumeDigits(&index)
      if index < source.endIndex, source[index] == "$" { index = source.index(after: index) }
    } else {
      consumeDigits(&index)
    }

    if index < source.endIndex, source[index] == "." {
      index = source.index(after: index)
      if index < source.endIndex, source[index] == "*" {
        index = source.index(after: index)
        consumeDigits(&index)
        if index < source.endIndex, source[index] == "$" { index = source.index(after: index) }
      } else {
        consumeDigits(&index)
      }
    }

    for modifier in ["hh", "ll", "h", "l", "L", "z", "j", "t", "q"] {
      if source[index...].hasPrefix(modifier) {
        index = source.index(index, offsetBy: modifier.count)
        break
      }
    }
    guard index < source.endIndex, "diouxXfFeEgGaAcCsSp@".contains(source[index]) else {
      return nil
    }
    return source.index(after: index)
  }
}
