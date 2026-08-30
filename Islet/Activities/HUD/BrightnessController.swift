import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics
import IOKit.i2c

struct BrightnessDisplayTarget: Equatable {
  let displayID: CGDirectDisplayID
  let frame: CGRect
}

enum BrightnessTargetResolver {
  static func displayID(
    at point: CGPoint, displays: [BrightnessDisplayTarget]
  ) -> CGDirectDisplayID? {
    displays.first { $0.frame.contains(point) }?.displayID
  }
}

struct ExternalBrightnessDisplay: Equatable, Identifiable, Sendable {
  let displayID: CGDirectDisplayID
  let id: String
  let name: String
  let vendorID: UInt32
  let productID: UInt32
  let serialNumber: UInt32
}

enum ExternalBrightnessFailure: Error, Equatable, Sendable {
  case timedOut
  case unsupported(String)
  case rejected(String)

  var summary: String {
    switch self {
    case .timedOut:
      "DDC request timed out"
    case .unsupported(let reason):
      "Unsupported: \(reason)"
    case .rejected(let reason):
      "DDC rejected: \(reason)"
    }
  }
}

struct ExternalBrightnessDisplayStatus: Equatable, Identifiable, Sendable {
  enum Capability: Equatable, Sendable {
    case disabled
    case probing
    case available(level: Float)
    case unavailable(ExternalBrightnessFailure)

    var summary: String {
      switch self {
      case .disabled: "Disabled in Islet Settings"
      case .probing: "Checking DDC support"
      case .available(let level): "DDC available, \(Int((level * 100).rounded()))%"
      case .unavailable(let failure): failure.summary
      }
    }

    var isAvailable: Bool {
      if case .available = self { return true }
      return false
    }
  }

  let display: ExternalBrightnessDisplay
  let capability: Capability
  var id: String { display.id }
}

struct ExternalBrightnessBackend: Sendable {
  typealias Completion = @Sendable (Result<Float, ExternalBrightnessFailure>) -> Void

  let read: @Sendable (ExternalBrightnessDisplay, @escaping Completion) -> Void
  let write: @Sendable (ExternalBrightnessDisplay, Float, @escaping Completion) -> Void

  static let ddc = DDCBrightnessBackend().backend
}

struct BrightnessDeadlineCancellation: Sendable {
  let cancel: @Sendable () -> Void
}

struct BrightnessDeadlineScheduler: Sendable {
  let schedule:
    @Sendable (
      _ delay: Duration, _ operation: @escaping @Sendable () -> Void
    ) -> BrightnessDeadlineCancellation

  static let continuous = Self { delay, operation in
    let task = Task {
      do {
        try await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
        operation()
      } catch {}
    }
    return BrightnessDeadlineCancellation { task.cancel() }
  }
}

/// Main-thread state machine for external brightness. Backend work is asynchronous, so the event
/// tap only consults cached capability and level state. A first unknown or failed display always
/// falls through to macOS. Writes are coalesced while a key is repeating.
@MainActor
final class ExternalBrightnessController {
  private enum State {
    case disabled
    case probing
    case available(Float)
    case writing(requested: Float, inFlight: Float)
    case unavailable(ExternalBrightnessFailure)

    var capability: ExternalBrightnessDisplayStatus.Capability {
      switch self {
      case .disabled: .disabled
      case .probing: .probing
      case .available(let level): .available(level: level)
      case .writing(let requested, _): .available(level: requested)
      case .unavailable(let failure): .unavailable(failure)
      }
    }
  }

  private struct Entry {
    var display: ExternalBrightnessDisplay
    var state: State
    var operationID: UInt64?
    var cancelDeadline: BrightnessDeadlineCancellation?
  }

  private let backend: ExternalBrightnessBackend
  private let deadlineScheduler: BrightnessDeadlineScheduler
  private let timeout: Duration
  private var entries: [String: Entry] = [:]
  private var nextOperationID: UInt64 = 0
  var didChange: (@MainActor ([ExternalBrightnessDisplayStatus]) -> Void)?

  init(
    backend: ExternalBrightnessBackend = .ddc,
    deadlineScheduler: BrightnessDeadlineScheduler = .continuous,
    timeout: Duration = .milliseconds(500)
  ) {
    self.backend = backend
    self.deadlineScheduler = deadlineScheduler
    self.timeout = timeout
  }

