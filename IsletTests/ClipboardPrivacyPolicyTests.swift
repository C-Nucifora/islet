import AppKit
import XCTest

@testable import Islet

private final class LazyClipboardDataProvider: NSObject, NSPasteboardItemDataProvider,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let representations: [String: Data]
  private var requestedTypes: [String] = []

  init(representations: [String: Data]) { self.representations = representations }

  nonisolated func pasteboard(
    _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
    provideDataForType type: NSPasteboard.PasteboardType
  ) {
    lock.withLock { requestedTypes.append(type.rawValue) }
    if let data = representations[type.rawValue] { item.setData(data, forType: type) }
  }

  func requests() -> [String] { lock.withLock { requestedTypes } }
}

private final class BlockingClipboardDataProvider: NSObject, NSPasteboardItemDataProvider,
  @unchecked Sendable
{
  private let condition = NSCondition()
  private let data: Data
  private var requestedTypes: [String] = []
  private var isReleased = false

  init(data: Data) { self.data = data }

  nonisolated func pasteboard(
    _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
    provideDataForType type: NSPasteboard.PasteboardType
  ) {
    condition.lock()
    requestedTypes.append(type.rawValue)
    condition.broadcast()
    while !isReleased { condition.wait() }
    condition.unlock()
    item.setData(data, forType: type)
  }

  func waitUntilRequested() async -> Bool {
    await waitUntilRequestCount(1)
  }

  func waitUntilRequestCount(_ count: Int, timeout: TimeInterval = 5) async -> Bool {
    await Task.detached { [self] in waitUntilRequestCountSynchronously(count, timeout: timeout) }
      .value
  }

  func release() {
    condition.lock()
    isReleased = true
    condition.broadcast()
    condition.unlock()
  }

  func requests() -> [String] {
    condition.withLock { requestedTypes }
  }

  private func waitUntilRequestCountSynchronously(_ count: Int, timeout: TimeInterval) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(timeout)
    while requestedTypes.count < count {
      guard condition.wait(until: deadline) else { return false }
    }
    return true
  }
}

