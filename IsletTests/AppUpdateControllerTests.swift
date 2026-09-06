import Foundation
import Sparkle
import XCTest

@testable import Islet

final class AppUpdateControllerTests: XCTestCase {
  private let validPublicKey = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="

  func testValidConfigurationRequiresTheCompleteTrustChain() throws {
    let configuration = try AppUpdateConfiguration(infoDictionary: validInfoDictionary())

    XCTAssertEqual(
      configuration.feedURL.absoluteString,
      "https://github.com/C-Nucifora/islet/releases/latest/download/appcast.xml")
    XCTAssertEqual(configuration.publicKey, validPublicKey)
    XCTAssertEqual(configuration.channel, .stable)
  }

  func testMissingOrPlaceholderPublicKeysFailClosed() {
    var missing = validInfoDictionary()
    missing.removeValue(forKey: AppUpdateConfiguration.publicKeyKey)
    XCTAssertThrowsError(try AppUpdateConfiguration(infoDictionary: missing)) { error in
      XCTAssertEqual(
        error as? AppUpdateConfigurationError,
        .missingValue(AppUpdateConfiguration.publicKeyKey))
    }

    var placeholder = validInfoDictionary()
    placeholder[AppUpdateConfiguration.publicKeyKey] = "CONFIGURATION_REQUIRED"
    XCTAssertThrowsError(try AppUpdateConfiguration(infoDictionary: placeholder)) { error in
      XCTAssertEqual(error as? AppUpdateConfigurationError, .invalidPublicKey)
    }

    var shortKey = validInfoDictionary()
    shortKey[AppUpdateConfiguration.publicKeyKey] = Data(repeating: 0, count: 31)
      .base64EncodedString()
    XCTAssertThrowsError(try AppUpdateConfiguration(infoDictionary: shortKey)) { error in
      XCTAssertEqual(error as? AppUpdateConfigurationError, .invalidPublicKey)
    }

    var whitespaceKey = validInfoDictionary()
    whitespaceKey[AppUpdateConfiguration.publicKeyKey] = "\(validPublicKey)\n"
    XCTAssertThrowsError(try AppUpdateConfiguration(infoDictionary: whitespaceKey)) { error in
      XCTAssertEqual(error as? AppUpdateConfigurationError, .invalidPublicKey)
    }
  }

  func testInsecureOrCredentialedFeedsFailClosed() {
    for feed in [
      "http://github.com/C-Nucifora/islet/appcast.xml",
      "https://user:password@github.com/C-Nucifora/islet/appcast.xml",
    ] {
      var info = validInfoDictionary()
      info[AppUpdateConfiguration.feedURLKey] = feed
      XCTAssertThrowsError(try AppUpdateConfiguration(infoDictionary: info)) { error in
        XCTAssertEqual(error as? AppUpdateConfigurationError, .insecureFeedURL)
      }
    }

    var unexpectedFeed = validInfoDictionary()
    unexpectedFeed[AppUpdateConfiguration.feedURLKey] =
      "https://updates.example.com/islet/appcast.xml"
    XCTAssertThrowsError(try AppUpdateConfiguration(infoDictionary: unexpectedFeed)) { error in
      XCTAssertEqual(error as? AppUpdateConfigurationError, .unexpectedFeedURL)
    }
  }

  func testVerificationControlsCannotBeRelaxed() {
    var unsignedFeed = validInfoDictionary()
    unsignedFeed[AppUpdateConfiguration.signedFeedKey] = false
    XCTAssertThrowsError(try AppUpdateConfiguration(infoDictionary: unsignedFeed)) { error in
      XCTAssertEqual(error as? AppUpdateConfigurationError, .signedFeedRequired)
    }

    var verifyAfterExtraction = validInfoDictionary()
    verifyAfterExtraction[AppUpdateConfiguration.verifyBeforeExtractionKey] = false
    XCTAssertThrowsError(try AppUpdateConfiguration(infoDictionary: verifyAfterExtraction)) {
      error in
      XCTAssertEqual(
        error as? AppUpdateConfigurationError, .preExtractionVerificationRequired)
    }

    var expiringFailure = validInfoDictionary()
    expiringFailure[AppUpdateConfiguration.signedFeedFailureExpirationKey] = 1
    XCTAssertThrowsError(try AppUpdateConfiguration(infoDictionary: expiringFailure)) { error in
      XCTAssertEqual(error as? AppUpdateConfigurationError, .signedFeedFailureMayExpire)
    }
  }

