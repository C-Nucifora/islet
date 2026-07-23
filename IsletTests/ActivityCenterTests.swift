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
}
