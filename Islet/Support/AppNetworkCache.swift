import Foundation

enum AppNetworkCache {
  static let memoryCapacity = 4 * 1024 * 1024

  static func install() {
    URLCache.shared = replacement(removingResponsesFrom: URLCache.shared)
  }

  static func replacement(removingResponsesFrom previousCache: URLCache) -> URLCache {
    previousCache.removeAllCachedResponses()
    return URLCache(memoryCapacity: memoryCapacity, diskCapacity: 0)
  }
}
