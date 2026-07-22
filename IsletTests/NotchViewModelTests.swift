import XCTest

@testable import Islet

@MainActor
final class NotchViewModelTests: XCTestCase {
  func makeVM(mode: InteractionMode = .hover) -> NotchViewModel {
    let g = NotchGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      safeAreaTop: 32, auxLeftWidth: 716, auxRightWidth: 716,
      menuBarHeight: 37)
    return NotchViewModel(geometry: g, modeOverride: mode)
  }

  func testMouseIntoHitRectPeeks() {
    let vm = makeVM()
    vm.handleMouseMoved(CGPoint(x: 864, y: 1110))  // inside notch
    XCTAssertEqual(vm.state, .peek)
  }

  func testMouseOutOfHitRectClosesFromPeek() {
    let vm = makeVM()
    vm.handleMouseMoved(CGPoint(x: 864, y: 1110))
    vm.handleMouseMoved(CGPoint(x: 100, y: 500))
    XCTAssertEqual(vm.state, .closed)
  }

  func testClickOnNotchPins() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    XCTAssertEqual(vm.state, .expanded(pinned: true))
  }

  func testClickOutsideExpandedCloses() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    vm.handleMouseDown(CGPoint(x: 100, y: 500))
    XCTAssertEqual(vm.state, .closed)
  }

  func testHoverRegionWhileExpandedIsExpandedRect() {
    let vm = makeVM(mode: .clickToPin)
    vm.handleMouseDown(CGPoint(x: 864, y: 1110))
    // move inside expandedRect but outside notch: must NOT exit-hover/close
    vm.handleMouseMoved(CGPoint(x: 864, y: 1000))
    XCTAssertEqual(vm.state, .expanded(pinned: true))
  }
}
