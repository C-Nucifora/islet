import XCTest

@testable import Islet

final class ContextRuleTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 10_000)

  func testEveryTriggerMatchesAndRejectsADifferentSnapshot() throws {
    let base = ContextSnapshot(
      focusMode: "Work", powerSource: .ac, lowPowerMode: true,
      frontmostBundleIdentifier: "com.apple.Keynote", isFullscreenPresentation: true,
      minuteOfDay: 10 * 60, activeDisplayID: "DISPLAY-1", activeDisplayName: "Studio Display",
      wifiNetwork: "Office")

    let cases: [(ContextRuleTrigger, (inout ContextSnapshot) -> Void)] = [
      (
        ContextRuleTrigger(kind: .focusMode, text: "Work"),
        { $0.focusMode = nil }
      ),
      (
        ContextRuleTrigger(kind: .powerSource, powerSource: .ac),
        { $0.powerSource = .battery }
      ),
      (
        ContextRuleTrigger(kind: .lowPowerMode, boolean: true),
        { $0.lowPowerMode = false }
      ),
      (
        ContextRuleTrigger(kind: .frontmostApp, text: "com.apple.Keynote"),
        { $0.frontmostBundleIdentifier = "com.apple.Safari" }
      ),
      (
        ContextRuleTrigger(kind: .fullscreenPresentation, boolean: true),
        { $0.isFullscreenPresentation = false }
      ),
      (
        ContextRuleTrigger(kind: .timeRange, startMinute: 9 * 60, endMinute: 17 * 60),
        { $0.minuteOfDay = 18 * 60 }
      ),
      (
        ContextRuleTrigger(kind: .activeDisplay, text: "Studio Display"),
        { $0.activeDisplayName = "Built-in Display" }
      ),
      (
        ContextRuleTrigger(kind: .wifiNetwork, text: "Office"),
        { $0.wifiNetwork = "Guest" }
      ),
    ]

    for (trigger, makeDifferent) in cases {
      XCTAssertNotNil(
        ContextRuleEvaluator.matchReason(for: trigger, snapshot: base), trigger.kind.title)
      var different = base
      makeDifferent(&different)
      if trigger.kind == .activeDisplay { different.activeDisplayID = "DISPLAY-2" }
      XCTAssertNil(
        ContextRuleEvaluator.matchReason(for: trigger, snapshot: different), trigger.kind.title)
    }
  }

  func testFocusCanMatchAnyActiveFocusAndTextMatchingIsCaseInsensitive() {
    let anyFocus = ContextRuleTrigger(kind: .focusMode)
    XCTAssertNotNil(
      ContextRuleEvaluator.matchReason(
        for: anyFocus, snapshot: ContextSnapshot(focusMode: "Personal")))
    XCTAssertNil(
      ContextRuleEvaluator.matchReason(for: anyFocus, snapshot: ContextSnapshot()))

    let app = ContextRuleTrigger(kind: .frontmostApp, text: "COM.APPLE.KEYNOTE")
    XCTAssertNotNil(
      ContextRuleEvaluator.matchReason(
        for: app,
        snapshot: ContextSnapshot(frontmostBundleIdentifier: "com.apple.keynote")))
  }

  func testTimeRangeSupportsMidnightAndExcludesItsEnd() {
    XCTAssertTrue(ContextRuleEvaluator.contains(minute: 23 * 60, start: 22 * 60, end: 7 * 60))
    XCTAssertTrue(ContextRuleEvaluator.contains(minute: 6 * 60, start: 22 * 60, end: 7 * 60))
    XCTAssertFalse(ContextRuleEvaluator.contains(minute: 7 * 60, start: 22 * 60, end: 7 * 60))
    XCTAssertFalse(ContextRuleEvaluator.contains(minute: 12 * 60, start: 22 * 60, end: 7 * 60))
  }

  func testFirstEnabledMatchingRuleWinsAndReorderingChangesPrecedence() throws {
    let snapshot = ContextSnapshot(lowPowerMode: true)
    let first = rule(
      name: "First", trigger: ContextRuleTrigger(kind: .lowPowerMode, boolean: true),
      action: ContextRuleAction(pulseDelivery: .criticalOnly))
    let second = rule(
      name: "Second", trigger: ContextRuleTrigger(kind: .lowPowerMode, boolean: true),
      action: ContextRuleAction(energyMode: .lowEnergy))

    XCTAssertEqual(
      ContextRuleEvaluator.resolve(
        rules: [first, second], snapshot: snapshot, manualOverride: nil, now: now
      ).matchedRuleID,
      first.id)
    XCTAssertEqual(
      ContextRuleEvaluator.resolve(
        rules: [second, first], snapshot: snapshot, manualOverride: nil, now: now
      ).matchedRuleID,
      second.id)

    var disabledFirst = first
    disabledFirst.isEnabled = false
    XCTAssertEqual(
      ContextRuleEvaluator.resolve(
        rules: [disabledFirst, second], snapshot: snapshot, manualOverride: nil, now: now
      ).matchedRuleID,
      second.id)
  }

  func testManualOverrideWinsUntilItsClearExpiry() {
    let matchingRule = rule(
      name: "Work", trigger: ContextRuleTrigger(kind: .focusMode),
      action: ContextRuleAction(energyMode: .lowEnergy))
    let manual = ContextManualOverride(
      action: ContextRuleAction(pulseDelivery: .paused),
      expiresAt: now.addingTimeInterval(60))

    let active = ContextRuleEvaluator.resolve(
      rules: [matchingRule], snapshot: ContextSnapshot(focusMode: "Work"),
      manualOverride: manual, now: now)
    XCTAssertTrue(active.isManualOverride)
    XCTAssertEqual(active.action?.pulseDelivery, .paused)

    let expired = ContextRuleEvaluator.resolve(
      rules: [matchingRule], snapshot: ContextSnapshot(focusMode: "Work"),
      manualOverride: manual, now: now.addingTimeInterval(60))
    XCTAssertFalse(expired.isManualOverride)
    XCTAssertEqual(expired.matchedRuleID, matchingRule.id)
  }

  func testPriorStateReturnsWhenRuleStopsMatching() {
    let baselinePulse = PulseDeliveryProfile.everything
    let baselineEnergy = EnergyMode.live
    let matching = ContextRuleEvaluator.resolve(
      rules: [
        rule(
          name: "Presenting",
          trigger: ContextRuleTrigger(kind: .fullscreenPresentation, boolean: true),
          action: ContextRuleAction(
            pulseDelivery: .criticalOnly, energyMode: .lowEnergy,
            activityVisibility: ["clipboard": false]))
      ],
      snapshot: ContextSnapshot(isFullscreenPresentation: true), manualOverride: nil, now: now)
    XCTAssertEqual(matching.pulseDelivery(baseline: baselinePulse), .criticalOnly)
    XCTAssertEqual(matching.energyMode(baseline: baselineEnergy), .lowEnergy)
    XCTAssertFalse(matching.isActivityVisible("clipboard", baselineVisible: true))

    let stopped = ContextRuleResolution.none
    XCTAssertEqual(stopped.pulseDelivery(baseline: baselinePulse), baselinePulse)
    XCTAssertEqual(stopped.energyMode(baseline: baselineEnergy), baselineEnergy)
    XCTAssertTrue(stopped.isActivityVisible("clipboard", baselineVisible: true))
    XCTAssertFalse(stopped.isActivityVisible("clipboard", baselineVisible: false))
  }

  @MainActor
  func testResolutionChangesEmitAfterTheCenterStoresTheNewResolution() {
    let matchingRule = rule(
      name: "Current power state",
      trigger: ContextRuleTrigger(
        kind: .lowPowerMode, boolean: ProcessInfo.processInfo.isLowPowerModeEnabled),
      action: ContextRuleAction(activityVisibility: ["clipboard": false]))
    let center = ContextRuleCenter(rules: [matchingRule])
    var received: (emitted: ContextRuleResolution, stored: ContextRuleResolution)?
    let cancellable = center.resolutionChanges.sink { emitted in
      received = (emitted, center.resolution)
    }

    center.refresh(now: now)

    XCTAssertEqual(received?.emitted.matchedRuleID, matchingRule.id)
    XCTAssertEqual(received?.stored, received?.emitted)
    withExtendedLifetime(cancellable) {}
  }

  func testSleepClearsAppliedStateAndWakeResamplesCurrentContext() {
    let focusRule = rule(
      name: "Focus", trigger: ContextRuleTrigger(kind: .focusMode),
      action: ContextRuleAction(pulseDelivery: .focused))
    var runtime = ContextRuleRuntime()
    runtime.evaluate(
      rules: [focusRule], snapshot: ContextSnapshot(focusMode: "Work"), manualOverride: nil,
      now: now)
    XCTAssertEqual(runtime.resolution.matchedRuleID, focusRule.id)

    runtime.sleep()
    XCTAssertTrue(runtime.isSleeping)
    XCTAssertEqual(runtime.resolution, .none)

    runtime.wake(
      rules: [focusRule], snapshot: ContextSnapshot(), manualOverride: nil,
      now: now.addingTimeInterval(60))
    XCTAssertFalse(runtime.isSleeping)
    XCTAssertEqual(runtime.resolution, .none)
  }

  func testRulesRoundTripWithoutDroppingActions() throws {
    let original = rule(
      name: "Office",
      trigger: ContextRuleTrigger(kind: .wifiNetwork, text: "Private SSID"),
      action: ContextRuleAction(
        pulseDelivery: .focused, energyMode: .automatic,
        activityVisibility: ["clipboard": false, "system": true]))
    let data = try JSONEncoder().encode(original)
    XCTAssertEqual(try JSONDecoder().decode(ContextRule.self, from: data), original)
  }

  @MainActor
  func testPulseRuleProfileFiltersAndThenRestoresRetainedItems() throws {
    let center = PulseCenter(symbolAvailability: { _ in true })
    let payload = PulsePayload(
      id: "build", source: "tests", title: "Building", subtitle: nil, symbol: nil,
      accentHex: nil, progress: 0.2, state: .progress, priority: .normal,
      expiresAt: nil, actions: nil)
    XCTAssertTrue(center.apply(command(.show, payload), now: now).ok)
    XCTAssertEqual(center.items.map(\.id), ["build"])

    center.ruleDeliveryProfile = .paused
    XCTAssertTrue(center.items.isEmpty)
    XCTAssertEqual(center.retainedItemCount, 1)

    center.ruleDeliveryProfile = nil
    XCTAssertEqual(center.items.map(\.id), ["build"])
  }

  private func rule(
    name: String, trigger: ContextRuleTrigger, action: ContextRuleAction
  ) -> ContextRule {
    ContextRule(name: name, trigger: trigger, action: action)
  }

  private func command(_ operation: PulseOperation, _ payload: PulsePayload) -> PulseCommand {
    PulseCommand(token: "test", operation: operation, activity: payload, id: nil)
  }
}