@MainActor
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

  func testUntilNextLoginPauseSurvivesTemporaryMissingSessionIdentifier() {
    let evaluation = ClipboardPrivacyEvaluator.evaluate(
      configuration: ClipboardPrivacyConfiguration(pausedLoginSession: "login-a"),
      context: ClipboardCaptureContext(), now: .distantPast, loginSession: nil)

    XCTAssertEqual(evaluation.reason, .untilNextLogin)
    XCTAssertEqual(evaluation.configuration.pausedLoginSession, "login-a")
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

  func testImagePolicyRetainsAPNGOnlyRepresentation() throws {
    let png = try imageData(as: .png)

    let payload = try XCTUnwrap(
      ClipboardImagePolicy.payload(from: [(type: .png, data: png)]))

    XCTAssertEqual(payload.data, png)
    XCTAssertEqual(payload.pasteboardTypeRawValue, NSPasteboard.PasteboardType.png.rawValue)
  }

  func testImagePolicyRetainsATIFFOnlyRepresentation() throws {
    let tiff = try imageData(as: .tiff)

    let payload = try XCTUnwrap(
      ClipboardImagePolicy.payload(from: [(type: .tiff, data: tiff)]))

    XCTAssertEqual(payload.data, tiff)
    XCTAssertEqual(payload.pasteboardTypeRawValue, NSPasteboard.PasteboardType.tiff.rawValue)
  }

  func testImagePolicyChoosesTheSmallerLosslessRepresentationAndRoundTripsItsType() throws {
    let png = try imageData(as: .png)
    let tiff = try imageData(as: .tiff)

    let expected = png.count <= tiff.count ? png : tiff
    let expectedType: NSPasteboard.PasteboardType = png.count <= tiff.count ? .png : .tiff
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("islet-tests-image-\\(UUID().uuidString)"))
    let item = NSPasteboardItem()
    XCTAssertTrue(item.setData(tiff, forType: .tiff))
    XCTAssertTrue(item.setData(png, forType: .png))
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([item]))

    let payload = try XCTUnwrap(ClipboardImagePolicy.payload(from: pasteboard))
    XCTAssertEqual(payload.data, expected)
    XCTAssertEqual(payload.pasteboardTypeRawValue, expectedType.rawValue)

    let selectedFromRepresentations = try XCTUnwrap(
      ClipboardImagePolicy.payload(from: [(type: .tiff, data: tiff), (type: .png, data: png)]))
    XCTAssertEqual(selectedFromRepresentations, payload)

    let copyBackPasteboard = NSPasteboard(
      name: NSPasteboard.Name("islet-tests-image-copy-back-\\(UUID().uuidString)"))
    copyBackPasteboard.clearContents()
    XCTAssertTrue(
      copyBackPasteboard.setData(
        payload.data,
        forType: NSPasteboard.PasteboardType(rawValue: payload.pasteboardTypeRawValue)))
    XCTAssertEqual(copyBackPasteboard.data(forType: expectedType), expected)
  }

  func testImagePolicyRejectsMalformedOversizedAndOverDimensionImages() {
    let malformedPNG = Data([137, 80, 78, 71, 13, 10, 26, 10])
    let oversizedPNG = Data(count: ClipboardPrivacyPolicy.maximumImageBytes + 1)
    let overDimensionPNG = pngHeader(
      width: ClipboardImagePolicy.maximumImageDimension + 1, height: 1)
    let oversizedDecodedPNG = pngHeader(
      width: ClipboardImagePolicy.maximumImageDimension,
      height: ClipboardImagePolicy.maximumImageDimension)

    XCTAssertNil(ClipboardImagePolicy.payload(from: [(type: .png, data: malformedPNG)]))
    XCTAssertNil(ClipboardImagePolicy.payload(from: [(type: .png, data: oversizedPNG)]))
    XCTAssertNil(ClipboardImagePolicy.payload(from: [(type: .png, data: overDimensionPNG)]))
    XCTAssertNil(ClipboardImagePolicy.payload(from: [(type: .png, data: oversizedDecodedPNG)]))
  }

  func testImagePolicyRejectsRepresentationsThatExceedTheCombinedReadBudget() throws {
    let png = try imageData(as: .png)
    let overBudgetTIFF = Data(count: ClipboardImagePolicy.maximumImageReadBytes)

    XCTAssertNil(
      ClipboardImagePolicy.payload(
        from: [(type: .png, data: png), (type: .tiff, data: overBudgetTIFF)]))
  }

  func testImagePolicyAcceptsOnlyLosslessTIFFCompressionModes() {
    for compression in [UInt32(1), 2, 3, 4, 5, 8, 32_773, 32_946] {
      XCTAssertTrue(ClipboardImagePolicy.isLosslessTIFFCompression(compression))
    }
    XCTAssertFalse(ClipboardImagePolicy.isLosslessTIFFCompression(6))
    XCTAssertFalse(ClipboardImagePolicy.isLosslessTIFFCompression(7))
    XCTAssertFalse(ClipboardImagePolicy.isLosslessTIFFCompression(32_865))
    XCTAssertFalse(ClipboardImagePolicy.isLosslessTIFFCompression(.max))
  }

  private func imageData(as type: NSBitmapImageRep.FileType) throws -> Data {
    let representation = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 2,
        pixelsHigh: 2,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0))
    for x in 0..<2 {
      for y in 0..<2 {
        representation.setColor(NSColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1), atX: x, y: y)
      }
    }
    return try XCTUnwrap(representation.representation(using: type, properties: [:]))
  }

  private func pngHeader(width: Int, height: Int) -> Data {
    var data = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82])
    appendBigEndian(UInt32(width), to: &data)
    appendBigEndian(UInt32(height), to: &data)
    data.append(contentsOf: [8, 6, 0, 0, 0])
    data.append(contentsOf: [0, 0, 0, 0])
    data.append(contentsOf: [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130])
    return data
  }

  private func appendBigEndian(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value >> 24))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value))
  }

  func testMultipleFileURLsRoundTripInOrder() async throws {
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
    let replaced = await ClipboardPasteboardTransaction.replace(on: destination) {
      ClipboardFileURLs.write(capturedURLs, to: destination)
    }
    XCTAssertTrue(replaced)
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

  func testFailedHistoryWriteRestoresTheExistingClipboard() async throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("islet-tests-\(UUID().uuidString)"))
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("keep me", forType: .string))

    let replaced = await ClipboardPasteboardTransaction.replace(on: pasteboard) {
      return false
    }
    XCTAssertFalse(replaced)
    XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
  }

  func testFailedWriteDoesNotOverwriteNewerPasteboardContents() async {
    let name = NSPasteboard.Name("islet-tests-external-write-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    let externalPasteboard = NSPasteboard(name: name)
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("original", forType: .string))

    let replaced = await ClipboardPasteboardTransaction.replace(on: pasteboard) {
      externalPasteboard.clearContents()
      XCTAssertTrue(externalPasteboard.setString("newer external value", forType: .string))
      return false
    }

    XCTAssertFalse(replaced)
    XCTAssertEqual(pasteboard.string(forType: .string), "newer external value")
  }

  func testClearWinsWhileCopyBackIsPreparingRollback() async throws {
    try await assertHistoryInvalidationWinsDuringCopyBack { model in
      model.clear()
    }
  }

  func testPauseWinsWhileCopyBackIsPreparingRollback() async throws {
    try await assertHistoryInvalidationWinsDuringCopyBack { model in
      model.setPaused(true)
      XCTAssertTrue(model.isPaused)
    }
  }

  func testRemoveWinsWhileCopyBackIsPreparingRollback() async throws {
    try await assertHistoryInvalidationWinsDuringCopyBack { model in
      model.remove(model.items[0])
    }
  }

  func testStopWinsWhileCopyBackIsPreparingRollback() async throws {
    try await assertHistoryInvalidationWinsDuringCopyBack(
      prepare: { $0.start() },
      invalidate: { $0.stop() })
  }

  func testNewerCopyBackWaitsForCancelledMaterializationToFinish() async throws {
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("islet-tests-copy-back-serialization-\(UUID().uuidString)"))
    let olderType = NSPasteboard.PasteboardType("com.islet.tests.blocked.older")
    let olderProvider = BlockingClipboardDataProvider(data: Data([1, 2, 3]))
    defer { olderProvider.release() }
    let olderPasteboardItem = NSPasteboardItem()
    XCTAssertTrue(olderPasteboardItem.setDataProvider(olderProvider, forTypes: [olderType]))
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([olderPasteboardItem]))

    let model = ClipboardModel(pasteboard: pasteboard)
    let olderItem = ClipboardItem(kind: .text("older"), date: .distantPast)
    let newerItem = ClipboardItem(kind: .text("newer"), date: .distantPast)
    let olderCopy = Task { await model.copyBack(olderItem) }
    let olderMaterializationStarted = await olderProvider.waitUntilRequested()
    XCTAssertTrue(olderMaterializationStarted)

    let newerType = NSPasteboard.PasteboardType("com.islet.tests.blocked.newer")
    let newerProvider = BlockingClipboardDataProvider(data: Data([4, 5, 6]))
    defer { newerProvider.release() }
    let newerPasteboardItem = NSPasteboardItem()
    XCTAssertTrue(newerPasteboardItem.setDataProvider(newerProvider, forTypes: [newerType]))
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([newerPasteboardItem]))

    let newerCopy = Task { await model.copyBack(newerItem) }
    let newerMaterializedConcurrently = await newerProvider.waitUntilRequestCount(1, timeout: 0.25)
    XCTAssertFalse(
      newerMaterializedConcurrently,
      "A superseding copy-back must wait for the cancelled materialization to leave the pipeline")
    olderProvider.release()
    let newerMaterializationStarted = await newerProvider.waitUntilRequested()
    XCTAssertTrue(newerMaterializationStarted)
    newerProvider.release()

    let olderSucceeded = await olderCopy.value
    let newerSucceeded = await newerCopy.value
    XCTAssertFalse(olderSucceeded)
    XCTAssertTrue(newerSucceeded)
    XCTAssertEqual(pasteboard.string(forType: .string), "newer")
  }

  func testOversizedLazyRollbackLeavesClipboardUnchanged() async throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("islet-tests-large-\(UUID().uuidString)"))
    let type = NSPasteboard.PasteboardType("com.islet.tests.large")
    let provider = LazyClipboardDataProvider(
      representations: [
        type.rawValue: Data(count: ClipboardPasteboardTransaction.maximumSnapshotBytes + 1)
      ])
    let item = NSPasteboardItem()
    XCTAssertTrue(item.setDataProvider(provider, forTypes: [type]))
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([item]))
    let originalChangeCount = pasteboard.changeCount
    var attemptedWrite = false

    let replaced = await ClipboardPasteboardTransaction.replace(on: pasteboard) {
      attemptedWrite = true
      return pasteboard.setString("replacement", forType: .string)
    }

    XCTAssertFalse(replaced)
    XCTAssertFalse(attemptedWrite)
    XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
    XCTAssertEqual(provider.requests(), [type.rawValue])
    XCTAssertEqual(pasteboard.pasteboardItems?.first?.types, [type])
  }

  func testTypeLimitRejectsBeforeRequestingLazyRepresentations() async {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("islet-tests-types-\(UUID().uuidString)"))
    let types = (0...ClipboardPasteboardTransaction.maximumTypeCount).map {
      NSPasteboard.PasteboardType("com.islet.tests.lazy.\($0)")
    }
    let provider = LazyClipboardDataProvider(
      representations: Dictionary(uniqueKeysWithValues: types.map { ($0.rawValue, Data([1])) }))
    let item = NSPasteboardItem()
    XCTAssertTrue(item.setDataProvider(provider, forTypes: types))
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([item]))
    let originalChangeCount = pasteboard.changeCount

    let replaced = await ClipboardPasteboardTransaction.replace(on: pasteboard) {
      XCTFail("An unsafe snapshot must not clear or write to the pasteboard")
      return true
    }
    XCTAssertFalse(replaced)
    XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
    XCTAssertTrue(provider.requests().isEmpty)
  }

  func testItemLimitLeavesClipboardUnchanged() async {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("islet-tests-items-\(UUID().uuidString)"))
    let items = (0...ClipboardPasteboardTransaction.maximumItemCount).map { index in
      let item = NSPasteboardItem()
      XCTAssertTrue(item.setString("item \(index)", forType: .string))
      return item
    }
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects(items))
    let originalChangeCount = pasteboard.changeCount

    let replaced = await ClipboardPasteboardTransaction.replace(on: pasteboard) {
      XCTFail("An unsafe snapshot must not clear or write to the pasteboard")
      return true
    }

    XCTAssertFalse(replaced)
    XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
    XCTAssertEqual(pasteboard.pasteboardItems?.count, items.count)
  }

  func testFailedWriteRestoresEveryRepresentationAndItemInOrder() async throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("islet-tests-rich-\(UUID().uuidString)"))
    let first = NSPasteboardItem()
    let customType = NSPasteboard.PasteboardType("com.islet.tests.metadata")
    let rtfType = NSPasteboard.PasteboardType.rtf
    let expected: [(NSPasteboard.PasteboardType, Data)] = [
      (.string, try XCTUnwrap("rich text".data(using: .utf8))),
      (rtfType, Data([0x7b, 0x5c, 0x72, 0x74, 0x66, 0x7d])),
      (customType, Data([0, 1, 2, 3, 255])),
    ]
    for (type, data) in expected { XCTAssertTrue(first.setData(data, forType: type)) }
    let second = NSPasteboardItem()
    XCTAssertTrue(second.setString("second item", forType: .string))
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([first, second]))
    let original = try XCTUnwrap(pasteboard.pasteboardItems).map { item in
      item.types.map { type in (type, item.data(forType: type)) }
    }

    let replaced = await ClipboardPasteboardTransaction.replace(on: pasteboard) {
      _ = pasteboard.setString("replacement", forType: .string)
      return false
    }
    XCTAssertFalse(replaced)

    let restored = try XCTUnwrap(pasteboard.pasteboardItems)
    XCTAssertEqual(restored.count, original.count)
    for (restoredItem, originalRepresentations) in zip(restored, original) {
      XCTAssertEqual(restoredItem.types, originalRepresentations.map(\.0))
      for (type, data) in originalRepresentations {
        XCTAssertEqual(restoredItem.data(forType: type), data)
      }
    }
  }

  private func assertHistoryInvalidationWinsDuringCopyBack(
    prepare: (ClipboardModel) -> Void = { _ in },
    invalidate: (ClipboardModel) -> Void
  ) async throws {
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("islet-tests-copy-back-race-\(UUID().uuidString)"))
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("current", forType: .string))

    let model = ClipboardModel(pasteboard: pasteboard)
    prepare(model)
    let historyItem = ClipboardItem(kind: .text("history"), date: .distantPast)
    let initialCopySucceeded = await model.copyBack(historyItem)
    XCTAssertTrue(initialCopySucceeded)
    XCTAssertEqual(model.items, [historyItem])

    let blockedType = NSPasteboard.PasteboardType("com.islet.tests.blocked")
    let unrequestedType = NSPasteboard.PasteboardType("com.islet.tests.blocked.unrequested")
    let provider = BlockingClipboardDataProvider(data: Data([1, 2, 3]))
    defer { provider.release() }
    let blockedItem = NSPasteboardItem()
    XCTAssertTrue(
      blockedItem.setDataProvider(provider, forTypes: [blockedType, unrequestedType]))
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([blockedItem]))

    let copyTask = Task { await model.copyBack(historyItem) }
    let requested = await provider.waitUntilRequested()
    XCTAssertTrue(requested, "Copy-back never requested the blocked rollback representation")

    invalidate(model)
    provider.release()

    let copySucceeded = await copyTask.value
    XCTAssertFalse(copySucceeded)
    XCTAssertNil(pasteboard.string(forType: .string))
    XCTAssertEqual(pasteboard.data(forType: blockedType), Data([1, 2, 3]))
    XCTAssertEqual(provider.requests(), [blockedType.rawValue])
    XCTAssertTrue(model.items.isEmpty)
  }

  private func testPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("islet-clipboard-privacy-\(UUID().uuidString)"))
  }

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
