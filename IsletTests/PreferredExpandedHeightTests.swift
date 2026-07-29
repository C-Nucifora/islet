import SwiftUI
import XCTest

@testable import Islet

@MainActor
final class PreferredExpandedHeightTests: XCTestCase {
  /// Takes the protocol default, the way every activity shipping today does.
  final class BaseTierActivity: NotchActivity, ObservableObject {
    let id = "baseTier"
    let priority = ActivityPriority.ambient
    var isActive = true
    var activationDate: Date?
    var compactLeading: AnyView { AnyView(EmptyView()) }
    var compactTrailing: AnyView { AnyView(EmptyView()) }
    var expandedView: AnyView { AnyView(EmptyView()) }
  }

  /// Opts into the taller tier, the way the Phase 2 power tab and the Phase 4 system tab will.
  final class TallTierActivity: NotchActivity, ObservableObject {
    let id = "tallTier"
    let priority = ActivityPriority.ambient
    var isActive = true
    var activationDate: Date?
    var compactLeading: AnyView { AnyView(EmptyView()) }
    var compactTrailing: AnyView { AnyView(EmptyView()) }
    var expandedView: AnyView { AnyView(EmptyView()) }
    let preferredExpandedHeight = Metrics.tallExpandedHeight
  }

  func testDefaultPreferredExpandedHeightIsTheBaseTier() {
    XCTAssertEqual(BaseTierActivity().preferredExpandedHeight, Metrics.expandedSize.height)
    XCTAssertEqual(BaseTierActivity().preferredExpandedHeight, 190)
  }

  func testAnActivityCanRequestTheTallTier() {
    XCTAssertEqual(TallTierActivity().preferredExpandedHeight, Metrics.tallExpandedHeight)
    XCTAssertEqual(TallTierActivity().preferredExpandedHeight, 250)
  }
}
