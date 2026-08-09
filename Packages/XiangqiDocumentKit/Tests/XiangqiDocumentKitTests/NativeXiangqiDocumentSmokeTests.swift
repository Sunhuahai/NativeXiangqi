import AppKit
import Foundation
import XCTest
import XiangqiCoreBinary
import XiangqiUI

@testable import XiangqiDocumentKit

@MainActor
final class NativeXiangqiDocumentSmokeTests: XCTestCase {
  func testTemporaryAutosaveSmokeEnvelopeIsBoundedAndNotAPlayerSave() throws {
    XCTAssertLessThanOrEqual(NativeXiangqiDocument.temporaryAutosaveSmokeEnvelope.count, 128)
    XCTAssertNoThrow(
      try NativeXiangqiDocument.validateTemporaryAutosaveSmokeEnvelope(
        NativeXiangqiDocument.temporaryAutosaveSmokeEnvelope))
    XCTAssertThrowsError(
      try NativeXiangqiDocument.validateTemporaryAutosaveSmokeEnvelope(Data("not-a-smoke".utf8)))
    XCTAssertFalse(NativeXiangqiDocument().canSaveTemporaryDocument)
  }

  func testTemporaryAutosaveSmokeUsesActualNSDocumentDataReadLifecycle() throws {
    let smoke = NativeXiangqiTemporaryAutosaveSmokeDocument()
    XCTAssertTrue(NativeXiangqiTemporaryAutosaveSmokeDocument.autosavesInPlace)
    let data = try smoke.data(ofType: NativeXiangqiTemporaryAutosaveSmokeDocument.typeName)
    XCTAssertEqual(data, NativeXiangqiDocument.temporaryAutosaveSmokeEnvelope)

    let restored = NativeXiangqiTemporaryAutosaveSmokeDocument()
    XCTAssertNoThrow(
      try restored.read(from: data, ofType: NativeXiangqiTemporaryAutosaveSmokeDocument.typeName))
    XCTAssertThrowsError(
      try restored.read(
        from: Data("corrupt".utf8), ofType: NativeXiangqiTemporaryAutosaveSmokeDocument.typeName))
    XCTAssertThrowsError(try smoke.data(ofType: "wrong.type"))
  }

  func testReadinessTimeoutCancelsPendingInitializationAndCleansWaiter() async throws {
    let document = NativeXiangqiDocument()
    document.beginReadinessTimeoutFixtureForTesting()
    do {
      try await document.waitUntilLocalSessionReady(timeout: .milliseconds(20))
      XCTFail("timeout fixture unexpectedly became ready")
    } catch {
      XCTAssertEqual(error as? NativeXiangqiDocumentReadinessError, .timedOut)
    }
    try await document.waitUntilIdleForTesting()
    XCTAssertTrue(document.readinessTimeoutFixtureCancelledForTestingResult)
    XCTAssertFalse(document.hasReadinessWaiterForTesting)
    XCTAssertFalse(document.hasReadinessTimeoutTaskForTesting)
    XCTAssertFalse(document.hasLiveCoreForTesting)
  }

  func testDisplayLedgerHardCapAllowsExistingChildButRejectsNewNode() {
    let document = NativeXiangqiDocument()
    document.configureVariationLedgerAtCapacityForTesting()
    XCTAssertEqual(
      document.variationNodeIDsForTesting.count, NativeXiangqiDocument.maximumVariationDisplayNodes)
    XCTAssertTrue(document.canRecordDisplayedMoveForTesting(parentNodeID: 0, from: 19, to: 28))
    XCTAssertFalse(document.canRecordDisplayedMoveForTesting(parentNodeID: 0, from: 29, to: 38))
  }
}

