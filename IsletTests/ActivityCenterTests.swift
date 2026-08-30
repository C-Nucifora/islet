import Defaults
import SwiftUI
import XCTest

@testable import Islet

@MainActor
final class ActivityCenterTests: XCTestCase {
  final class Fake: NotchActivity, ObservableObject {
    let id: String
    let priority: ActivityPriority
    var isActive: Bool {
      didSet { activationDate = isActive ? Date() : nil }
    }
    var activationDate: Date?
    var isAvailableWhenInactive: Bool
    var compactLeading: AnyView { AnyView(EmptyView()) }
    var compactTrailing: AnyView { AnyView(EmptyView()) }
    var expandedView: AnyView { AnyView(EmptyView()) }

    init(
      id: String, priority: ActivityPriority, active: Bool = false,
      isAvailableWhenInactive: Bool = false
    ) {
      self.id = id
      self.priority = priority
      self.isActive = active
      self.isAvailableWhenInactive = isAvailableWhenInactive
      if active { activationDate = Date() }
    }
  }

  func testUserOrderDeterminesPrimary() {
    // The primary activity is the first-in-user-order among the active ones. In the default order,
    // "nowPlaying" precedes "battery".
    let center = ActivityCenter()
    center.register(Fake(id: "battery", priority: .ambient, active: true))
    center.register(Fake(id: "nowPlaying", priority: .media, active: true))
    XCTAssertEqual(center.primaryActivity?.id, "nowPlaying")
  }

  func testDisabledActivityExcluded() {
    let saved = Defaults[.disabledActivities]
    defer { Defaults[.disabledActivities] = saved }

    let center = ActivityCenter()
    center.register(Fake(id: "battery", priority: .ambient, active: true))
    center.register(Fake(id: "nowPlaying", priority: .media, active: true))

    // Disabling the would-be primary drops it from the active set entirely, tab and all.
    Defaults[.disabledActivities] = ["nowPlaying"]
    XCTAssertEqual(center.activeActivities.map(\.id), ["battery"])
    XCTAssertEqual(center.primaryActivity?.id, "battery")

    // Re-enabling brings it back as primary.
    Defaults[.disabledActivities] = []
    XCTAssertEqual(center.primaryActivity?.id, "nowPlaying")
  }

  func testTemporaryPresentationRevealsOnlyTheRequestedDisabledActivity() {
    let saved = Defaults[.disabledActivities]
    defer { Defaults[.disabledActivities] = saved }
    Defaults[.disabledActivities] = ["timer", "battery"]
    let center = ActivityCenter()
    center.register(Fake(id: "timer", priority: .timer, active: true))
    center.register(Fake(id: "battery", priority: .ambient, active: true))

    XCTAssertTrue(center.expandedActivities.isEmpty)
    XCTAssertEqual(
      center.expandedActivities(temporarilyIncluding: "timer").map(\.id), ["timer"])
    XCTAssertTrue(center.expandedActivities.isEmpty)
  }

  func testInactiveIgnored() {
    let center = ActivityCenter()
    center.register(Fake(id: "media", priority: .media, active: false))
    XCTAssertNil(center.primaryActivity)
  }

  func testInactiveUtilityIsAvailableOnlyInExpandedSwitcher() {
    let saved = Defaults[.disabledActivities]
    defer { Defaults[.disabledActivities] = saved }
    Defaults[.disabledActivities] = []

    let center = ActivityCenter()
    center.register(
      Fake(
        id: "shelf", priority: .ambient, active: false,
        isAvailableWhenInactive: true))

    XCTAssertTrue(center.activeActivities.isEmpty)
    XCTAssertNil(center.primaryActivity)
    XCTAssertEqual(center.expandedActivities.map(\.id), ["shelf"])

    Defaults[.disabledActivities] = ["shelf"]
    XCTAssertTrue(center.expandedActivities.isEmpty)
    XCTAssertFalse(center.isAvailableInExpandedSwitcher("shelf"))
  }

  func testHiddenShelfQuickActionIsUnavailable() {
    let saved = Defaults[.disabledActivities]
    defer { Defaults[.disabledActivities] = saved }
    Defaults[.disabledActivities] = ["shelf"]

    let action = IsletQuickAction.all.first { $0.id == "shelf-open" }
    XCTAssertNotNil(action)
    XCTAssertFalse(action?.isAvailable() ?? true)
  }

