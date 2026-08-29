#!/usr/bin/env swift
import Darwin
import Foundation
import Network

private let usage = """
  usage: islet-pulse end <id> [--source NAME]
         islet-pulse <show|update|event> <id> <title> [subtitle] [options]

  options:
    --source NAME            Stable provider source (default: cli)
    --progress NUMBER        Progress from 0 through 1
    --state STATE            active|progress|needsAction|succeeded|failed
    --priority PRIORITY      low|normal|high|critical
    --expires SECONDS        Expire after 2 through 86400 seconds
    --action TITLE URL       Add an HTTP(S) action (up to three)
  """ + "\n"

private struct Response: Decodable {
  let ok: Bool
  let error: String?
  let errorCode: String?
  let requestID: String?
}

/// Network callbacks run on a private serial queue. Completion is separately lock-protected so a
/// timeout and a callback cannot race to choose the process exit status.
private final class PulseClient: @unchecked Sendable {
  private let connection = NWConnection(
    host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 47_717)!, using: .tcp)
  private let queue = DispatchQueue(label: "dev.islet.pulse-cli", qos: .utility)
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var complete = false
  private var exitCode: Int32 = 1
  private var sent = false  // queue-confined
  private var buffer = Data()  // queue-confined
  private var expectedRequestID = ""

  func run(payload: Data, requestID: String) -> Int32 {
    expectedRequestID = requestID
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready: self.sendOnce(payload)
      case .failed(let error): self.finish(1, error: "connection failed: \(error)")
      case .cancelled: self.finish(1, error: "connection closed before a response was received")
      default: break
      }
    }
    connection.start(queue: queue)
    if semaphore.wait(timeout: .now() + 5) == .timedOut {
      finish(70, error: "timed out waiting for Islet Pulse")
    }
    connection.cancel()
    lock.lock()
    let result = exitCode
    lock.unlock()
    return result
  }

  private func sendOnce(_ payload: Data) {
    guard !sent else { return }
    sent = true
    connection.send(
      content: payload,
      completion: .contentProcessed { [weak self] error in
        guard let self else { return }
        if let error { self.finish(1, error: "send failed: \(error)") } else { self.receive() }
      })
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data { self.buffer.append(data) }
      guard self.buffer.count <= 64 * 1024 else {
        self.finish(65, error: "Islet Pulse returned an oversized response")
        return
      }
      if let newline = self.buffer.firstIndex(of: 0x0A) {
        self.handleResponse(Data(self.buffer[..<newline]))
      } else if let error {
        self.finish(1, error: "receive failed: \(error)")
      } else if isComplete {
        self.finish(65, error: "Islet Pulse returned an incomplete response")
      } else {
        self.receive()
      }
    }
  }

  private func handleResponse(_ data: Data) {
    do {
      let response = try JSONDecoder().decode(Response.self, from: data)
      guard response.requestID == expectedRequestID else {
        finish(65, error: "Islet Pulse returned a response with the wrong requestID")
        return
      }
      var output = data
      output.append(0x0A)
      let prefix = response.errorCode.map { "[\($0)] " } ?? ""
      finish(
        response.ok ? 0 : 65,
        error: response.ok ? nil : prefix + (response.error ?? "command rejected"), output: output)
    } catch {
      finish(65, error: "invalid response from Islet Pulse: \(error.localizedDescription)")
    }
  }

  private func finish(_ code: Int32, error: String? = nil, output: Data? = nil) {
    lock.lock()
    guard !complete else {
      lock.unlock()
      return
    }
    complete = true
    exitCode = code
    lock.unlock()
    if let output { FileHandle.standardOutput.write(output) }
    if let error { FileHandle.standardError.write(Data("\(error)\n".utf8)) }
    semaphore.signal()
  }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
  FileHandle.standardOutput.write(Data(usage.utf8))
  exit(0)
}
let validOperations = Set(["show", "update", "event", "end"])
guard arguments.count >= 2, validOperations.contains(arguments[0]) else {
  FileHandle.standardError.write(Data(usage.utf8))
  exit(64)
}
let operation = arguments[0]
let identifier = arguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
guard !identifier.isEmpty, identifier.count <= 128 else {
  FileHandle.standardError.write(Data("id must contain 1...128 characters\n".utf8))
  exit(64)
}

