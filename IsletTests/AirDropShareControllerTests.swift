import XCTest

@testable import Islet

final class AirDropShareControllerTests: XCTestCase {
  @MainActor
  func testUnavailableServiceDisablesTheActionWithoutTryingToStart() {
    var starts = 0
    let controller = AirDropShareController(
      serviceAvailable: { false },
      startShare: { _, _ in
        starts += 1
        return .started
      })

    XCTAssertEqual(controller.state, .unavailable)
    XCTAssertFalse(controller.isActionEnabled)
    controller.share([URL(fileURLWithPath: "/Shelf/report.pdf")])
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(controller.state, .unavailable)
  }

  @MainActor
  func testSecondTapDoesNotStartAnOverlappingShare() {
    var starts = 0
    var finish: ((AirDropShareOutcome) -> Void)?
    let controller = AirDropShareController(
      serviceAvailable: { true },
      startShare: { _, completion in
        starts += 1
        finish = completion
        return .started
      })
    let urls = [URL(fileURLWithPath: "/Shelf/report.pdf")]

    controller.share(urls)
    controller.share(urls)

    XCTAssertEqual(starts, 1)
    XCTAssertEqual(controller.state, .sharing)
    finish?(.cancelled)
    XCTAssertEqual(controller.state, .cancelled)
  }

  @MainActor
  func testCancellationKeepsTheControllerReadyForRetry() {
    var starts = 0
    var finish: ((AirDropShareOutcome) -> Void)?
    let controller = AirDropShareController(
      serviceAvailable: { true },
      startShare: { _, completion in
        starts += 1
        finish = completion
        return .started
      })
    let urls = [URL(fileURLWithPath: "/Shelf/report.pdf")]

    controller.share(urls)
    finish?(.cancelled)
    controller.retry(urls)

    XCTAssertEqual(starts, 2)
    XCTAssertEqual(controller.state, .sharing)
  }

  @MainActor
  func testFailureIsVisibleAndCanBeDismissedWithoutChangingTheShelfURLs() {
    var finish: ((AirDropShareOutcome) -> Void)?
    let controller = AirDropShareController(
      serviceAvailable: { true },
      startShare: { _, completion in
        finish = completion
        return .started
      })
    let urls = [
      URL(fileURLWithPath: "/Shelf/report.pdf"),
      URL(fileURLWithPath: "/Shelf/notes.txt"),
    ]

    controller.share(urls)
    finish?(.failed("The receiving device is no longer available."))

    XCTAssertEqual(controller.state, .failed("The receiving device is no longer available."))
    controller.dismissFeedback()
    XCTAssertEqual(controller.state, .ready)
    XCTAssertEqual(urls.map(\.path), ["/Shelf/report.pdf", "/Shelf/notes.txt"])
  }

  func testCancellationErrorsAreClassifiedWithoutMatchingTheirLocalizedText() {
    XCTAssertEqual(
      AirDropShareOutcome.from(error: URLError(.cancelled)),
      .cancelled)
    XCTAssertEqual(
      AirDropShareOutcome.from(error: CocoaError(.userCancelled)),
      .cancelled)
  }

  @MainActor
  func testAnExistingShareStaysDisabledUntilTheAppKitObserverFinishesIt() {
    let controller = AirDropShareController(
      serviceAvailable: { true },
      startShare: { _, _ in .busy })

    controller.share([URL(fileURLWithPath: "/Shelf/report.pdf")])

    XCTAssertEqual(controller.state, .busy)
    XCTAssertFalse(controller.isActionEnabled)
  }

  @MainActor
  func testServiceDisappearingBetweenAvailabilityCheckAndShareDisablesTheAction() {
    let controller = AirDropShareController(
      serviceAvailable: { true },
      startShare: { _, _ in .unavailable })

    controller.share([URL(fileURLWithPath: "/Shelf/report.pdf")])

    XCTAssertEqual(controller.state, .unavailable)
    XCTAssertFalse(controller.isServiceAvailable)
    XCTAssertFalse(controller.isActionEnabled)
  }

  @MainActor
  func testSuccessClearsTheInFlightState() {
    var finish: ((AirDropShareOutcome) -> Void)?
    let controller = AirDropShareController(
      serviceAvailable: { true },
      startShare: { _, completion in
        finish = completion
        return .started
      })

    controller.share([URL(fileURLWithPath: "/Shelf/report.pdf")])
    finish?(.shared)

    XCTAssertEqual(controller.state, .ready)
    XCTAssertTrue(controller.isActionEnabled)
  }
}