@MainActor
final class NativeXiangqiDocumentIntegrationTests: XCTestCase {
  func testDocumentBuildsThreePaneAppKitShellWithCustomBoard() async throws {
    _ = NSApplication.shared
    let document = NativeXiangqiDocument()
    document.makeWindowControllers()
    try await document.waitUntilIdleForTesting()
    defer { document.close() }

    let window = try XCTUnwrap(document.windowControllers.first?.window)
    let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
    XCTAssertEqual(split.splitViewItems.count, 3)
    XCTAssertTrue(containsView(of: XiangqiBoardView.self, in: split.view))
    XCTAssertTrue(containsOutlineView(in: split.view))
    XCTAssertTrue(containsText(NativeXiangqiDocument.baseRuleModeTitle, in: split.view))
    let board = try XCTUnwrap(firstView(of: XiangqiBoardView.self, in: split.view))
    XCTAssertTrue(window.initialFirstResponder === board)
  }

  func testVirtualAccessibilityAndKeyboardHistoryReachTheRustBackedDocument() async throws {
    _ = NSApplication.shared
    let document = NativeXiangqiDocument()
    document.makeWindowControllers()
    try await document.waitUntilLocalSessionReady()
    defer { document.close() }

    let window = try XCTUnwrap(document.windowControllers.first?.window)
    let board = try XCTUnwrap(
      firstView(of: XiangqiBoardView.self, in: try XCTUnwrap(window.contentView)))
    let elements = board.virtualAccessibilityElements()
    XCTAssertEqual(elements.count, 90)

    XCTAssertTrue(elements[19].accessibilityPerformPress())
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.boardPresentation.selectedSquare, 19)
    XCTAssertTrue(elements[28].accessibilityPerformPress())
    try await document.waitUntilIdleForTesting()
    let movedNode = try XCTUnwrap(document.snapshotForTesting?.currentNode)
    XCTAssertNotEqual(movedNode, 0)