  func testAutomaticChecksRemainOptInAndInstallsRemainManualByDefault() {
    var forcedChecks = validInfoDictionary()
    forcedChecks[AppUpdateConfiguration.automaticChecksKey] = true
    XCTAssertThrowsError(try AppUpdateConfiguration(infoDictionary: forcedChecks)) { error in
      XCTAssertEqual(error as? AppUpdateConfigurationError, .automaticCheckDefaultOverridden)
    }

    var automaticInstall = validInfoDictionary()
    automaticInstall[AppUpdateConfiguration.automaticInstallationKey] = true
    XCTAssertThrowsError(try AppUpdateConfiguration(infoDictionary: automaticInstall)) { error in
      XCTAssertEqual(error as? AppUpdateConfigurationError, .automaticInstallationEnabled)
    }
  }

  func testUnknownChannelsAndHiddenReleaseNotesFailClosed() {
    var unknownChannel = validInfoDictionary()
    unknownChannel[AppUpdateConfiguration.channelKey] = "nightly"
    XCTAssertThrowsError(try AppUpdateConfiguration(infoDictionary: unknownChannel)) { error in
      XCTAssertEqual(
        error as? AppUpdateConfigurationError,
        .unsupportedChannel("nightly"))
    }

    var hiddenNotes = validInfoDictionary()
    hiddenNotes[AppUpdateConfiguration.showReleaseNotesKey] = false
    XCTAssertThrowsError(try AppUpdateConfiguration(infoDictionary: hiddenNotes)) { error in
      XCTAssertEqual(error as? AppUpdateConfigurationError, .releaseNotesRequired)
    }
  }

  func testVersionAndStateTextAreDeterministic() {
    let version = AppUpdateVersion(infoDictionary: [
      "CFBundleShortVersionString": "1.2.3",
      "CFBundleVersion": "456",
    ])

    XCTAssertEqual(version.text, "1.2.3 (456)")
    XCTAssertEqual(AppUpdateState.ready.summary, "Ready")
    XCTAssertEqual(
      AppUpdateState.updateAvailable("1.2.4").summary,
      "Version 1.2.4 is available")
    XCTAssertEqual(
      AppUpdateState.readyToInstall("1.2.4").summary,
      "Version 1.2.4 is ready to install")
    XCTAssertTrue(AppUpdateState.failed("Bad signature").isFailure)
  }

  func testSparkleNoUpdateAndCancellationAreNotReportedAsFailures() {
    let noUpdate = NSError(
      domain: SUSparkleErrorDomain,
      code: Int(SUError.noUpdateError.rawValue))
    let cancelled = NSError(
      domain: SUSparkleErrorDomain,
      code: Int(SUError.installationCanceledError.rawValue))

    XCTAssertEqual(AppUpdateController.state(after: noUpdate), .upToDate)
    XCTAssertEqual(AppUpdateController.state(after: cancelled), .ready)
  }

  func testSignatureFailureIsVisible() {
    let failure = NSError(
      domain: SUSparkleErrorDomain,
      code: Int(SUError.signatureError.rawValue),
      userInfo: [NSLocalizedDescriptionKey: "The update signature is invalid."])

    XCTAssertEqual(
      AppUpdateController.state(after: failure),
      .failed("The update signature is invalid."))
  }

  private func validInfoDictionary() -> [String: Any] {
    [
      AppUpdateConfiguration.feedURLKey:
        "https://github.com/C-Nucifora/islet/releases/latest/download/appcast.xml",
      AppUpdateConfiguration.publicKeyKey: validPublicKey,
      AppUpdateConfiguration.signedFeedKey: true,
      AppUpdateConfiguration.verifyBeforeExtractionKey: true,
      AppUpdateConfiguration.signedFeedFailureExpirationKey: 0,
      AppUpdateConfiguration.automaticInstallationKey: false,
      AppUpdateConfiguration.showReleaseNotesKey: true,
      AppUpdateConfiguration.channelKey: "stable",
    ]
  }
}
