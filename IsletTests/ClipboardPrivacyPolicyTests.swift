import AppKit
import XCTest

@testable import Islet

final class ClipboardPrivacyPolicyTests: XCTestCase {
  func testPrivacyIdentifiersAreNormalizedDeduplicatedAndBounded() {
    XCTAssertEqual(
      ClipboardIdentifierPolicy.bundleIdentifiers([
        " COM.Example.Passwords ", "com.example.passwords", "bad identifier", "",
      ]),
      ["com.example.passwords"])
    XCTAssertNil(
      ClipboardIdentifierPolicy.bundleIdentifier(
        String(repeating: "a", count: ClipboardIdentifierPolicy.maximumBundleIdentifierBytes + 1)))
    XCTAssertEqual(
      ClipboardIdentifierPolicy.focusIdentifiers([" Work ", "work", "Personal Focus"]),
      ["work", "personal focus"])
  }

  @MainActor
  func testDefaultsStoreRestoresPrivacyRulesAfterOwnerRecreation() {
    var firstStore: DefaultsClipboardPrivacyStore? = DefaultsClipboardPrivacyStore()
    let original = firstStore!.load()
    defer { DefaultsClipboardPrivacyStore().save(original) }

    let expected = ClipboardPrivacyConfiguration(
      excludedBundleIdentifiers: ["com.example.passwords"],
      pausedFocusIdentifiers: ["work"], clearHistoryOnPause: false, manuallyPaused: true,
      pausedUntil: Date(timeIntervalSince1970: 2_000_000), pausedLoginSession: "session-42")
    firstStore!.save(expected)
    firstStore = nil

    let relaunchedStore = DefaultsClipboardPrivacyStore()
    XCTAssertEqual(relaunchedStore.load(), expected)
  }

  func testEvaluatorFailsClosedForUnknownAppsAndComposesAppAndFocusRules() throws {
    let allowed = try XCTUnwrap(
      ClipboardApplicationIdentity(bundleIdentifier: "com.example.editor", name: "Editor"))
    let excluded = try XCTUnwrap(
      ClipboardApplicationIdentity(bundleIdentifier: "COM.EXAMPLE.SECRETS", name: "Secrets"))
    let configuration = ClipboardPrivacyConfiguration(
      excludedBundleIdentifiers: ["com.example.secrets"],
      pausedFocusIdentifiers: ["work"])

    XCTAssertEqual(
      ClipboardPrivacyEvaluator.evaluate(
        configuration: configuration, context: ClipboardCaptureContext(), now: .distantPast,
        loginSession: "1"
      ).reason,
      .unidentifiedApplication)
    XCTAssertEqual(
      ClipboardPrivacyEvaluator.evaluate(
        configuration: configuration,
        context: ClipboardCaptureContext(application: excluded, focusIdentifier: "work"),
        now: .distantPast, loginSession: "1"
      ).reason,
      .excludedApplication(excluded))
    XCTAssertEqual(
      ClipboardPrivacyEvaluator.evaluate(
        configuration: configuration,
        context: ClipboardCaptureContext(application: allowed, focusIdentifier: "Work"),
        now: .distantPast, loginSession: "1"
      ).reason,
      .focusMode("work"))
    XCTAssertNil(
      ClipboardPrivacyEvaluator.evaluate(
        configuration: configuration,
        context: ClipboardCaptureContext(application: allowed, focusIdentifier: nil),
        now: .distantPast, loginSession: "1"
      ).reason)
  }

  @MainActor
  func testAppSwitchDropsCopyBeforeReevaluatingTheNewFrontmostApp() throws {
    let pasteboard = testPasteboard()
    let allowed = try identity("com.example.editor", "Editor")
    let excluded = try identity("com.example.secrets", "Secrets")
    let store = TestClipboardPrivacyStore(
      ClipboardPrivacyConfiguration(excludedBundleIdentifiers: [excluded.bundleIdentifier]))
    let context = TestClipboardContextMonitor(application: allowed)
    let model = ClipboardModel(
      pasteboard: pasteboard, privacyStore: store, contextMonitor: context,
      loginSession: { "login" })
    model.start()
    defer { model.stop() }

    write("copied just before exclusion", to: pasteboard)
    context.change(application: excluded)
    model.pollNow()
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertEqual(model.pauseReason, .excludedApplication(excluded))

    write("copied while excluded", to: pasteboard)
    context.change(application: allowed)
    model.pollNow()
    XCTAssertTrue(model.items.isEmpty)

    write("ordinary allowed copy", to: pasteboard)
    model.pollNow()
    XCTAssertEqual(model.items.map(\.preview), ["ordinary allowed copy"])
  }