  func testActivityLifecyclePolicyUsesCanonicalStateAndAdditionalProviderDemand() {
    XCTAssertTrue(
      ActivityLifecyclePolicy.shouldRun(activityID: "pulse", disabledActivities: []))
    XCTAssertFalse(
      ActivityLifecyclePolicy.shouldRun(
        activityID: "pulse", disabledActivities: ["pulse"]))
    XCTAssertTrue(
      ActivityLifecyclePolicy.shouldRun(
        activityID: "calendar", disabledActivities: ["calendar"],
        additionalRuntimeDemand: true))
  }

  func testAlwaysShowSystemInvalidatesTheActiveActivityCache() async {
    let savedAlwaysVisible = Defaults[.systemAlwaysVisible]
    defer {
      Defaults[.systemAlwaysVisible] = savedAlwaysVisible
    }
    Defaults[.systemAlwaysVisible] = false

    let center = ActivityCenter()
    center.register(SystemActivity())
    XCTAssertTrue(center.activeActivities.isEmpty)

    Defaults[.systemAlwaysVisible] = true
    await Task.yield()

    XCTAssertEqual(center.activeActivities.map(\.id), ["system"])
  }

  func testTieBrokenByRecency() {
    let center = ActivityCenter()
    let a = Fake(id: "a", priority: .ambient, active: true)
    a.activationDate = Date(timeIntervalSinceNow: -60)
    let b = Fake(id: "b", priority: .ambient, active: true)
    center.register(a)
    center.register(b)
    XCTAssertEqual(center.primaryActivity?.id, "b")
  }

  // MARK: - Stored-order migration

  /// The Settings menu-order list renders from the persisted order, so an entry added to the
  /// catalogue after that order was written must be appended or it can never be reordered or
  /// disabled there.
  func testMergedOrderAppendsCatalogueEntriesTheStoredOrderPredates() {
    let preSystem = ["timer", "nowPlaying", "shelf", "clipboard", "ports", "calendar", "battery"]
    let merged = ActivityCatalog.mergedOrder(preSystem)
    XCTAssertEqual(merged, preSystem + ["pulse", "t3Code", "system", "continuity"])
  }

  func testMergedOrderPreservesTheUsersOrderingAndUnknownIDs() {
    // A custom order, plus an id from some future build this one does not know about.
    let stored = ["battery", "future-thing", "timer", "system"]
    let merged = ActivityCatalog.mergedOrder(stored)
    XCTAssertEqual(Array(merged.prefix(4)), stored)  // user's order untouched, unknown id kept
    XCTAssertEqual(Set(merged), Set(stored + ActivityCatalog.defaultOrder))
  }

  func testMergedOrderIsIdempotent() {
    let once = ActivityCatalog.mergedOrder(["battery"])
    XCTAssertEqual(ActivityCatalog.mergedOrder(once), once)
    XCTAssertEqual(
      ActivityCatalog.mergedOrder(ActivityCatalog.defaultOrder), ActivityCatalog.defaultOrder)
  }

  func testEveryCataloguedActivityHasALifecycleClassification() {
    XCTAssertEqual(
      Set(ActivityCatalog.defaultOrder),
      ActivityCatalog.lifecycleManagedIDs.union(ActivityCatalog.persistentLifecycleIDs))
    XCTAssertTrue(
      ActivityCatalog.lifecycleManagedIDs.isDisjoint(with: ActivityCatalog.persistentLifecycleIDs))
  }

  // MARK: - Canonical enablement migration

  func testLegacyActivityOnlyFlagsUseTheCompleteMigrationTruthTable() {
    let activityOnlyIDs = ActivityEnablement.legacyFlagActivityIDs.subtracting(
      ActivityEnablement.sharedProviderIDs)

    for activityID in activityOnlyIDs {
      for wasHidden in [false, true] {
        for legacyEnabled in [false, true] {
          let migrated = ActivityEnablement.migratedDisabledActivities(
            existing: wasHidden ? [activityID] : [],
            legacyEnabled: [activityID: legacyEnabled])
          let expectedEnabled = !wasHidden && legacyEnabled
          XCTAssertEqual(
            ActivityEnablement.isEnabled(activityID, disabledActivities: migrated),
            expectedEnabled,
            "\(activityID), hidden=\(wasHidden), legacyEnabled=\(legacyEnabled)")
        }
      }
    }
  }

  func testCalendarMigrationPreservesAllProviderAndVisibilityCombinations() {
    for wasHidden in [false, true] {
      for providerEnabled in [false, true] {
        let migrated = ActivityEnablement.migratedDisabledActivities(
          existing: wasHidden ? ["calendar"] : [],
          legacyEnabled: ["calendar": providerEnabled])
        XCTAssertEqual(
          ActivityEnablement.isEnabled("calendar", disabledActivities: migrated),
          !wasHidden && providerEnabled,
          "hidden=\(wasHidden), providerEnabled=\(providerEnabled)")
      }
    }
  }

