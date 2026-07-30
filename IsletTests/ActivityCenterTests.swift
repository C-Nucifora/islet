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
    var compactLeading: AnyView { AnyView(EmptyView()) }
    var compactTrailing: AnyView { AnyView(EmptyView()) }
    var expandedView: AnyView { AnyView(EmptyView()) }

    init(id: String, priority: ActivityPriority, active: Bool = false) {
      self.id = id
      self.priority = priority
      self.isActive = active
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

  func testInactiveIgnored() {
    let center = ActivityCenter()
    center.register(Fake(id: "media", priority: .media, active: false))
    XCTAssertNil(center.primaryActivity)
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
    XCTAssertEqual(merged, preSystem + ["system"])
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
    XCTAssertEqual(ActivityCatalog.mergedOrder(ActivityCatalog.defaultOrder),
                   ActivityCatalog.defaultOrder)
  }
}
