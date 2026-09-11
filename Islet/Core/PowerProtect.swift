import Foundation

protocol PowerProtectProviding: Sendable {
  var isInstalled: Bool { get }
  func install() throws
  func enable() throws
  func disable() throws
}

enum PowerProtectError: LocalizedError {
  case missingResource(String)
  case notInstalled
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingResource(let name):
      "Islet is missing its \(name) resource. Reinstall Islet and try again."
    case .notInstalled:
      "Install Power Protect, or keep Amphetamine Power Protect installed, before starting a closed-display session."
    case .commandFailed(let message):
      message.isEmpty
        ? String(localized: "Power Protect could not change the system sleep setting.") : message
    }
  }
}

struct SystemPowerProtectProvider: PowerProtectProviding {
  enum DisableStrategy: Equatable {
    case nativeHelper
    case legacyAuthorization
    case none
  }

  static let helperPath = "/usr/local/libexec/islet-power-protect"
  static let sudoersPath = "/etc/sudoers.d/islet-power-protect"

  var isInstalled: Bool {
    nativeHelperInstalled || existingPMSetAuthorizationAvailable
  }

  func install() throws {
    let installer = try resource(named: "install-islet-power-protect", extension: "sh")
    let helper = try resource(named: "islet-power-protect", extension: nil)
    let sudoers = try resource(named: "islet-power-protect", extension: "sudoers")
    let appleScript = [
      "on run argv",
      "do shell script \"/bin/zsh \" & quoted form of item 1 of argv & \" \" & quoted form of item 2 of argv & \" \" & quoted form of item 3 of argv with administrator privileges",
      "end run",
    ]
    var arguments = appleScript.flatMap { ["-e", $0] }
    arguments += ["--", installer.path, helper.path, sudoers.path]
    _ = try run(executable: "/usr/bin/osascript", arguments: arguments)
    guard isInstalled else { throw PowerProtectError.notInstalled }
  }

  func enable() throws {
    guard isInstalled else { throw PowerProtectError.notInstalled }
    if nativeHelperInstalled {
      _ = try runHelper("enable")
    } else {
      try enableUsingExistingAuthorization()
    }
  }

  func disable() throws {
    switch Self.disableStrategy(
      nativeHelperInstalled: nativeHelperInstalled,
      legacyStateExists: FileManager.default.fileExists(atPath: legacyStateURL.path)
    ) {
    case .nativeHelper:
      _ = try runHelper("disable")
    case .legacyAuthorization:
      try disableUsingExistingAuthorization()
    case .none:
      break
    }
  }

  static func disableStrategy(
    nativeHelperInstalled: Bool, legacyStateExists: Bool
  ) -> DisableStrategy {
    if nativeHelperInstalled { return .nativeHelper }
    if legacyStateExists { return .legacyAuthorization }
    return .none
  }

  private var nativeHelperInstalled: Bool {
    FileManager.default.isExecutableFile(atPath: Self.helperPath)
      && FileManager.default.fileExists(atPath: Self.sudoersPath)
  }

  private var existingPMSetAuthorizationAvailable: Bool {
    (try? checkPMSetAuthorization(value: 1)) != nil
      && (try? checkPMSetAuthorization(value: 0)) != nil
  }

  private var legacyStateURL: URL {
    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    return
      applicationSupport
      .appending(path: "Islet", directoryHint: .isDirectory)
      .appending(path: "power-protect.previous")
  }

  private func runHelper(_ action: String) throws -> String {
    try run(
      executable: "/usr/bin/sudo", arguments: ["-n", Self.helperPath, action])
  }

  private func checkPMSetAuthorization(value: Int) throws {
    _ = try run(
      executable: "/usr/bin/sudo",
      arguments: ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", String(value)])
  }

  private func enableUsingExistingAuthorization() throws {
    let stateURL = legacyStateURL
    var createdState = false
    if !FileManager.default.fileExists(atPath: stateURL.path) {
      let output = try run(executable: "/usr/bin/pmset", arguments: ["-g"])
      guard let previous = Self.sleepDisabledValue(from: output) else {
        throw PowerProtectError.commandFailed(
          "Power Protect could not read the current SleepDisabled setting.")
      }
      try FileManager.default.createDirectory(
        at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("\(previous)\n".utf8).write(to: stateURL, options: .atomic)
      createdState = true
    }
    do {
      _ = try run(
        executable: "/usr/bin/sudo",
        arguments: ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"])
    } catch {
      if createdState { try? FileManager.default.removeItem(at: stateURL) }
      throw error
    }
  }

  private func disableUsingExistingAuthorization() throws {
    let stateURL = legacyStateURL
    let data = try Data(contentsOf: stateURL)
    let saved = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard saved == "0" || saved == "1" else {
      throw PowerProtectError.commandFailed(
        "Power Protect saved an invalid prior SleepDisabled setting.")
    }
    _ = try run(
      executable: "/usr/bin/sudo",
      arguments: ["-n", "/usr/bin/pmset", "-a", "disablesleep", saved])
    try FileManager.default.removeItem(at: stateURL)
  }

  static func sleepDisabledValue(from output: String) -> Int? {
    for line in output.split(separator: "\n") {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.first == "SleepDisabled", let last = fields.last else { continue }
      return Int(last)
    }
    return nil
  }

  private func resource(named name: String, extension fileExtension: String?) throws -> URL {
    guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension) else {
      let filename = fileExtension.map { "\(name).\($0)" } ?? name
      throw PowerProtectError.missingResource(filename)
    }
    return url
  }

  private func run(executable: String, arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    do {
      try process.run()
    } catch {
      throw PowerProtectError.commandFailed(error.localizedDescription)
    }
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let message = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
      throw PowerProtectError.commandFailed(message)
    }
    return message
  }
}