  var statuses: [ExternalBrightnessDisplayStatus] {
    entries.values
      .map { ExternalBrightnessDisplayStatus(display: $0.display, capability: $0.state.capability) }
      .sorted { $0.display.name.localizedStandardCompare($1.display.name) == .orderedAscending }
  }

  var diagnostics: String {
    guard !statuses.isEmpty else { return "External brightness: no external displays connected" }
    return statuses.map {
      "External brightness \($0.display.name) [\($0.id)]: \($0.capability.summary)"
    }
    .joined(separator: "\n")
  }

  func refresh(displays: [ExternalBrightnessDisplay], disabledDisplayIDs: Set<String>) {
    let connectedIDs = Set(displays.map(\.id))
    for id in entries.keys where !connectedIDs.contains(id) {
      entries[id]?.cancelDeadline?.cancel()
      entries.removeValue(forKey: id)
    }

    for display in displays {
      let disabled = disabledDisplayIDs.contains(display.id)
      if var entry = entries[display.id] {
        entry.display = display
        if disabled {
          entry.cancelDeadline?.cancel()
          entry.operationID = nil
          entry.cancelDeadline = nil
          entry.state = .disabled
        } else {
          switch entry.state {
          case .disabled, .available, .unavailable:
            entry.state = .probing
            entries[display.id] = entry
            startProbe(display)
            continue
          case .probing, .writing:
            break
          }
        }
        entries[display.id] = entry
      } else if disabled {
        entries[display.id] = Entry(display: display, state: .disabled)
      } else {
        entries[display.id] = Entry(display: display, state: .probing)
        startProbe(display)
      }
    }
    notifyChange()
  }

  /// Returns an optimistic level only when a prior non-mutating probe succeeded. Returning nil is
  /// a hard instruction to the event tap to preserve the original event for macOS.
  func adjust(displayID: CGDirectDisplayID, up: Bool, divisor: Float) -> Float? {
    guard let id = entries.first(where: { $0.value.display.displayID == displayID })?.key,
      var entry = entries[id]
    else { return nil }

    let current: Float
    switch entry.state {
    case .available(let level):
      current = level
    case .writing(let requested, _):
      current = requested
    case .disabled, .probing, .unavailable:
      return nil
    }

    let target = HUDMath.stepped(current, up: up, divisor: divisor)
    switch entry.state {
    case .available:
      entry.state = .writing(requested: target, inFlight: target)
      entries[id] = entry
      startWrite(id: id, target: target)
    case .writing(_, let inFlight):
      entry.state = .writing(requested: target, inFlight: inFlight)
      entries[id] = entry
    case .disabled, .probing, .unavailable:
      return nil
    }
    notifyChange()
    return target
  }

  func cancelAll() {
    for entry in entries.values { entry.cancelDeadline?.cancel() }
    entries.removeAll()
    notifyChange()
  }

  func retryUnavailable() {
    let displays = entries.values.compactMap { entry -> ExternalBrightnessDisplay? in
      guard case .unavailable = entry.state else { return nil }
      return entry.display
    }
    for display in displays { entries[display.id]?.state = .probing }
    for display in displays { startProbe(display) }
    if !displays.isEmpty { notifyChange() }
  }

  private func startProbe(_ display: ExternalBrightnessDisplay) {
    startOperation(displayID: display.id) { [backend] completion in
      backend.read(display, completion)
    } completion: { [weak self] result in
      guard let self, var entry = self.entries[display.id] else { return }
      switch result {
      case .success(let level): entry.state = .available(Self.clamp(level))
      case .failure(let failure): entry.state = .unavailable(failure)
      }
      self.entries[display.id] = entry
      self.notifyChange()
    }
  }

  private func startWrite(id: String, target: Float) {
    guard let display = entries[id]?.display else { return }
    startOperation(displayID: id) { [backend] completion in
      backend.write(display, target, completion)
    } completion: { [weak self] result in
      guard let self, var entry = self.entries[id] else { return }
      switch result {
      case .failure(let failure):
        entry.state = .unavailable(failure)
        self.entries[id] = entry
      case .success(let actual):
        let requested: Float
        if case .writing(let desired, _) = entry.state {
          requested = desired
        } else {
          requested = Self.clamp(actual)
        }
        if abs(requested - target) > 0.0001 {
          entry.state = .writing(requested: requested, inFlight: requested)
          self.entries[id] = entry
          self.startWrite(id: id, target: requested)
        } else {
          entry.state = .available(Self.clamp(actual))
          self.entries[id] = entry
        }
      }
      self.notifyChange()
    }
  }

