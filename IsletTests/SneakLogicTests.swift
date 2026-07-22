import SwiftUI
import XCTest

@testable import Islet

final class SneakLogicTests: XCTestCase {
  func sneak(_ source: String) -> Sneak {
    Sneak(source: source, leading: AnyView(EmptyView()), trailing: AnyView(EmptyView()))
  }

  func testFIFOOrder() {
    var q = SneakLogic()
    q.enqueue(sneak("a"))
    q.enqueue(sneak("b"))
    XCTAssertEqual(q.popNext()?.source, "a")
    XCTAssertEqual(q.popNext()?.source, "b")
    XCTAssertNil(q.popNext())
  }

  func testCoalescingReplacesSameSourceInPlace() {
    var q = SneakLogic()
    q.enqueue(sneak("battery"))
    q.enqueue(sneak("track"))
    let replacement = sneak("battery")
    q.enqueue(replacement)
    XCTAssertEqual(q.pending.count, 2)
    XCTAssertEqual(q.popNext()?.id, replacement.id)  // kept battery's slot, new content
    XCTAssertEqual(q.popNext()?.source, "track")
  }

  func testDistinctSourcesBothKept() {
    var q = SneakLogic()
    q.enqueue(sneak("a"))
    q.enqueue(sneak("b"))
    XCTAssertEqual(q.pending.count, 2)
  }
}