  @MainActor
  func testAppChangeWhileReadingACopyRejectsThatGeneration() throws {
    let pasteboard = testPasteboard()
    let allowed = try identity("com.example.editor", "Editor")
    let excluded = try identity("com.example.secrets", "Secrets")
    let store = TestClipboardPrivacyStore(
      ClipboardPrivacyConfiguration(
        excludedBundleIdentifiers: [excluded.bundleIdentifier], clearHistoryOnPause: false))
    let context = TestClipboardContextMonitor(application: allowed)
    context.refreshResults = [.noChange, .change(excluded)]
    let model = ClipboardModel(
      pasteboard: pasteboard, privacyStore: store, contextMonitor: context,
      loginSession: { "login" })
    model.start()
    defer { model.stop() }

    write("ambiguous copy", to: pasteboard)
    model.pollNow()

    XCTAssertTrue(model.items.isEmpty)
    XCTAssertEqual(model.pauseReason, .excludedApplication(excluded))
  }

  @MainActor
  func testUnknownApplicationStopsCaptureAndClearsHistoryByDefault() throws {
    let pasteboard = testPasteboard()
    let context = TestClipboardContextMonitor(
      application: try identity("com.example.editor", "Editor"))
    let model = ClipboardModel(
      pasteboard: pasteboard, privacyStore: TestClipboardPrivacyStore(),
      contextMonitor: context, loginSession: { "login" })
    model.start()
    defer { model.stop() }

    write("ordinary copy", to: pasteboard)
    model.pollNow()
    XCTAssertEqual(model.items.count, 1)

    context.changeToUnknownApplication()
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertEqual(model.pauseReason, .unidentifiedApplication)
    write("must not be retained", to: pasteboard)
    model.pollNow()
    XCTAssertTrue(model.items.isEmpty)
  }

  @MainActor
  func testTimedPauseSkipsCopiesAndResumesWithoutBackfill() throws {
    let pasteboard = testPasteboard()
    let store = TestClipboardPrivacyStore()
    let context = TestClipboardContextMonitor(
      application: try identity("com.example.editor", "Editor"))
    var now = Date(timeIntervalSince1970: 2_000_000)
    let model = ClipboardModel(
      pasteboard: pasteboard, privacyStore: store, contextMonitor: context, now: { now },
      loginSession: { "login" })
    model.start()
    defer { model.stop() }

    model.pause(for: 5 * 60)
    write("copy during pause", to: pasteboard)
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertNotNil(store.configuration.pausedUntil)

    // Simulate polling being suspended for the whole pause (for example while the Mac sleeps).
    now.addTimeInterval(5 * 60 + 1)
    model.pollNow()
    XCTAssertFalse(model.isPaused)
    XCTAssertNil(store.configuration.pausedUntil)
    XCTAssertTrue(model.items.isEmpty)

    write("copy after expiry", to: pasteboard)
    model.pollNow()
    XCTAssertEqual(model.items.map(\.preview), ["copy after expiry"])
  }

  @MainActor
  func testExclusionsAndLoginPausePersistWithoutClipboardContents() throws {
    let pasteboard = testPasteboard()
    let excluded = try identity("com.example.secrets", "Secrets")
    let store = TestClipboardPrivacyStore(
      ClipboardPrivacyConfiguration(excludedBundleIdentifiers: [excluded.bundleIdentifier]))

    var first: ClipboardModel? = ClipboardModel(
      pasteboard: pasteboard, privacyStore: store,
      contextMonitor: TestClipboardContextMonitor(application: excluded),
      loginSession: { "login-a" })
    first?.start()
    first?.pauseUntilNextLogin()
    write("never persisted", to: pasteboard)
    first?.pollNow()
    XCTAssertTrue(first?.items.isEmpty == true)
    first?.stop()
    first = nil

    let relaunched = ClipboardModel(
      pasteboard: pasteboard, privacyStore: store,
      contextMonitor: TestClipboardContextMonitor(application: excluded),
      loginSession: { "login-a" })
    relaunched.start()
    XCTAssertTrue(relaunched.items.isEmpty)
    XCTAssertEqual(relaunched.pauseReason, .untilNextLogin)
    XCTAssertEqual(store.configuration.excludedBundleIdentifiers, [excluded.bundleIdentifier])
    relaunched.stop()

    let nextLogin = ClipboardModel(
      pasteboard: pasteboard, privacyStore: store,
      contextMonitor: TestClipboardContextMonitor(
        application: try identity("com.example.editor", "Editor")),
      loginSession: { "login-b" })
    nextLogin.start()
    XCTAssertFalse(nextLogin.isPaused)
    XCTAssertNil(store.configuration.pausedLoginSession)
    nextLogin.stop()
  }