  private func startOperation(
    displayID: String,
    operation: (@escaping ExternalBrightnessBackend.Completion) -> Void,
    completion: @escaping @MainActor (Result<Float, ExternalBrightnessFailure>) -> Void
  ) {
    nextOperationID &+= 1
    let operationID = nextOperationID
    entries[displayID]?.cancelDeadline?.cancel()
    entries[displayID]?.operationID = operationID

    let finish: @Sendable (Result<Float, ExternalBrightnessFailure>) -> Void = {
      [weak self] result in
      Task { @MainActor in
        guard let self, self.entries[displayID]?.operationID == operationID else { return }
        self.entries[displayID]?.operationID = nil
        self.entries[displayID]?.cancelDeadline?.cancel()
        self.entries[displayID]?.cancelDeadline = nil
        completion(result)
      }
    }
    entries[displayID]?.cancelDeadline = deadlineScheduler.schedule(timeout) {
      finish(.failure(.timedOut))
    }
    operation(finish)
  }

  private func notifyChange() { didChange?(statuses) }
  private static func clamp(_ value: Float) -> Float { max(0, min(1, value)) }
}

/// Native display brightness via DisplayServices. It is intentionally limited to built-in
/// displays. External displays use the public IOKit DDC backend above and never reach these private
/// symbols.
enum BrightnessController {
  private typealias GetFn =
    @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
  private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

  nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = {
    for path in [
      "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
      "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices",
    ] {
      if let handle = dlopen(path, RTLD_LAZY) { return handle }
    }
    return nil
  }()

  private static let getFn: GetFn? =
    handle
    .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
    .map { unsafeBitCast($0, to: GetFn.self) }
  private static let setFn: SetFn? =
    handle
    .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
    .map { unsafeBitCast($0, to: SetFn.self) }

  static var isAvailable: Bool { readBrightness() != nil && setFn != nil }

  static func readBrightness(displayID: CGDirectDisplayID = CGMainDisplayID()) -> Float? {
    guard CGDisplayIsBuiltin(displayID) == 1, let getFn else { return nil }
    var value: Float = 0
    guard getFn(displayID, &value) == 0 else { return nil }
    return max(0, min(1, value))
  }

  static func adjustBrightness(
    displayID: CGDirectDisplayID, up: Bool, divisor: Float
  ) -> Float? {
    guard CGDisplayIsBuiltin(displayID) == 1,
      let target = adjustBrightness(
        displayID: displayID, up: up, divisor: divisor,
        read: { readBrightness(displayID: $0) },
        write: { setBrightness($1, displayID: $0) })
    else { return nil }
    return readBrightness(displayID: displayID) ?? target
  }

  static func adjustBrightness(
    displayID: CGDirectDisplayID, up: Bool, divisor: Float,
    read: (CGDirectDisplayID) -> Float?,
    write: (CGDirectDisplayID, Float) -> Bool
  ) -> Float? {
    guard let current = read(displayID) else { return nil }
    let target = HUDMath.stepped(current, up: up, divisor: divisor)
    guard write(displayID, target) else { return nil }
    return target
  }

  static func currentBrightness() -> Float { readBrightness() ?? 0 }

  @discardableResult
  static func setBrightness(
    _ value: Float, displayID: CGDirectDisplayID = CGMainDisplayID()
  ) -> Bool {
    guard CGDisplayIsBuiltin(displayID) == 1, let setFn,
      let original = readBrightness(displayID: displayID)
    else { return false }
    let clamped = max(0, min(1, value))
    guard setFn(displayID, clamped) == 0 else { return false }
    guard let readback = readBrightness(displayID: displayID), abs(readback - clamped) <= 0.02
    else {
      _ = setFn(displayID, original)
      return false
    }
    return true
  }
}

private final class DDCBrightnessBackend: @unchecked Sendable {
  private struct Route: Sendable {
    let bus: IOOptionBits
    let maximum: UInt16
  }