let requestID = UUID().uuidString
var command: [String: Any] = ["operation": operation, "requestID": requestID]
if operation == "end" {
  guard arguments.count == 2 || arguments.count == 4 else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(64)
  }
  command["id"] = identifier
  if arguments.count == 4 {
    guard arguments[2] == "--source" else {
      FileHandle.standardError.write(Data(usage.utf8))
      exit(64)
    }
    let source = arguments[3].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !source.isEmpty, source.count <= 80 else {
      FileHandle.standardError.write(Data("source must contain 1...80 characters\n".utf8))
      exit(64)
    }
    command["source"] = source
  }
} else {
  guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("show/update/event requires a title\n".utf8))
    exit(64)
  }
  let title = arguments[2].trimmingCharacters(in: .whitespacesAndNewlines)
  guard !title.isEmpty, title.count <= 180 else {
    FileHandle.standardError.write(Data("title must contain 1...180 characters\n".utf8))
    exit(64)
  }
  var activity: [String: Any] = ["id": identifier, "source": "cli", "title": title]
  var index = 3
  if index < arguments.count, !arguments[index].hasPrefix("--") {
    let subtitle = arguments[index].trimmingCharacters(in: .whitespacesAndNewlines)
    guard subtitle.count <= 240 else {
      FileHandle.standardError.write(Data("subtitle exceeds 240 characters\n".utf8))
      exit(64)
    }
    if !subtitle.isEmpty { activity["subtitle"] = subtitle }
    index += 1
  }
  var actions: [[String: Any]] = []
  while index < arguments.count {
    let option = arguments[index]
    switch option {
    case "--source":
      guard index + 1 < arguments.count else {
        FileHandle.standardError.write(Data("--source requires a value\n".utf8))
        exit(64)
      }
      let source = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !source.isEmpty, source.count <= 80 else {
        FileHandle.standardError.write(Data("source must contain 1...80 characters\n".utf8))
        exit(64)
      }
      activity["source"] = source
      index += 2
    case "--progress":
      guard index + 1 < arguments.count, let progress = Double(arguments[index + 1]),
        progress.isFinite, (0...1).contains(progress)
      else {
        FileHandle.standardError.write(Data("progress must be a number from 0 through 1\n".utf8))
        exit(64)
      }
      activity["progress"] = progress
      index += 2
    case "--state":
      let allowed = Set(["active", "progress", "needsAction", "succeeded", "failed"])
      guard index + 1 < arguments.count, allowed.contains(arguments[index + 1]) else {
        FileHandle.standardError.write(Data("invalid state\n".utf8))
        exit(64)
      }
      activity["state"] = arguments[index + 1]
      index += 2
    case "--priority":
      let allowed = Set(["low", "normal", "high", "critical"])
      guard index + 1 < arguments.count, allowed.contains(arguments[index + 1]) else {
        FileHandle.standardError.write(Data("invalid priority\n".utf8))
        exit(64)
      }
      activity["priority"] = arguments[index + 1]
      index += 2
    case "--expires":
      guard index + 1 < arguments.count, let seconds = Double(arguments[index + 1]),
        seconds.isFinite, (2...86_400).contains(seconds)
      else {
        FileHandle.standardError.write(Data("expiry must be from 2 through 86400 seconds\n".utf8))
        exit(64)
      }
      activity["expiresAt"] = ISO8601DateFormatter().string(
        from: Date().addingTimeInterval(seconds))
      index += 2
    case "--action":
      guard index + 2 < arguments.count, actions.count < 3,
        let url = URL(string: arguments[index + 2]),
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
        components.host?.isEmpty == false, components.user == nil, components.password == nil
      else {
        FileHandle.standardError.write(
          Data("action requires a title and safe HTTP(S) URL (maximum three)\n".utf8))
        exit(64)
      }
      guard url.absoluteString.count <= 2_048 else {
        FileHandle.standardError.write(Data("action URL exceeds 2048 characters\n".utf8))
        exit(64)
      }
      let actionTitle = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !actionTitle.isEmpty, actionTitle.count <= 60 else {
        FileHandle.standardError.write(Data("action title must contain 1...60 characters\n".utf8))
        exit(64)
      }
      actions.append([
        "id": "cli-\(actions.count + 1)", "title": actionTitle,
        "url": url.absoluteString,
      ])
      index += 3
    default:
      FileHandle.standardError.write(Data("unknown option: \(option)\n\(usage)".utf8))
      exit(64)
    }
  }
  if !actions.isEmpty { activity["actions"] = actions }
  command["activity"] = activity
}

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("Islet", isDirectory: true)
let tokenURL = support.appendingPathComponent("pulse-token")
var tokenInfo = stat()
guard
  lstat(tokenURL.path, &tokenInfo) == 0,
  (tokenInfo.st_mode & S_IFMT) == S_IFREG,
  tokenInfo.st_uid == getuid(),
  (tokenInfo.st_mode & 0o077) == 0,
  let token = try? String(contentsOf: tokenURL, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines),
  let tokenData = Data(base64Encoded: token), tokenData.count == 32
else {
  FileHandle.standardError.write(
    Data(
      "Islet Pulse token is missing, invalid, not owned by this user, or has unsafe permissions.\n"
        .utf8))
  exit(69)
}
command["token"] = token

do {
  var payload = try JSONSerialization.data(withJSONObject: command)
  payload.append(0x0A)
  exit(PulseClient().run(payload: payload, requestID: requestID))
} catch {
  FileHandle.standardError.write(
    Data("could not encode command: \(error.localizedDescription)\n".utf8))
  exit(70)
}
