import AppKit
import Foundation

enum AppRelauncher {
  static func helperArguments(parentPID: pid_t, bundleURL: URL) -> [String] {
    [
      "-c",
      "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open -n \"$2\"",
      "islet-relaunch",
      String(parentPID),
      bundleURL.path,
    ]
  }

  @MainActor
  static func restart() {
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = helperArguments(
      parentPID: ProcessInfo.processInfo.processIdentifier, bundleURL: Bundle.main.bundleURL)
    helper.standardOutput = FileHandle.nullDevice
    helper.standardError = FileHandle.nullDevice

    do {
      try helper.run()
      NSApplication.shared.terminate(nil)
    } catch {
      Log.app.error("Could not start relaunch helper: \(error)")
    }
  }
}