  private let lock = NSLock()
  private var routes: [String: Route] = [:]
  private let queue = DispatchQueue(
    label: "dev.islet.external-brightness", qos: .userInitiated,
    attributes: .concurrent)

  var backend: ExternalBrightnessBackend {
    ExternalBrightnessBackend(
      read: { display, completion in self.read(display, completion: completion) },
      write: { display, level, completion in
        self.write(display, level: level, completion: completion)
      })
  }

  private func read(
    _ display: ExternalBrightnessDisplay,
    completion: @escaping ExternalBrightnessBackend.Completion
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      let result = self.probe(display)
      completion(result.map(\.level))
    }
  }

  private func write(
    _ display: ExternalBrightnessDisplay, level: Float,
    completion: @escaping ExternalBrightnessBackend.Completion
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      let route = self.lock.withLock { self.routes[display.id] }
      guard let route else {
        completion(.failure(.unsupported("capability probe has no usable DDC route")))
        return
      }
      let result = self.withFramebuffer(for: display) { framebuffer in
        self.setBrightness(level, route: route, framebuffer: framebuffer)
      }
      completion(result.map { level })
    }
  }

  private func probe(
    _ display: ExternalBrightnessDisplay
  ) -> Result<(level: Float, route: Route), ExternalBrightnessFailure> {
    withFramebuffer(for: display) { framebuffer in
      var count: IOItemCount = 0
      let countResult = IOFBGetI2CInterfaceCount(framebuffer, &count)
      guard countResult == kIOReturnSuccess, count > 0 else {
        return .failure(
          .unsupported("connector exposes no public I2C interface (\(Self.ioResult(countResult)))"))
      }

      var lastFailure: ExternalBrightnessFailure = .rejected("brightness VCP code did not reply")
      for bus in 0..<count {
        let routeResult = readBrightness(framebuffer: framebuffer, bus: IOOptionBits(bus))
        switch routeResult {
        case .success(let reading):
          let route = Route(bus: IOOptionBits(bus), maximum: reading.maximum)
          lock.withLock { routes[display.id] = route }
          return .success((reading.level, route))
        case .failure(let failure):
          lastFailure = failure
        }
      }
      return .failure(lastFailure)
    }
  }

  private func withFramebuffer<Value>(
    for display: ExternalBrightnessDisplay,
    body: (io_service_t) -> Result<Value, ExternalBrightnessFailure>
  ) -> Result<Value, ExternalBrightnessFailure> {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &iterator) == kIOReturnSuccess
    else { return .failure(.unsupported("IOFramebuffer registry query failed")) }
    defer { IOObjectRelease(iterator) }

    var matches: [io_service_t] = []
    while case let framebuffer = IOIteratorNext(iterator), framebuffer != 0 {
      guard
        let unmanagedInfo = IODisplayCreateInfoDictionary(
          framebuffer, IOOptionBits(kIODisplayMatchingInfo))
      else {
        IOObjectRelease(framebuffer)
        continue
      }
      let info = unmanagedInfo.takeRetainedValue() as NSDictionary
      let vendor = (info[kDisplayVendorID] as? NSNumber)?.uint32Value
      let product = (info[kDisplayProductID] as? NSNumber)?.uint32Value
      let serial = (info[kDisplaySerialNumber] as? NSNumber)?.uint32Value ?? 0
      if vendor == display.vendorID, product == display.productID,
        display.serialNumber == 0 || serial == display.serialNumber
      {
        matches.append(framebuffer)
      } else {
        IOObjectRelease(framebuffer)
      }
    }
    defer {
      for match in matches { IOObjectRelease(match) }
    }
    guard matches.count == 1, let framebuffer = matches.first else {
      let reason =
        matches.isEmpty
        ? "no matching public IOFramebuffer"
        : "display identity is ambiguous; a hardware serial number is required"
      return .failure(.unsupported(reason))
    }
    return body(framebuffer)
  }

  private func readBrightness(
    framebuffer: io_service_t, bus: IOOptionBits
  ) -> Result<(level: Float, maximum: UInt16), ExternalBrightnessFailure> {
    withConnection(framebuffer: framebuffer, bus: bus) { connection in
      let requestBytes = Self.ddcPacket(payload: [0x01, 0x10])
      let sendResult = Self.send(connection: connection, bytes: requestBytes)
      guard sendResult == kIOReturnSuccess else {
        return .failure(.rejected("read request \(Self.ioResult(sendResult))"))
      }

      Thread.sleep(forTimeInterval: 0.04)
      var reply = [UInt8](repeating: 0, count: 11)
      let replyResult = Self.receive(connection: connection, bytes: &reply)
      guard replyResult == kIOReturnSuccess else {
        return .failure(.rejected("read reply \(Self.ioResult(replyResult))"))
      }
      guard reply.count >= 11, reply[0] == 0x6E, reply[2] == 0x02, reply[3] == 0,
        reply[4] == 0x10, reply.reduce(UInt8(0x50), ^) == 0
      else { return .failure(.rejected("invalid brightness VCP reply")) }
      let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
      let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
      guard maximum > 0, current <= maximum else {
        return .failure(.rejected("brightness VCP reply has an invalid range"))
      }
      return .success((Float(current) / Float(maximum), maximum))
    }
  }

  private func setBrightness(
    _ level: Float, route: Route, framebuffer: io_service_t
  ) -> Result<Void, ExternalBrightnessFailure> {
    withConnection(framebuffer: framebuffer, bus: route.bus) { connection in
      let clamped = max(0, min(1, level))
      let value = UInt16((Float(route.maximum) * clamped).rounded())
      let bytes = Self.ddcPacket(
        payload: [0x03, 0x10, UInt8(value >> 8), UInt8(value & 0xFF)])
      let result = Self.send(connection: connection, bytes: bytes)
      guard result == kIOReturnSuccess else {
        return .failure(.rejected("write request \(Self.ioResult(result))"))
      }
      return .success(())
    }
  }

  private func withConnection<Value>(
    framebuffer: io_service_t, bus: IOOptionBits,
    body: (IOI2CConnectRef) -> Result<Value, ExternalBrightnessFailure>
  ) -> Result<Value, ExternalBrightnessFailure> {
    var interface: io_service_t = 0
    let copyResult = IOFBCopyI2CInterfaceForBus(framebuffer, bus, &interface)
    guard copyResult == kIOReturnSuccess, interface != 0 else {
      return .failure(.rejected("I2C bus \(bus) unavailable (\(Self.ioResult(copyResult)))"))
    }
    defer { IOObjectRelease(interface) }

    var connection: IOI2CConnectRef?
    let openResult = IOI2CInterfaceOpen(interface, 0, &connection)
    guard openResult == kIOReturnSuccess, let connection else {
      return .failure(.rejected("I2C bus \(bus) could not open (\(Self.ioResult(openResult)))"))
    }
    defer { IOI2CInterfaceClose(connection, 0) }
    return body(connection)
  }

  private static func ddcPacket(payload: [UInt8]) -> [UInt8] {
    var packet = [UInt8(0x51), UInt8(0x80 | payload.count)] + payload
    packet.append(packet.reduce(UInt8(0x6E), ^))
    return packet
  }

  private static func send(connection: IOI2CConnectRef, bytes: [UInt8]) -> IOReturn {
    bytes.withUnsafeBytes { buffer in
      var request = IOI2CRequest()
      request.sendAddress = 0x6E
      request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
      request.sendBuffer = vm_address_t(UInt(bitPattern: buffer.baseAddress!))
      request.sendBytes = UInt32(buffer.count)
      let startResult = IOI2CSendRequest(connection, 0, &request)
      return startResult == kIOReturnSuccess ? request.result : startResult
    }
  }

  private static func receive(connection: IOI2CConnectRef, bytes: inout [UInt8]) -> IOReturn {
    let outcome: (result: IOReturn, count: Int) = bytes.withUnsafeMutableBytes { buffer in
      var request = IOI2CRequest()
      request.replyAddress = 0x6F
      request.replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
      request.replyBuffer = vm_address_t(UInt(bitPattern: buffer.baseAddress!))
      request.replyBytes = UInt32(buffer.count)
      let startResult = IOI2CSendRequest(connection, 0, &request)
      guard startResult == kIOReturnSuccess else { return (startResult, buffer.count) }
      return (request.result, Int(request.replyBytes))
    }
    if outcome.count < bytes.count { bytes.removeSubrange(outcome.count...) }
    return outcome.result
  }

  private static func ioResult(_ result: IOReturn) -> String {
    String(format: "0x%08X", UInt32(bitPattern: result))
  }
}
