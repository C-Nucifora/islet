import AppKit
import XCTest

@testable import Islet

final class ArtworkDecoderTests: XCTestCase {
  func testRejectsDecompressionBombFromMetadata() throws {
    let data = try png(width: 1, height: 1)
    let bomb = try replacingPNGDimensions(in: data, width: 32_768, height: 32_768)

    XCTAssertEqual(
      ArtworkDecoder.inspect(bomb),
      .sourceDimensionsTooLarge)
    XCTAssertNil(ArtworkDecoder.decode(bomb))
  }

  func testDownsamplesOversizedDimensionWithinDecodedMemoryBudget() throws {
    let decoded = try XCTUnwrap(ArtworkDecoder.decode(png(width: 4_096, height: 1)))

    XCTAssertLessThanOrEqual(
      max(decoded.pixelWidth, decoded.pixelHeight),
      ArtworkDecodePolicy.standard.maximumOutputDimension)
    XCTAssertLessThanOrEqual(
      decoded.decodedBytes, ArtworkDecodePolicy.standard.maximumDecodedBytes)
  }

  func testRejectsEncodedDataOverBudgetBeforeMetadataRead() {
    let policy = ArtworkDecodePolicy.standard
    let data = Data(repeating: 0, count: policy.maximumEncodedBytes + 1)

    XCTAssertEqual(ArtworkDecoder.inspect(data), .encodedDataTooLarge)
    XCTAssertNil(ArtworkDecoder.decode(data))
  }

  private func png(width: Int, height: Int) throws -> Data {
    let representation = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: width * 4,
        bitsPerPixel: 32))
    return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
  }

  private func replacingPNGDimensions(
    in data: Data, width: UInt32, height: UInt32
  ) throws -> Data {
    var bytes = [UInt8](data)
    let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    guard bytes.count >= 33,
      Array(bytes[0..<8]) == signature,
      String(bytes: bytes[12..<16], encoding: .ascii) == "IHDR"
    else { throw ArtworkTestError.invalidPNG }

    writeBigEndian(width, to: &bytes, at: 16)
    writeBigEndian(height, to: &bytes, at: 20)
    writeBigEndian(crc32(bytes[12..<29]), to: &bytes, at: 29)
    return Data(bytes)
  }

  private func writeBigEndian(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
    bytes[offset] = UInt8(truncatingIfNeeded: value >> 24)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
    bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
    bytes[offset + 3] = UInt8(truncatingIfNeeded: value)
  }

  private func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    var crc = UInt32.max
    for byte in bytes {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
      }
    }
    return crc ^ UInt32.max
  }
}

private enum ArtworkTestError: Error {
  case invalidPNG
}