    board.keyDown(with: try keyEvent(keyCode: 123, modifiers: []))
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.snapshotForTesting?.currentNode, 0)
    board.keyDown(with: try keyEvent(keyCode: 124, modifiers: []))
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.snapshotForTesting?.currentNode, movedNode)
  }

  func testPointerSelectionAndMoveReachTheRustBackedDocument() async throws {
    _ = NSApplication.shared
    let document = NativeXiangqiDocument()
    document.makeWindowControllers()
    try await document.waitUntilLocalSessionReady()
    defer { document.close() }
    let window = try XCTUnwrap(document.windowControllers.first?.window)
    window.displayIfNeeded()
    let board = try XCTUnwrap(
      firstView(of: XiangqiBoardView.self, in: try XCTUnwrap(window.contentView)))

    board.mouseDown(with: try pointerEvent(for: 19, board: board, window: window))
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.boardPresentation.selectedSquare, 19)
    board.mouseDown(with: try pointerEvent(for: 28, board: board, window: window))
    try await document.waitUntilIdleForTesting()
    XCTAssertNil(document.boardPresentation.selectedSquare)
    XCTAssertNotEqual(document.snapshotForTesting?.currentNode, 0)
  }

  func testNativeMenuAndToolbarValidationTracksDocumentState() async throws {
    _ = NSApplication.shared
    let document = NativeXiangqiDocument()
    document.makeWindowControllers()
    try await document.waitUntilLocalSessionReady()
    defer { document.close() }
    let controller = try XCTUnwrap(
      document.windowControllers.first as? NativeXiangqiDocumentWindowController)
    let undoItem = NSMenuItem(
      title: "撤销", action: NSSelectorFromString("undoMove:"), keyEquivalent: "")
    let redoItem = NSMenuItem(
      title: "重做", action: NSSelectorFromString("redoMove:"), keyEquivalent: "")
    let previousItem = NSMenuItem(
      title: "上一步", action: NSSelectorFromString("navigatePrevious:"), keyEquivalent: "")
    let nextItem = NSMenuItem(
      title: "下一步", action: NSSelectorFromString("navigateNext:"), keyEquivalent: "")
    let saveItem = NSMenuItem(
      title: "保存", action: NSSelectorFromString("saveTemporaryDocument:"), keyEquivalent: "")

    XCTAssertFalse(controller.validateUserInterfaceItem(undoItem))
    XCTAssertFalse(controller.validateUserInterfaceItem(redoItem))
    XCTAssertFalse(controller.validateUserInterfaceItem(previousItem))
    XCTAssertFalse(controller.validateUserInterfaceItem(nextItem))
    XCTAssertFalse(controller.validateUserInterfaceItem(saveItem))

    try await play(document, from: 19, to: 28)
    XCTAssertTrue(controller.validateUserInterfaceItem(undoItem))
    XCTAssertFalse(controller.validateUserInterfaceItem(redoItem))
    XCTAssertTrue(controller.validateUserInterfaceItem(previousItem))
  }

  func testLocalMoveCaptureUndoBranchNavigationAndFlipRemainRustBacked() async throws {
    let document = try await readyDocument()
    defer { document.close() }
    let root = try XCTUnwrap(document.snapshotForTesting)
    let rootFEN = try await document.fenForTesting()

    try await play(document, from: 19, to: 28)  // b2 → b3
    let firstBranch = try XCTUnwrap(document.snapshotForTesting)
    let firstFEN = try await document.fenForTesting()
    XCTAssertNotEqual(firstBranch.currentNode, root.currentNode)
    XCTAssertNotEqual(firstFEN, rootFEN)

    document.requestHistoryPrevious()
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.snapshotForTesting?.currentNode, root.currentNode)
    let restoredRootFEN = try await document.fenForTesting()
    XCTAssertEqual(restoredRootFEN, rootFEN)

    try await play(document, from: 29, to: 38)  // c3 → c4, second root branch
    let secondBranch = try XCTUnwrap(document.snapshotForTesting)
    let secondFEN = try await document.fenForTesting()
    XCTAssertNotEqual(secondBranch.currentNode, firstBranch.currentNode)
    XCTAssertEqual(
      Set(document.variationNodeIDsForTesting),
      [0, firstBranch.currentNode, secondBranch.currentNode])

    document.requestNavigate(to: firstBranch.currentNode)
    try await document.waitUntilIdleForTesting()
    let navigatedFirstFEN = try await document.fenForTesting()
    XCTAssertEqual(navigatedFirstFEN, firstFEN)
    document.requestNavigate(to: secondBranch.currentNode)
    try await document.waitUntilIdleForTesting()
    let navigatedSecondFEN = try await document.fenForTesting()
    XCTAssertEqual(navigatedSecondFEN, secondFEN)

    let beforeFlip = try XCTUnwrap(document.snapshotForTesting)
    let beforeFEN = try await document.fenForTesting()
    let dirtyBeforeFlip = document.isDocumentEdited
    document.flipBoard()
    let afterFlip = try XCTUnwrap(document.snapshotForTesting)
    XCTAssertEqual(afterFlip.currentNode, beforeFlip.currentNode)
    XCTAssertEqual(afterFlip.positionHash, beforeFlip.positionHash)
    XCTAssertEqual(afterFlip.repetitionHash, beforeFlip.repetitionHash)
    let afterFlipFEN = try await document.fenForTesting()
    XCTAssertEqual(afterFlipFEN, beforeFEN)
    XCTAssertEqual(document.isDocumentEdited, dirtyBeforeFlip)
    XCTAssertEqual(document.boardPresentation.perspective, .blackAtBottom)

    try await document.replaceWithFixtureForTesting("4k4/4a4/9/9/4p4/4P4/9/9/9/4K4 w - - 0 1")
    try await play(document, from: 40, to: 49)
    let capture = try XCTUnwrap(document.snapshotForTesting)
    XCTAssertEqual(capture.cells[49], 7)
    XCTAssertEqual(capture.cells[40], 0)
    XCTAssertTrue(document.isDocumentEdited)
    XCTAssertTrue(document.undoManager?.canUndo == true)
  }

  func testUndoManagerTerminalStatesAndTemporaryPersistenceFailClosed() async throws {
    let document = try await readyDocument()
    defer { document.close() }
    try await play(document, from: 19, to: 28)
    let moved = try XCTUnwrap(document.snapshotForTesting)

    document.undoManager?.undo()
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.snapshotForTesting?.currentNode, 0)
    document.undoManager?.redo()
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.snapshotForTesting?.currentNode, moved.currentNode)

    try await document.replaceWithFixtureForTesting("3RkR3/9/4P4/9/9/9/9/9/9/4K4 b - - 0 1")
    let mate = try XCTUnwrap(document.snapshotForTesting)
    XCTAssertEqual(mate.terminal, .checkmate(winner: .red))
    document.requestSquare(85)
    XCTAssertEqual(document.snapshotForTesting?.positionHash, mate.positionHash)
    XCTAssertEqual(document.snapshotForTesting?.historyLength, mate.historyLength)

    try await document.replaceWithFixtureForTesting("4k4/4a4/3R1R3/9/9/9/9/9/9/4K4 b - - 0 1")
    XCTAssertEqual(document.snapshotForTesting?.terminal, .stalemate(winner: .red))

    let unchanged = try XCTUnwrap(document.snapshotForTesting)
    XCTAssertThrowsError(try document.data(ofType: "org.nativexiangqi.temporary")) { error in
      XCTAssertEqual(error as? NativeXiangqiTemporaryPersistenceError, .unavailable)
    }
    XCTAssertThrowsError(
      try document.read(from: Data("corrupt".utf8), ofType: "org.nativexiangqi.temporary")
    ) { error in
      XCTAssertEqual(error as? NativeXiangqiTemporaryPersistenceError, .invalidSmokeEnvelope)
    }
    XCTAssertEqual(document.snapshotForTesting?.positionHash, unchanged.positionHash)
    XCTAssertThrowsError(
      try document.read(
        from: NativeXiangqiDocument.temporaryAutosaveSmokeEnvelope,
        ofType: "org.nativexiangqi.temporary")
    ) { error in
      XCTAssertEqual(error as? NativeXiangqiTemporaryPersistenceError, .unavailable)
    }
  }

  func testUnsavedInMemorySessionStaysDirtyAndCannotPretendToSave() async throws {
    let document = try await readyDocument()
    defer { document.close() }
    try await play(document, from: 19, to: 28)
    XCTAssertTrue(document.isDocumentEdited)
    XCTAssertNil(document.fileURL)
    XCTAssertThrowsError(try document.data(ofType: "org.nativexiangqi.temporary")) { error in
      XCTAssertEqual(error as? NativeXiangqiTemporaryPersistenceError, .unavailable)
    }
  }

  func testRapidInputAndRepeatedCloseDoNotAccumulateCoreHandles() async throws {
    let document = try await readyDocument()
    document.requestSquare(19)
    document.requestSquare(29)  // ignored while the bounded first query is pending
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.boardPresentation.selectedSquare, 19)
    try await document.closeForTesting()
    do {
      _ = try await document.fenForTesting()
      XCTFail("closed document unexpectedly retained a live Rust handle")
    } catch {
      XCTAssertEqual(error as? NativeXiangqiDocument.TestingError, .unavailableCore)
    }

    for _ in 0..<65 {
      let cycle = NativeXiangqiDocument()
      cycle.beginInMemoryGameIfNeeded()
      try await cycle.waitUntilIdleForTesting()
      try await cycle.closeForTesting()
    }

    let initializing = NativeXiangqiDocument()
    initializing.beginInMemoryGameIfNeeded()
    try await initializing.closeForTesting()
    XCTAssertFalse(initializing.hasLiveCoreForTesting)
  }

  func testHistoryBrowsingClearsNativeUndoWhileNativeUndoRedoRemainBalanced() async throws {
    let document = try await readyDocument()
    defer { document.close() }
    try await play(document, from: 19, to: 28)
    XCTAssertTrue(document.canUndoMove)

    document.requestHistoryPrevious()
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.snapshotForTesting?.currentNode, 0)
    XCTAssertFalse(document.canUndoMove)
    document.performNativeUndo()
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.snapshotForTesting?.currentNode, 0)

    try await play(document, from: 29, to: 38)
    let branch = try XCTUnwrap(document.snapshotForTesting)
    document.performNativeUndo()
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.snapshotForTesting?.currentNode, 0)
    document.performNativeRedo()
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.snapshotForTesting?.currentNode, branch.currentNode)
  }

  func testNavigateToLastDisplayedNodeReachesLeafRatherThanOnlyOneChild() async throws {
    let document = try await readyDocument()
    defer { document.close() }
    try await play(document, from: 19, to: 28)  // b2 → b3
    try await play(document, from: 54, to: 45)  // a6 → a5
    let leaf = try XCTUnwrap(document.snapshotForTesting?.currentNode)
    XCTAssertNotEqual(leaf, 0)

    document.requestNavigateToStart()
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.snapshotForTesting?.currentNode, 0)
    document.requestNavigateToLastDisplayedNode()
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.snapshotForTesting?.currentNode, leaf)
  }

  func testPostMutationSnapshotFailureQuarantinesTheCoreSession() async throws {
    let document = try await readyDocument()
    document.requestSquare(19)
    try await document.waitUntilIdleForTesting()
    document.failNextPostMutationSnapshotForTesting()
    document.requestSquare(28)
    try await document.waitUntilIdleForTesting()

    XCTAssertNil(document.snapshotForTesting)
    XCTAssertFalse(document.hasLiveCoreForTesting)
    XCTAssertFalse(document.isInteractionActive)
    XCTAssertTrue(document.visibleStatusText.contains("已关闭"))
  }

  private func readyDocument() async throws -> NativeXiangqiDocument {
    _ = NSApplication.shared
    let document = NativeXiangqiDocument()
    document.beginInMemoryGameIfNeeded()
    try await document.waitUntilLocalSessionReady()
    XCTAssertNotNil(document.snapshotForTesting)
    return document
  }

  private func play(_ document: NativeXiangqiDocument, from: UInt8, to: UInt8) async throws {
    document.requestSquare(from)
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.boardPresentation.selectedSquare, from)
    XCTAssertTrue(document.boardPresentation.legalDestinations.contains(to))
    document.requestSquare(to)
    try await document.waitUntilIdleForTesting()
    XCTAssertNil(document.boardPresentation.selectedSquare)
  }

  private func containsView<T: NSView>(of type: T.Type, in root: NSView) -> Bool {
    if root is T {
      return true
    }
    return root.subviews.contains { containsView(of: type, in: $0) }
  }

  private func firstView<T: NSView>(of type: T.Type, in root: NSView) -> T? {
    if let match = root as? T {
      return match
    }
    for child in root.subviews {
      if let match = firstView(of: type, in: child) {
        return match
      }
    }
    return nil
  }

  private func keyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: keyCode
      )
    )
  }

  private func pointerEvent(for square: UInt8, board: XiangqiBoardView, window: NSWindow) throws
    -> NSEvent
  {
    let geometry = try XCTUnwrap(
      XiangqiBoardGeometry(
        bounds: board.bounds,
        backingScaleFactor: max(window.backingScaleFactor, 1),
        perspective: board.presentation.perspective
      ))
    let point = try XCTUnwrap(geometry.point(forCanonicalSquare: square))
    return try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: board.convert(point, to: nil),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: Int(square),
        clickCount: 1,
        pressure: 1
      ))
  }

  private func containsOutlineView(in root: NSView) -> Bool {
    if root is NSOutlineView {
      return true
    }
    return root.subviews.contains { containsOutlineView(in: $0) }
  }

  private func containsText(_ text: String, in root: NSView) -> Bool {
    if let label = root as? NSTextField, label.stringValue == text {
      return true
    }
    return root.subviews.contains { containsText(text, in: $0) }
  }
}
