import AppKit
import Darwin
import Foundation

struct SingleInstanceOwner: Codable, Equatable {
  let processIdentifier: pid_t
  let bundleIdentifier: String
  let version: String
  let build: String
  let executablePath: String

  static func current(bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo) -> Self {
    Self(
      processIdentifier: processInfo.processIdentifier,
      bundleIdentifier: bundle.bundleIdentifier ?? "Islet",
      version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
      build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
      executablePath: bundle.executableURL?.path ?? "")
  }
}

enum SingleInstanceClaim: Equatable {
  case primary
  case secondary(owner: SingleInstanceOwner?)
}

enum SingleInstanceLaunchResolution: Equatable {
  case primary
  case activatedExisting
  case secondaryStillOwned(owner: SingleInstanceOwner?)
}

/// Holds a BSD advisory lock for the process lifetime. The file stores diagnostics only. The
/// kernel drops ownership when the descriptor closes, including after a crash or app replacement.
final class SingleInstanceCoordinator {
  private let lockURL: URL
  private var descriptor: Int32 = -1

  init(lockURL: URL) {
    self.lockURL = lockURL
  }

  convenience init(bundleIdentifier: String, fileManager: FileManager = .default) throws {
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true)
    let directory = applicationSupport.appendingPathComponent("Islet/Instances", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let safeIdentifier = bundleIdentifier.replacingOccurrences(of: "/", with: "_")
    self.init(lockURL: directory.appendingPathComponent("\(safeIdentifier).lock"))
  }

  deinit {
    release()
  }

  func claim(owner: SingleInstanceOwner) throws -> SingleInstanceClaim {
    if descriptor >= 0 { return .primary }

    let openedDescriptor = lockURL.path.withCString {
      Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
    }
    guard openedDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    if flock(openedDescriptor, LOCK_EX | LOCK_NB) == 0 {
      do {
        try write(owner: owner, to: openedDescriptor)
        descriptor = openedDescriptor
        return .primary
      } catch {
        Darwin.close(openedDescriptor)
        throw error
      }
    }

    let lockError = errno
    Darwin.close(openedDescriptor)
    guard lockError == EWOULDBLOCK else {
      throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
    }
    return .secondary(owner: readOwner())
  }

  func readOwner() -> SingleInstanceOwner? {
    guard let data = try? Data(contentsOf: lockURL) else { return nil }
    return try? JSONDecoder().decode(SingleInstanceOwner.self, from: data)
  }

  func release() {
    guard descriptor >= 0 else { return }
    Darwin.close(descriptor)
    descriptor = -1
  }

  private func write(owner: SingleInstanceOwner, to descriptor: Int32) throws {
    let data = try JSONEncoder().encode(owner)
    guard Darwin.ftruncate(descriptor, 0) == 0, Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    try data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var written = 0
      while written < bytes.count {
        let result = Darwin.write(
          descriptor,
          baseAddress.advanced(by: written),
          bytes.count - written)
        if result > 0 {
          written += result
        } else if result < 0, errno == EINTR {
          continue
        } else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
      }
    }
  }
}

enum SingleInstanceLaunchResolver {
  /// Resolves the handoff race where the previous owner exits after the first failed claim but
  /// before AppKit can activate it. A failed activation gets one fresh lock claim; if the kernel
  /// has released ownership, this process becomes the primary instead of terminating too.
  static func resolve(
    coordinator: SingleInstanceCoordinator,
    owner: SingleInstanceOwner,
    activate: (SingleInstanceOwner?) -> Bool
  ) throws -> SingleInstanceLaunchResolution {
    switch try coordinator.claim(owner: owner) {
    case .primary:
      return .primary
    case .secondary(let existingOwner):
      if activate(existingOwner) { return .activatedExisting }
      switch try coordinator.claim(owner: owner) {
      case .primary:
        return .primary
      case .secondary(let currentOwner):
        return .secondaryStillOwned(owner: currentOwner)
      }
    }
  }
}

@MainActor
enum ExistingInstanceActivator {
  static func activate(
    owner: SingleInstanceOwner?,
    bundleIdentifier: String,
    currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
  ) -> Bool {
    if let owner,
      owner.bundleIdentifier == bundleIdentifier,
      owner.processIdentifier != currentProcessIdentifier,
      let application = NSRunningApplication(processIdentifier: owner.processIdentifier),
      !application.isTerminated,
      application.bundleIdentifier == bundleIdentifier
    {
      return application.activate()
    }

    guard
      let application = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
      )
      .first(where: { !$0.isTerminated && $0.processIdentifier != currentProcessIdentifier })
    else { return false }
    return application.activate()
  }
}
