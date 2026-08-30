import AppKit
import XCTest

@testable import Islet

@MainActor
final class NotchPanelDropTests: XCTestCase {
  private func pasteboard(containing urls: [URL]) throws -> NSPasteboard {
    let pasteboard = NSPasteboard(name: .init("NotchPanelDropTests-\(UUID().uuidString)"))
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects(urls.map { $0 as NSURL }))
    return pasteboard
  }

  func testFileURLDragTargetsPanelAndHandsOffDrop() throws {
    let panel = NotchPanel(frame: CGRect(x: 0, y: 0, width: 300, height: 50))
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let source = temporaryRoot.appendingPathComponent("notch-panel-drop.txt")
    try Data("drop".utf8).write(to: source)
    let pasteboard = try pasteboard(containing: [source])
    XCTAssertTrue(EventMonitors.pasteboardContainsFileURLs(pasteboard))
    var targetChanges: [Bool] = []
    var droppedURLs: [URL] = []
    panel.fileDragTargetChanged = { targetChanges.append($0) }
    panel.fileURLsDropped = {
      droppedURLs = $0
      return true
    }

    XCTAssertEqual(panel.fileDragOperation(for: pasteboard), .copy)
    XCTAssertEqual(targetChanges, [true])
    panel.draggingExited(nil)
    XCTAssertEqual(targetChanges, [true, false])
    XCTAssertEqual(panel.fileDragOperation(for: pasteboard), .copy)
    XCTAssertEqual(targetChanges, [true, false, true])
    XCTAssertTrue(panel.performFileDrop(from: pasteboard))
    XCTAssertEqual(droppedURLs, [source])
    XCTAssertEqual(targetChanges, [true, false, true, false])
    panel.close()
  }

  func testNonFileDragIsRejectedWithoutTargetingPanel() {
    let panel = NotchPanel(frame: CGRect(x: 0, y: 0, width: 300, height: 50))
    let pasteboard = NSPasteboard(name: .init("NotchPanelDropTests-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString("not a file", forType: .string)
    XCTAssertFalse(EventMonitors.pasteboardContainsFileURLs(pasteboard))
    var targetChanges: [Bool] = []
    panel.fileDragTargetChanged = { targetChanges.append($0) }

    XCTAssertEqual(panel.fileDragOperation(for: pasteboard), [])
    XCTAssertFalse(panel.performFileDrop(from: pasteboard))
    XCTAssertTrue(targetChanges.isEmpty)
    panel.close()
  }

  func testFileDropIsRejectedWhenShelfIsUnavailable() throws {
    let panel = NotchPanel(frame: CGRect(x: 0, y: 0, width: 300, height: 50))
    panel.acceptsFileDrops = { false }
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let source = temporaryRoot.appendingPathComponent("hidden-shelf-drop.txt")
    try Data("drop".utf8).write(to: source)
    let pasteboard = try pasteboard(containing: [source])
    var handedOff = false
    panel.fileURLsDropped = { _ in
      handedOff = true
      return true
    }

    XCTAssertEqual(panel.fileDragOperation(for: pasteboard), [])
    XCTAssertFalse(panel.performFileDrop(from: pasteboard))
    XCTAssertFalse(handedOff)
    panel.close()
  }

  func testAdaptiveResizePreservesCaptureAndFullscreenPolicy() {
    let panel = NotchPanel(frame: CGRect(x: 200, y: 900, width: 300, height: 50))
    panel.sharingType = .none
    let collectionBehavior = panel.collectionBehavior

    panel.setFrame(CGRect(x: 50, y: 600, width: 900, height: 280), display: false)

    XCTAssertEqual(panel.sharingType, .none)
    XCTAssertEqual(panel.collectionBehavior, collectionBehavior)
    XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
    panel.close()
  }
}
