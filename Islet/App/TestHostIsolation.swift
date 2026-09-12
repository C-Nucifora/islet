import Foundation

enum TestHostIsolation {
  static var isRunningTests: Bool {
    #if ISLET_TESTING
      true
    #else
      NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
    #endif
  }

  static func requireSafeIdentity() {
    guard isRunningTests else { return }
    precondition(
      Bundle.main.bundleIdentifier == "dev.islet.tests",
      "Islet tests require the Testing configuration and dev.islet.tests bundle identifier.")
  }
}