  func testRunningMigrationDoesNotRewriteCalendarProviderSetting() {
    let savedDisabled = Defaults[.disabledActivities]
    let savedVersion = Defaults[.activityEnablementMigrationVersion]
    let savedCalendarProvider = Defaults[.calendarEnabled]
    defer {
      Defaults[.disabledActivities] = savedDisabled
      Defaults[.activityEnablementMigrationVersion] = savedVersion
      Defaults[.calendarEnabled] = savedCalendarProvider
    }

    for providerEnabled in [false, true] {
      Defaults[.disabledActivities] = []
      Defaults[.calendarEnabled] = providerEnabled
      ActivityEnablement.migrateLegacyPreferencesIfNeeded(force: true)
      XCTAssertEqual(Defaults[.calendarEnabled], providerEnabled)
    }
  }

  func testEnablementMigrationPreservesUnknownIDsAndIsIdempotent() {
    let once = ActivityEnablement.migratedDisabledActivities(
      existing: ["futureActivity", "pulse"],
      legacyEnabled: ["pulse": true, "clipboard": false])
    let twice = ActivityEnablement.migratedDisabledActivities(
      existing: once,
      legacyEnabled: ["pulse": true, "clipboard": false])

    XCTAssertEqual(once.filter { $0 == "futureActivity" }, ["futureActivity"])
    XCTAssertEqual(twice, once)
    XCTAssertFalse(ActivityEnablement.isEnabled("pulse", disabledActivities: once))
    XCTAssertFalse(ActivityEnablement.isEnabled("clipboard", disabledActivities: once))
  }

  // MARK: - Live lifecycle changes

  func testEveryManagedActivityStartsAndStopsOnCanonicalLiveToggle() async {
    let savedDisabled = Defaults[.disabledActivities]
    let savedCalendarProvider = Defaults[.calendarEnabled]
    defer {
      Defaults[.disabledActivities] = savedDisabled
      Defaults[.calendarEnabled] = savedCalendarProvider
    }
    Defaults[.disabledActivities] = []
    Defaults[.calendarEnabled] = false

    var running = Dictionary(
      uniqueKeysWithValues: ActivityCatalog.lifecycleManagedIDs.map { ($0, false) })
    let controls = ActivityCatalog.lifecycleManagedIDs.sorted().map { activityID in
      ActivityLifecycleControl(
        activityID: activityID,
        start: { running[activityID] = true },
        stop: { running[activityID] = false })
    }
    let controller = ActivityLifecycleController(controls: controls)
    controller.startObserving()
    XCTAssertTrue(running.values.allSatisfy { $0 })

    for activityID in ActivityCatalog.lifecycleManagedIDs.sorted() {
      Defaults[.disabledActivities] = [activityID]
      await Task.yield()
      await Task.yield()
      XCTAssertFalse(running[activityID] ?? true, "\(activityID) did not stop")
      XCTAssertTrue(
        running.filter { $0.key != activityID }.values.allSatisfy { $0 },
        "toggling \(activityID) changed another lifecycle")

      Defaults[.disabledActivities] = []
      await Task.yield()
      await Task.yield()
      XCTAssertTrue(running[activityID] ?? false, "\(activityID) did not restart")
    }
    controller.stopObserving()
  }

  func testCalendarProviderDemandKeepsRuntimeAliveWhenActivityIsOff() async {
    let savedDisabled = Defaults[.disabledActivities]
    let savedCalendarProvider = Defaults[.calendarEnabled]
    defer {
      Defaults[.disabledActivities] = savedDisabled
      Defaults[.calendarEnabled] = savedCalendarProvider
    }
    Defaults[.disabledActivities] = ["calendar"]
    Defaults[.calendarEnabled] = true

    var running = false
    let controller = ActivityLifecycleController(controls: [
      ActivityLifecycleControl(
        activityID: "calendar", additionalRuntimeDemand: { Defaults[.calendarEnabled] },
        start: { running = true }, stop: { running = false })
    ])
    controller.startObserving()
    XCTAssertTrue(running)

    Defaults[.calendarEnabled] = false
    await Task.yield()
    await Task.yield()
    XCTAssertFalse(running)

    Defaults[.disabledActivities] = []
    await Task.yield()
    await Task.yield()
    XCTAssertTrue(running)
    controller.stopObserving()
  }
}