  @MainActor
  func testExplicitKeepHistoryChoiceAppliesToContextRules() throws {
    let pasteboard = testPasteboard()
    let store = TestClipboardPrivacyStore(
      ClipboardPrivacyConfiguration(
        pausedFocusIdentifiers: ["work"], clearHistoryOnPause: false))
    let context = TestClipboardContextMonitor(
      application: try identity("com.example.editor", "Editor"))
    let model = ClipboardModel(
      pasteboard: pasteboard, privacyStore: store, contextMonitor: context,
      loginSession: { "login" })
    model.start()
    defer { model.stop() }

    write("keep this existing item", to: pasteboard)
    model.pollNow()
    context.change(focusIdentifier: "Work")
    XCTAssertEqual(model.items.map(\.preview), ["keep this existing item"])
    XCTAssertEqual(model.pauseReason, .focusMode("work"))

    write("do not add this item", to: pasteboard)
    model.pollNow()
    XCTAssertEqual(model.items.map(\.preview), ["keep this existing item"])
  }

  func testSensitivePasteboardTypesAreRejectedCaseInsensitively() {
    XCTAssertFalse(ClipboardPrivacyPolicy.permits(types: ["org.nspasteboard.ConcealedType"]))
    XCTAssertFalse(ClipboardPrivacyPolicy.permits(types: ["ORG.NSPASTEBOARD.CONCEALEDTYPE"]))
    XCTAssertTrue(ClipboardPrivacyPolicy.permits(types: ["public.utf8-plain-text"]))
  }

  func testHighConfidenceSecretsAreRejected() {
    // Assemble provider-like examples at runtime so repository secret scanning never sees a
    // credential-shaped literal, even though every value here is synthetic test data.
    XCTAssertFalse(
      ClipboardPrivacyPolicy.permits(text: ["gh", "p_", "abcdefghijklmnopqrstuvwxyz1234"].joined()))
    XCTAssertFalse(
      ClipboardPrivacyPolicy.permits(text: ["AS", "IA", "1234567890123456"].joined()))
    XCTAssertFalse(
      ClipboardPrivacyPolicy.permits(text: ["xo", "xb-", "1234567890-abcdefghijklmnop"].joined()))
    XCTAssertFalse(
      ClipboardPrivacyPolicy.permits(text: ["sk", "_live_", "abcdefghijklmnopqrstuv"].joined()))
  }

  func testOrdinaryTextIsPermitted() {
    XCTAssertTrue(ClipboardPrivacyPolicy.permits(text: "Meet me at 9:30 tomorrow"))
    XCTAssertTrue(ClipboardPrivacyPolicy.permits(text: "123456"))
  }

  func testImagePayloadRetainsRepresentationType() {
    let payload = ClipboardItem.ImagePayload(
      data: Data([1, 2, 3]), pasteboardTypeRawValue: "public.png")
    let item = ClipboardItem(kind: .image(payload), date: .distantPast)
    XCTAssertEqual(item.retainedByteCount, 3)
    XCTAssertEqual(payload.pasteboardTypeRawValue, "public.png")
  }

  func testMultipleFileURLsRoundTripInOrder() throws {
    let source = NSPasteboard(name: NSPasteboard.Name("islet-tests-source-\(UUID().uuidString)"))
    let destination = NSPasteboard(
      name: NSPasteboard.Name("islet-tests-destination-\(UUID().uuidString)"))
    let urls = [
      URL(fileURLWithPath: "/tmp/first file.txt"),
      URL(fileURLWithPath: "/tmp/second file.txt"),
      URL(fileURLWithPath: "/tmp/third file.txt"),
    ]

    source.clearContents()
    XCTAssertTrue(ClipboardFileURLs.write(urls, to: source))
    let capturedURLs = ClipboardFileURLs.read(from: source)
    XCTAssertEqual(capturedURLs, urls)
    XCTAssertTrue(ClipboardPrivacyPolicy.permits(fileURLs: capturedURLs))

    destination.clearContents()
    XCTAssertTrue(
      ClipboardPasteboardTransaction.replace(on: destination) {
        ClipboardFileURLs.write(capturedURLs, to: destination)
      })
    XCTAssertEqual(ClipboardFileURLs.read(from: destination), urls)
  }

