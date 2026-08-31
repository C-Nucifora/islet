import Foundation
import ImageIO

struct ArtworkDecodePolicy: Sendable {
  static let standard = ArtworkDecodePolicy(
    maximumEncodedBytes: 750_000,
    maximumSourceDimension: 32_768,
    maximumSourcePixels: 8_388_608,
    maximumOutputDimension: 2_048,
    maximumDecodedBytes: 16 * 1_024 * 1_024)

  let maximumEncodedBytes: Int
  let maximumSourceDimension: Int
  let maximumSourcePixels: Int
  let maximumOutputDimension: Int
  let maximumDecodedBytes: Int

  /// ImageIO can produce 16-bit channels even for compact input. Reserve eight bytes per output
  /// pixel when choosing the thumbnail size, then check the actual row storage after decoding.
  var maximumOutputPixels: Int { maximumDecodedBytes / 8 }

  var maximumBase64Characters: Int {
    ((maximumEncodedBytes + 2) / 3) * 4
  }
}

struct ArtworkMetadata: Equatable, Sendable {
  let width: Int
  let height: Int

  var pixelCount: Int? {
    let result = width.multipliedReportingOverflow(by: height)
    return result.overflow ? nil : result.partialValue
  }
}

enum ArtworkInspection: Equatable, Sendable {
  case accepted(ArtworkMetadata)
  case invalid
  case encodedDataTooLarge
  case sourceDimensionsTooLarge
}

struct DecodedArtwork: @unchecked Sendable {
  /// CGImage is immutable. The main actor wraps it in NSImage after the utility task finishes.
  let cgImage: CGImage
  let pixelWidth: Int
  let pixelHeight: Int
  let decodedBytes: Int
}

enum ArtworkDecoder {
  static func inspect(
    _ data: Data, policy: ArtworkDecodePolicy = .standard
  ) -> ArtworkInspection {
    guard !data.isEmpty, data.count <= policy.maximumEncodedBytes else {
      return data.isEmpty ? .invalid : .encodedDataTooLarge
    }
    if let metadata = pngMetadata(in: data) {
      return validate(metadata, policy: policy)
    }
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(
        source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
      let width = integerProperty(properties[kCGImagePropertyPixelWidth]),
      let height = integerProperty(properties[kCGImagePropertyPixelHeight]),
      width > 0, height > 0
    else { return .invalid }

    return validate(ArtworkMetadata(width: width, height: height), policy: policy)
  }

  private static func validate(
    _ metadata: ArtworkMetadata, policy: ArtworkDecodePolicy
  ) -> ArtworkInspection {
    let width = metadata.width
    let height = metadata.height
    guard width <= policy.maximumSourceDimension,
      height <= policy.maximumSourceDimension,
      let pixelCount = metadata.pixelCount,
      pixelCount <= policy.maximumSourcePixels
    else { return .sourceDimensionsTooLarge }
    return .accepted(metadata)
  }

  static func decode(
    _ data: Data, policy: ArtworkDecodePolicy = .standard
  ) -> DecodedArtwork? {
    guard case .accepted = inspect(data, policy: policy), !Task.isCancelled,
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }

    let outputDimension = min(
      policy.maximumOutputDimension,
      Int(Double(policy.maximumOutputPixels).squareRoot()))
    guard outputDimension > 0 else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: outputDimension,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceShouldCache: true,
      kCGImageSourceShouldAllowFloat: false,
    ]
    guard !Task.isCancelled,
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }

    let pixelCount = image.width.multipliedReportingOverflow(by: image.height)
    let decodedBytes = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
    guard !pixelCount.overflow,
      !decodedBytes.overflow,
      pixelCount.partialValue <= policy.maximumOutputPixels,
      decodedBytes.partialValue <= policy.maximumDecodedBytes
    else { return nil }
    return DecodedArtwork(
      cgImage: image,
      pixelWidth: image.width,
      pixelHeight: image.height,
      decodedBytes: decodedBytes.partialValue)
  }

  private static func integerProperty(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    return value as? Int
  }

  /// PNG stores width and height in the fixed IHDR header. Reading those 24 bytes avoids asking a
  /// codec to initialize a source that already declares bomb-sized output.
  private static func pngMetadata(in data: Data) -> ArtworkMetadata? {
    let bytes = [UInt8](data.prefix(24))
    let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    guard bytes.count == 24,
      Array(bytes[0..<8]) == signature,
      String(bytes: bytes[12..<16], encoding: .ascii) == "IHDR"
    else { return nil }
    let width = readBigEndianUInt32(bytes, at: 16)
    let height = readBigEndianUInt32(bytes, at: 20)
    return ArtworkMetadata(width: Int(width), height: Int(height))
  }

  private static func readBigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
      | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
  }
}
