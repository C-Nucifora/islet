import XCTest

@testable import Islet

@MainActor
final class VPNEventSourceTests: XCTestCase {
  private final class StubMonitor: TunnelNetworkChangeMonitoring {
    var startResults: [Bool]
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (@MainActor () -> Void)?

    init(startResults: [Bool]) {
      self.startResults = startResults
    }

    func start(handler: @escaping @MainActor () -> Void) -> Bool {
      startCount += 1
      self.handler = handler
      return startResults.isEmpty ? false : startResults.removeFirst()
    }

    func stop() {
      stopCount += 1
      handler = nil
    }

    func sendChange() {
      handler?()
    }
  }

  func testDynamicStoreBurstReadsInterfacesOnce() async {
    let monitor = StubMonitor(startResults: [true])
    var reads = 0
    var interfaces = ["en0"]
    var events: [SystemEvent] = []
    let source = VPNEventSource(
      interfaceReader: {
        reads += 1
        return interfaces
      },
      monitor: monitor,
      debounceDuration: .milliseconds(10),
      emitter: { events.append($0) })
    source.start()
    defer { source.stop() }
    XCTAssertEqual(reads, 1)

    interfaces = ["en0", "utun4"]
    monitor.sendChange()
    monitor.sendChange()
    monitor.sendChange()
    try? await Task.sleep(for: .milliseconds(40))

    XCTAssertEqual(reads, 2)
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.title, "Network tunnel up")
    XCTAssertEqual(events.first?.subtitle, "utun4")
  }

  func testReconnectReportsDownThenUp() async {
    let monitor = StubMonitor(startResults: [true])
    var interfaces = ["utun2"]
    var events: [SystemEvent] = []
    let source = VPNEventSource(
      interfaceReader: { interfaces }, monitor: monitor,
      debounceDuration: .milliseconds(5), emitter: { events.append($0) })
    source.start()
    defer { source.stop() }

    interfaces = []
    monitor.sendChange()
    try? await Task.sleep(for: .milliseconds(20))
    interfaces = ["utun7"]
    monitor.sendChange()
    try? await Task.sleep(for: .milliseconds(20))

    XCTAssertEqual(events.map(\.title), ["Network tunnel down", "Network tunnel up"])
    XCTAssertEqual(events.map(\.subtitle), ["utun2", "utun7"])
  }

  func testWakeReconcilesMissedChangeImmediately() {
    let monitor = StubMonitor(startResults: [true, true])
    var interfaces = [String]()
    var events: [SystemEvent] = []
    let source = VPNEventSource(
      interfaceReader: { interfaces }, monitor: monitor, emitter: { events.append($0) })
    source.start()
    defer { source.stop() }

    interfaces = ["utun9"]
    source.handleWake()

    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.title, "Network tunnel up")
    XCTAssertEqual(events.first?.subtitle, "utun9")
    XCTAssertEqual(monitor.startCount, 2)
    XCTAssertEqual(monitor.stopCount, 1)
    XCTAssertEqual(source.cadence, .subscribedRecovery)
  }

  func testFailedSubscriptionUsesPollingAndRecoveryRepairsIt() {
    let monitor = StubMonitor(startResults: [false, true])
    var interfaces = [String]()
    var events: [SystemEvent] = []
    let source = VPNEventSource(
      interfaceReader: { interfaces }, monitor: monitor, emitter: { events.append($0) })
    source.start()
    defer { source.stop() }
    XCTAssertEqual(source.cadence, .pollingFallback)
    XCTAssertEqual(monitor.startCount, 1)

    interfaces = ["ipsec0"]
    source.handleRecoveryTick()

    XCTAssertEqual(events.first?.title, "Network tunnel up")
    XCTAssertEqual(events.first?.subtitle, "ipsec0")
    XCTAssertEqual(monitor.startCount, 2)
    XCTAssertEqual(source.cadence, .subscribedRecovery)
  }

  func testSuccessfulSubscriptionUsesSlowRecoveryCadence() {
    let policy = EnergyPolicy(mode: .live, systemLowPowerMode: false)
    XCTAssertEqual(
      TunnelObservationCadence.pollingFallback.interval(for: policy),
      policy.tunnelPollingInterval)
    XCTAssertEqual(
      TunnelObservationCadence.subscribedRecovery.interval(for: policy),
      5 * 60)
  }

  func testAmbiguousUtunKeepsGenericNetworkTunnelWording() async {
    let monitor = StubMonitor(startResults: [true])
    var interfaces = [String]()
    var event: SystemEvent?
    let source = VPNEventSource(
      interfaceReader: { interfaces }, monitor: monitor,
      debounceDuration: .milliseconds(5), emitter: { event = $0 })
    source.start()
    defer { source.stop() }

    interfaces = ["utun12"]
    monitor.sendChange()
    try? await Task.sleep(for: .milliseconds(20))

    XCTAssertEqual(event?.title, "Network tunnel up")
    XCTAssertEqual(event?.subtitle, "utun12")
    XCTAssertEqual(event?.announcement, "Network tunnel up")
    XCTAssertFalse(event?.title.contains("VPN") ?? true)
  }
}
