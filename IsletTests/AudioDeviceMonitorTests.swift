import CoreAudio
import XCTest

@testable import Islet

@MainActor
final class AudioDeviceMonitorTests: XCTestCase {
  private final class FakeProvider: AudioDeviceProviding {
    var currentSelection: AudioDeviceSelection
    var startSucceeds = true
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var onChange: (@MainActor @Sendable () -> Void)?

    init(selection: AudioDeviceSelection) {
      currentSelection = selection
    }

    func start(onChange: @escaping @MainActor @Sendable () -> Void) -> Bool {
      startCount += 1
      guard startSucceeds else { return false }
      self.onChange = onChange
      return true
    }

    func stop() {
      stopCount += 1
      onChange = nil
    }

    func change(to selection: AudioDeviceSelection) {
      currentSelection = selection
      onChange?()
    }
  }

  private let speakers = SelectedAudioDevice(id: 1, name: "MacBook Pro Speakers")
  private let microphone = SelectedAudioDevice(id: 2, name: "MacBook Pro Microphone")
  private let airPods = SelectedAudioDevice(id: 3, name: "Ned's AirPods Pro")
  private let display = SelectedAudioDevice(id: 4, name: "Studio Display")

  func testInputChangeProducesAnInputEvent() {
    let provider = FakeProvider(
      selection: AudioDeviceSelection(input: microphone, output: speakers))
    var events: [SystemEvent] = []
    let monitor = AudioDeviceMonitor(provider: provider, emit: { events.append($0) })
    monitor.start()

    provider.change(to: AudioDeviceSelection(input: airPods, output: speakers))
    monitor.flushPendingChange()

    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0].title, "Ned's AirPods Pro")
    XCTAssertEqual(events[0].subtitle, "Input selected")
    XCTAssertEqual(events[0].icon, "mic.fill")
    XCTAssertEqual(events[0].sourceID, "audiodevice")
  }

  func testOutputChangeProducesAnOutputEvent() {
    let provider = FakeProvider(
      selection: AudioDeviceSelection(input: microphone, output: speakers))
    var events: [SystemEvent] = []
    let monitor = AudioDeviceMonitor(provider: provider, emit: { events.append($0) })
    monitor.start()

    provider.change(to: AudioDeviceSelection(input: microphone, output: display))
    monitor.flushPendingChange()

    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0].title, "Studio Display")
    XCTAssertEqual(events[0].subtitle, "Output selected")
    XCTAssertEqual(events[0].announcement, "Studio Display selected for audio output")
  }

  func testSeparateHeadsetCallbacksProduceOneCombinedEvent() {
    let provider = FakeProvider(
      selection: AudioDeviceSelection(input: microphone, output: speakers))
    var events: [SystemEvent] = []
    let monitor = AudioDeviceMonitor(provider: provider, emit: { events.append($0) })
    monitor.start()

    provider.change(to: AudioDeviceSelection(input: airPods, output: speakers))
    provider.change(to: AudioDeviceSelection(input: airPods, output: airPods))
    monitor.flushPendingChange()

    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0].title, "Ned's AirPods Pro")
    XCTAssertEqual(events[0].subtitle, "Input and output selected")
    XCTAssertEqual(
      events[0].announcement, "Ned's AirPods Pro selected for audio input and output")
  }

  func testDifferentInputAndOutputNamesRemainClearInCombinedCopy() {
    let provider = FakeProvider(
      selection: AudioDeviceSelection(input: microphone, output: speakers))
    var events: [SystemEvent] = []
    let monitor = AudioDeviceMonitor(provider: provider, emit: { events.append($0) })
    monitor.start()

    provider.change(to: AudioDeviceSelection(input: airPods, output: speakers))
    provider.change(to: AudioDeviceSelection(input: airPods, output: display))
    monitor.flushPendingChange()

    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0].title, "Audio devices changed")
    XCTAssertEqual(events[0].subtitle, "Ned's AirPods Pro input, Studio Display output")
  }

  func testDuplicateCallbackDoesNotProduceAnEvent() {
    let selection = AudioDeviceSelection(input: microphone, output: speakers)
    let provider = FakeProvider(selection: selection)
    var events: [SystemEvent] = []
    let monitor = AudioDeviceMonitor(provider: provider, emit: { events.append($0) })
    monitor.start()

    provider.change(to: selection)
    monitor.flushPendingChange()

    XCTAssertTrue(events.isEmpty)
  }

  func testMissingDeviceIsRememberedWithoutEmittingAndReconnectEmits() {
    let initial = AudioDeviceSelection(input: microphone, output: airPods)
    let provider = FakeProvider(selection: initial)
    var events: [SystemEvent] = []
    let monitor = AudioDeviceMonitor(provider: provider, emit: { events.append($0) })
    monitor.start()

    provider.change(to: AudioDeviceSelection(input: microphone, output: nil))
    monitor.flushPendingChange()
    XCTAssertTrue(events.isEmpty)

    provider.change(to: initial)
    monitor.flushPendingChange()
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0].subtitle, "Output selected")
  }

  func testStartAndStopOwnExactlyOneProviderRegistration() {
    let provider = FakeProvider(selection: .empty)
    let monitor = AudioDeviceMonitor(provider: provider, emit: { _ in })

    monitor.start()
    monitor.start()
    XCTAssertTrue(monitor.isRunning)
    XCTAssertEqual(provider.startCount, 1)

    monitor.stop()
    monitor.stop()
    XCTAssertFalse(monitor.isRunning)
    XCTAssertEqual(provider.stopCount, 1)

    monitor.start()
    XCTAssertTrue(monitor.isRunning)
    XCTAssertEqual(provider.startCount, 2)
  }

  func testFailedProviderStartLeavesMonitorStoppedAndRestartable() {
    let provider = FakeProvider(selection: .empty)
    provider.startSucceeds = false
    let monitor = AudioDeviceMonitor(provider: provider, emit: { _ in })

    monitor.start()
    XCTAssertFalse(monitor.isRunning)

    provider.startSucceeds = true
    monitor.start()
    XCTAssertTrue(monitor.isRunning)
    XCTAssertEqual(provider.startCount, 2)
  }

  func testStopDropsPendingChange() {
    let provider = FakeProvider(
      selection: AudioDeviceSelection(input: microphone, output: speakers))
    var events: [SystemEvent] = []
    let monitor = AudioDeviceMonitor(provider: provider, emit: { events.append($0) })
    monitor.start()

    provider.change(to: AudioDeviceSelection(input: airPods, output: speakers))
    monitor.stop()
    monitor.flushPendingChange()

    XCTAssertTrue(events.isEmpty)
  }
}
