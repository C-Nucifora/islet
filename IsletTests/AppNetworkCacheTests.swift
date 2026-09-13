import Foundation
import XCTest

@testable import Islet

final class AppNetworkCacheTests: XCTestCase {
  func testReplacementClearsLegacyResponsesAndDisablesDiskCaching() throws {
    let legacy = URLCache(memoryCapacity: 1024 * 1024, diskCapacity: 0)
    let request = URLRequest(url: try XCTUnwrap(URL(string: "https://cache.islet.test/data")))
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Cache-Control": "public, max-age=3600"]))
    legacy.storeCachedResponse(
      CachedURLResponse(response: response, data: Data("cached".utf8)), for: request)
    XCTAssertNotNil(legacy.cachedResponse(for: request))

    let replacement = AppNetworkCache.replacement(removingResponsesFrom: legacy)

    XCTAssertNil(legacy.cachedResponse(for: request))
    XCTAssertEqual(replacement.memoryCapacity, AppNetworkCache.memoryCapacity)
    XCTAssertEqual(replacement.diskCapacity, 0)
  }
}