  func testFileSetPreviewAndRetentionUseOnlyURLMetadata() {
    let urls = [
      URL(fileURLWithPath: "/tmp/first.txt"),
      URL(fileURLWithPath: "/tmp/second.txt"),
    ]
    let item = ClipboardItem(kind: .fileURLs(urls), date: .distantPast)

    XCTAssertEqual(item.preview, "first.txt")
    XCTAssertEqual(item.detail, "2 files")
    XCTAssertEqual(
      item.retainedByteCount,
      urls.reduce(0) { $0 + ClipboardPrivacyPolicy.fileURLByteCount($1) })
  }

  func testFileSetPolicyRejectsEmptyRemoteAndOversizedURLLists() {
    XCTAssertFalse(ClipboardPrivacyPolicy.permits(fileURLs: []))
    XCTAssertFalse(
      ClipboardPrivacyPolicy.permits(fileURLs: [URL(string: "https://example.com/file")!]))

    let oversizedPath =
      "/tmp/" + String(repeating: "a", count: ClipboardPrivacyPolicy.maximumFileURLBytes)
    XCTAssertFalse(
      ClipboardPrivacyPolicy.permits(fileURLs: [URL(fileURLWithPath: oversizedPath)]))
  }

  func testMixedLocalAndRemoteURLPasteboardIsRejectedAsAWhole() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("islet-tests-mixed-\(UUID().uuidString)"))
    let urls = [
      URL(fileURLWithPath: "/tmp/local.txt"),
      try XCTUnwrap(URL(string: "https://example.com/remote.txt")),
    ]

    pasteboard.clearContents()
    XCTAssertTrue(ClipboardFileURLs.write(urls, to: pasteboard))
    let capturedURLs = ClipboardFileURLs.read(from: pasteboard)

    XCTAssertEqual(capturedURLs, urls)
    XCTAssertFalse(ClipboardPrivacyPolicy.permits(fileURLs: capturedURLs))
  }

  func testFailedHistoryWriteRestoresTheExistingClipboard() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("islet-tests-\(UUID().uuidString)"))
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("keep me", forType: .string))

    XCTAssertFalse(
      ClipboardPasteboardTransaction.replace(on: pasteboard) {
        _ = pasteboard.setString("replacement", forType: .string)
        return false
      })
    XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
  }

  @MainActor
  private func testPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("islet-clipboard-privacy-\(UUID().uuidString)"))
  }

  @MainActor
  private func write(_ value: String, to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString(value, forType: .string))
  }

  private func identity(_ bundleIdentifier: String, _ name: String) throws
    -> ClipboardApplicationIdentity
  {
    try XCTUnwrap(
      ClipboardApplicationIdentity(bundleIdentifier: bundleIdentifier, name: name))
  }
}

@MainActor
private final class TestClipboardPrivacyStore: ClipboardPrivacyStoring {
  var onChange: (() -> Void)?
  var configuration: ClipboardPrivacyConfiguration

  init(_ configuration: ClipboardPrivacyConfiguration = ClipboardPrivacyConfiguration()) {
    self.configuration = configuration
  }

  func load() -> ClipboardPrivacyConfiguration { configuration }
  func save(_ configuration: ClipboardPrivacyConfiguration) {
    self.configuration = configuration
  }
}

@MainActor
private final class TestClipboardContextMonitor: ClipboardContextMonitoring {
  enum RefreshResult {
    case noChange
    case change(ClipboardApplicationIdentity?)
  }

  var context: ClipboardCaptureContext
  var onChange: ((ClipboardCaptureContext) -> Void)?
  var refreshResults: [RefreshResult] = []

  init(application: ClipboardApplicationIdentity?) {
    context = ClipboardCaptureContext(application: application)
  }

  func start() {}
  func stop() {}
  func refreshApplication() -> Bool {
    guard !refreshResults.isEmpty else { return false }
    switch refreshResults.removeFirst() {
    case .noChange:
      return false
    case .change(let application):
      context.application = application
      onChange?(context)
      return true
    }
  }

  func change(application: ClipboardApplicationIdentity) {
    context.application = application
    onChange?(context)
  }

  func changeToUnknownApplication() {
    context.application = nil
    onChange?(context)
  }

  func change(focusIdentifier: String?) {
    context.focusIdentifier = focusIdentifier
    onChange?(context)
  }
}
