import AppKit
import Foundation
import XCTest
import XiangqiCoreBinary
import XiangqiDocumentKitVersionFixture
import XiangqiUI

@testable import XiangqiDocumentKit

@MainActor
final class NativeXiangqiDocumentSmokeTests: XCTestCase {
  func testXQGameUsesActualNSDocumentDataReadLifecycle() async throws {
    _ = NSApplication.shared
    let document = NativeXiangqiDocument()
    document.beginInMemoryGameIfNeeded()
    try await document.waitUntilLocalSessionReady()
    defer { document.close() }
    try await play(document, from: 19, to: 28)
    let expectedFEN = try await document.exportFEN(.current)

    XCTAssertTrue(NativeXiangqiDocument.autosavesInPlace)
    XCTAssertTrue(
      NativeXiangqiDocument.canConcurrentlyReadDocuments(
        ofType: NativeXiangqiDocument.documentTypeName))
    let data = try document.data(ofType: NativeXiangqiDocument.documentTypeName)
    XCTAssertLessThan(data.count, 64 * 1024 * 1024)

    let restored = NativeXiangqiDocument()
    try restored.read(from: data, ofType: NativeXiangqiDocument.documentTypeName)
    restored.makeWindowControllers()
    try await restored.waitUntilLocalSessionReady()
    defer { restored.close() }
    let restoredFEN = try await restored.exportFEN(.current)
    XCTAssertEqual(restoredFEN, expectedFEN)
    XCTAssertThrowsError(try document.data(ofType: "wrong.type"))
  }

  func testFailedV0MigrationLeavesSourceBytesAndLiveDocumentUntouched() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("NativeXiangqi-invalid-v0-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("invalid-v0.xqgame", isDirectory: false)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // A structurally valid v0 record whose annotation refers to no replayed
    // node. It reaches migration validation rather than failing as generic JSON.
    let invalidText = [
      "{\"schemaVersion\":0,\"documentID\":\"00000000-0000-4000-8000-000000000102\",",
      "\"createdAtMilliseconds\":1,\"modifiedAtMilliseconds\":2,",
      "\"initialFEN\":\"rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1\",",
      "\"ruleProfile\":{\"id\":1,\"version\":1,\"snapshot\":\"base-v1\"},",
      "\"ucciMainline\":[\"b2b3\"],\"annotations\":{\"0\":\"root\",\"2\":\"orphan\"},",
      "\"result\":null,\"extensions\":{}}",
    ].joined()
    let sourceBytes = Data(invalidText.utf8)
    try sourceBytes.write(to: url)

    let document = NativeXiangqiDocument()
    document.makeWindowControllers()
    try await document.waitUntilLocalSessionReady()
    defer { document.close() }
    try await play(document, from: 19, to: 28)
    let liveFEN = try await document.exportFEN(.current)
    let liveBytes = try document.data(ofType: NativeXiangqiDocument.documentTypeName)

    XCTAssertThrowsError(
      try document.read(from: url, ofType: NativeXiangqiDocument.documentTypeName)
    ) {
      error in
      XCTAssertEqual(error as? NativeXiangqiDocumentFormatError, .field("annotations.key"))
    }
    XCTAssertEqual(try Data(contentsOf: url), sourceBytes)
    let unchangedLiveFEN = try await document.exportFEN(.current)
    XCTAssertEqual(unchangedLiveFEN, liveFEN)
    XCTAssertEqual(try document.data(ofType: NativeXiangqiDocument.documentTypeName), liveBytes)
  }

  func testSaveAsAutosavePreparedReopenAndLocalRevertPreserveCanonicalRecord() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("NativeXiangqi-T040-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("roundtrip.xqgame", isDirectory: false)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let document = NativeXiangqiDocument()
    document.makeWindowControllers()
    try await document.waitUntilLocalSessionReady()
    defer { document.close() }

    try await play(document, from: 19, to: 28)  // b2 → b3
    document.setCurrentAnnotation("保存的注释")
    try await document.waitUntilIdleForTesting()
    let afterSaveFEN = try await document.exportFEN(.current)
    try await save(document, to: url, operation: .saveAsOperation)
    XCTAssertEqual(document.fileURL, url)
    XCTAssertFalse(document.isDocumentEdited)
    XCTAssertFalse(try Data(contentsOf: url).isEmpty)

    try await play(document, from: 64, to: 55)  // b7 → b6
    let afterAutosaveFEN = try await document.exportFEN(.current)
    try await autosave(document)
    XCTAssertFalse(document.hasUnautosavedChanges)

    try await play(document, from: 29, to: 38)  // c3 → c4
    XCTAssertTrue(document.isDocumentEdited)
    let preRestoreFEN = try await document.exportFEN(.current)
    let preRestoreBytes = try document.data(ofType: NativeXiangqiDocument.documentTypeName)
    XCTAssertEqual(document.restoreSavedDocument(), .requiresExplicitConfirmation)
    let unchangedFEN = try await document.exportFEN(.current)
    XCTAssertEqual(unchangedFEN, preRestoreFEN)
    XCTAssertEqual(
      try document.data(ofType: NativeXiangqiDocument.documentTypeName), preRestoreBytes)
    XCTAssertTrue(document.isDocumentEdited)

    XCTAssertEqual(
      document.restoreSavedDocument(discardingUnsavedChanges: true),
      .started
    )
    try await document.waitUntilIdleForTesting()
    let restoredFEN = try await document.exportFEN(.current)
    XCTAssertEqual(restoredFEN, afterAutosaveFEN)
    XCTAssertNotEqual(restoredFEN, afterSaveFEN)
    XCTAssertFalse(document.isDocumentEdited)
    XCTAssertFalse(document.undoManager?.canUndo == true)

    let reopened = NativeXiangqiDocument()
    try reopened.read(from: Data(contentsOf: url), ofType: NativeXiangqiDocument.documentTypeName)
    reopened.makeWindowControllers()
    try await reopened.waitUntilLocalSessionReady()
    defer { reopened.close() }
    let reopenedFEN = try await reopened.exportFEN(.current)
    XCTAssertEqual(reopenedFEN, afterAutosaveFEN)
    reopened.requestHistoryPrevious()
    try await reopened.waitUntilIdleForTesting()
    let reopenedAnnotation = try await reopened.currentAnnotation()
    XCTAssertEqual(reopenedAnnotation, "保存的注释")
  }

  func testUserEnteredInitialFENStartsAnUntitledDocumentDirty() async throws {
    _ = NSApplication.shared
    let fen =
      "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
    let document = NativeXiangqiDocument.newDocument(initialFEN: fen)
    document.makeWindowControllers()
    try await document.waitUntilLocalSessionReady()
    defer {
      document.updateChangeCount(.changeCleared)
      document.close()
    }

    XCTAssertTrue(document.isDocumentEdited)
    let exportedInitialFEN = try await document.exportFEN(.initial)
    XCTAssertEqual(exportedInitialFEN, fen)
  }

  func testConfirmedLocalVersionRecoveryAutosavesBeforeReopen() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("NativeXiangqi-history-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("history.xqgame", isDirectory: false)
    let versionURL = directory.appendingPathComponent("version-a.xqgame", isDirectory: false)
    let unrelatedURL = directory.appendingPathComponent("unrelated.xqgame", isDirectory: false)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let document = NativeXiangqiDocument()
    document.makeWindowControllers()
    try await document.waitUntilLocalSessionReady()
    defer { document.close() }

    try await play(document, from: 19, to: 28)
    let versionAFEN = try await document.exportFEN(.current)
    try await save(document, to: url, operation: .saveAsOperation)
    try FileManager.default.copyItem(at: url, to: versionURL)
    try createLocalVersion(for: url, contents: versionURL)
    try FileManager.default.copyItem(at: versionURL, to: unrelatedURL)

    try await play(document, from: 64, to: 55)
    let versionBFEN = try await document.exportFEN(.current)
    try await save(document, to: url, operation: .saveOperation)

    let fabricatedDescriptor = NativeXiangqiLocalVersionDescriptor(
      documentURL: url,
      versionURL: unrelatedURL,
      title: "伪造本地历史版本"
    )
    let bytesBeforeRejectedRestore = try document.data(
      ofType: NativeXiangqiDocument.documentTypeName)
    XCTAssertEqual(
      document.restoreLocalVersion(fabricatedDescriptor, discardingUnsavedChanges: true),
      .started
    )
    try await document.waitUntilIdleForTesting()
    let rejectedRestoreFEN = try await document.exportFEN(.current)
    XCTAssertEqual(rejectedRestoreFEN, versionBFEN)
    XCTAssertEqual(
      try document.data(ofType: NativeXiangqiDocument.documentTypeName),
      bytesBeforeRejectedRestore
    )

    let catalog = NativeXiangqiLocalVersionCatalog()
    let descriptors = await catalog.descriptors(for: url)
    let descriptor = try XCTUnwrap(descriptors.first)
    XCTAssertEqual(document.restoreLocalVersion(descriptor), .requiresExplicitConfirmation)
    let unreplacedFEN = try await document.exportFEN(.current)
    XCTAssertEqual(unreplacedFEN, versionBFEN)
    XCTAssertEqual(
      document.restoreLocalVersion(descriptor, discardingUnsavedChanges: true),
      .started
    )
    try await document.waitUntilIdleForTesting()
    let restoredFEN = try await document.exportFEN(.current)
    XCTAssertEqual(restoredFEN, versionAFEN)

    let reopened = NativeXiangqiDocument()
    try reopened.read(from: url, ofType: NativeXiangqiDocument.documentTypeName)
    reopened.makeWindowControllers()
    try await reopened.waitUntilLocalSessionReady()
    defer { reopened.close() }
    let reopenedFEN = try await reopened.exportFEN(.current)
    XCTAssertEqual(reopenedFEN, versionAFEN)
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

  private func play(_ document: NativeXiangqiDocument, from: UInt8, to: UInt8) async throws {
    document.requestSquare(from)
    try await document.waitUntilIdleForTesting()
    document.requestSquare(to)
    try await document.waitUntilIdleForTesting()
  }

  private func save(
    _ document: NativeXiangqiDocument,
    to url: URL,
    operation: NSDocument.SaveOperationType
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      document.save(to: url, ofType: NativeXiangqiDocument.documentTypeName, for: operation) {
        error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func autosave(_ document: NativeXiangqiDocument) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      document.autosave(withImplicitCancellability: true) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func createLocalVersion(for documentURL: URL, contents: URL) throws {
    var error: NSError?
    guard NXQCreateLocalFileVersion(documentURL, contents, &error) else {
      throw error ?? NativeXiangqiDocumentReadinessError.unavailable
    }
  }

  private func readyDocument() async throws -> NativeXiangqiDocument {
    _ = NSApplication.shared
    let document = NativeXiangqiDocument()
    document.beginInMemoryGameIfNeeded()
    try await document.waitUntilLocalSessionReady()
    XCTAssertNotNil(document.snapshotForTesting)
    return document
  }

  func testHistoryNavigationFromCleanStateDirtiedUntilSaved() async throws {
    let document = try await readyDocument()
    defer { document.close() }
    try await play(document, from: 19, to: 28)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("NativeXiangqi-nav-dirty-\(UUID().uuidString).xqgame")
    defer { try? FileManager.default.removeItem(at: url) }
    try await save(document, to: url, operation: .saveAsOperation)
    XCTAssertFalse(document.isDocumentEdited)

    // The cursor is persisted document content; browsing must not silently drop
    // it on close without a save prompt.
    document.requestHistoryPrevious()
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.snapshotForTesting?.currentNode, 0)
    XCTAssertTrue(document.isDocumentEdited)

    document.requestHistoryNext()
    try await document.waitUntilIdleForTesting()
    XCTAssertTrue(document.isDocumentEdited)

    // Navigating to the already-current node is a no-op and must not dirty.
    let currentNode = try XCTUnwrap(document.snapshotForTesting?.currentNode)
    document.updateChangeCount(.changeCleared)
    XCTAssertFalse(document.isDocumentEdited)
    document.requestNavigate(to: currentNode)
    try await document.waitUntilIdleForTesting()
    XCTAssertFalse(document.isDocumentEdited)
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
    let annotationItem = NSMenuItem(
      title: "编辑注释", action: NSSelectorFromString("editCurrentAnnotation:"), keyEquivalent: "")

    XCTAssertFalse(controller.validateUserInterfaceItem(undoItem))
    XCTAssertFalse(controller.validateUserInterfaceItem(redoItem))
    XCTAssertFalse(controller.validateUserInterfaceItem(previousItem))
    XCTAssertFalse(controller.validateUserInterfaceItem(nextItem))
    XCTAssertTrue(controller.validateUserInterfaceItem(annotationItem))

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

  func testUndoManagerTerminalStatesAndInvalidDocumentBytesPreserveLiveState() async throws {
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
    let cachedBytes = try document.data(ofType: NativeXiangqiDocument.documentTypeName)
    XCTAssertThrowsError(
      try document.read(from: Data("corrupt".utf8), ofType: NativeXiangqiDocument.documentTypeName))
    XCTAssertEqual(document.snapshotForTesting?.positionHash, unchanged.positionHash)
    XCTAssertEqual(try document.data(ofType: NativeXiangqiDocument.documentTypeName), cachedBytes)
  }

  func testUnsavedInMemorySessionStaysDirtyAndHasBoundedSaveSnapshot() async throws {
    let document = try await readyDocument()
    defer { document.close() }
    try await play(document, from: 19, to: 28)
    XCTAssertTrue(document.isDocumentEdited)
    XCTAssertNil(document.fileURL)
    XCTAssertFalse(try document.data(ofType: NativeXiangqiDocument.documentTypeName).isEmpty)
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

  func testNativeUndoKeepsRetainedVariationDirtyUntilItIsSaved() async throws {
    let document = try await readyDocument()
    defer { document.close() }
    document.updateChangeCount(.changeCleared)
    XCTAssertFalse(document.isDocumentEdited)

    try await play(document, from: 19, to: 28)
    XCTAssertTrue(document.isDocumentEdited)
    document.undoManager?.undo()
    try await document.waitUntilIdleForTesting()

    XCTAssertEqual(document.snapshotForTesting?.currentNode, 0)
    XCTAssertTrue(document.isDocumentEdited)
    let encoded = try document.data(ofType: NativeXiangqiDocument.documentTypeName)
    let restored = NativeXiangqiDocument()
    try restored.read(from: encoded, ofType: NativeXiangqiDocument.documentTypeName)
    restored.makeWindowControllers()
    try await restored.waitUntilLocalSessionReady()
    defer { restored.close() }
    XCTAssertEqual(restored.variationNodeIDsForTesting, [0, 1])
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

  func testFENAndUCCIFailuresExposeExactSafeFieldOrPlyWithoutChangingLiveDocument() async throws {
    let document = try await readyDocument()
    defer { document.close() }
    let beforeFEN = try await document.fenForTesting()
    let beforeBytes = try document.data(ofType: NativeXiangqiDocument.documentTypeName)
    document.updateChangeCount(.changeCleared)

    document.replaceInitialPosition(
      withFEN: "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR x - - 0 1"
    )
    try await document.waitUntilIdleForTesting()
    let fenAfterBadFEN = try await document.fenForTesting()
    XCTAssertTrue(document.visibleStatusText.contains("side-to-move"))
    XCTAssertEqual(fenAfterBadFEN, beforeFEN)
    XCTAssertEqual(try document.data(ofType: NativeXiangqiDocument.documentTypeName), beforeBytes)
    XCTAssertFalse(document.isDocumentEdited)

    document.replaceInitialPosition(
      withFEN: String(repeating: "x", count: NativeXiangqiDocument.maximumDocumentFENBytes + 1)
    )
    try await document.waitUntilIdleForTesting()
    XCTAssertTrue(document.visibleStatusText.contains("initialFEN"))
    let fenAfterOversizeFEN = try await document.fenForTesting()
    XCTAssertEqual(fenAfterOversizeFEN, beforeFEN)
    XCTAssertEqual(try document.data(ofType: NativeXiangqiDocument.documentTypeName), beforeBytes)
    XCTAssertFalse(document.isDocumentEdited)

    document.replaceRecord(withUCCIMainline: "b2b3 a0a9")
    try await document.waitUntilIdleForTesting()
    let fenAfterBadUCCI = try await document.fenForTesting()
    XCTAssertTrue(document.visibleStatusText.contains("第 2 手"))
    XCTAssertEqual(fenAfterBadUCCI, beforeFEN)
    XCTAssertEqual(try document.data(ofType: NativeXiangqiDocument.documentTypeName), beforeBytes)
    XCTAssertFalse(document.isDocumentEdited)
  }

  func testRegisteredUndoFailureKeepsAppendOnlyRecordConservativelyDirty() async throws {
    let document = try await readyDocument()
    defer { document.close() }
    try await play(document, from: 19, to: 28)
    XCTAssertTrue(document.undoManager?.canUndo == true)
    // Simulate a just-saved document. UndoManager will issue its automatic
    // change-undone transition before the asynchronous Rust inverse reaches its
    // post-mutation snapshot, so the injected failure must explicitly re-dirty.
    document.updateChangeCount(.changeCleared)
    XCTAssertFalse(document.isDocumentEdited)
    document.failNextPostMutationSnapshotForTesting()
    document.undoManager?.undo()
    try await document.waitUntilIdleForTesting()
    XCTAssertTrue(document.isDocumentEdited)
    XCTAssertFalse(document.hasLiveCoreForTesting)
    XCTAssertTrue(document.visibleStatusText.contains("已关闭"))
  }

  func testRegisteredAnnotationUndoFailureKeepsDocumentDirty() async throws {
    let document = try await readyDocument()
    defer { document.close() }
    document.setCurrentAnnotation("可撤销注释")
    try await document.waitUntilIdleForTesting()
    XCTAssertTrue(document.undoManager?.canUndo == true)
    document.updateChangeCount(.changeCleared)
    document.failNextPostMutationSnapshotForTesting()
    document.undoManager?.undo()
    try await document.waitUntilIdleForTesting()
    XCTAssertTrue(document.isDocumentEdited)
    XCTAssertFalse(document.hasLiveCoreForTesting)
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

  #if DEBUG
    func testNearCapacityCoreMutationIsRejectedBeforeRustStateChanges() async throws {
      let document = try await readyDocument()
      defer { document.close() }
      let beforeFEN = try await document.fenForTesting()
      document.requestSquare(19)
      try await document.waitUntilIdleForTesting()
      document.setPersistenceByteCountOverrideForTesting(
        NativeXiangqiDocumentFormatLimits.maximumFileBytes
          - NativeXiangqiDocumentPersistenceAdmission.reservedCoreMutationBytes + 1
      )
      defer { document.setPersistenceByteCountOverrideForTesting(nil) }

      document.requestSquare(28)
      try await document.waitUntilIdleForTesting()
      let afterFEN = try await document.fenForTesting()
      XCTAssertEqual(afterFEN, beforeFEN)
      XCTAssertTrue(document.hasLiveCoreForTesting)
      XCTAssertTrue(document.visibleStatusText.contains("资源上限"))
    }

    func testNearCapacityNavigationIsRejectedBeforeRustStateChanges() async throws {
      let document = try await readyDocument()
      defer { document.close() }
      try await play(document, from: 19, to: 28)
      let beforeFEN = try await document.fenForTesting()
      let beforeNode = try XCTUnwrap(document.snapshotForTesting?.currentNode)
      let beforeBytes = try document.data(ofType: NativeXiangqiDocument.documentTypeName)
      document.setPersistenceByteCountOverrideForTesting(
        NativeXiangqiDocumentFormatLimits.maximumFileBytes
          - NativeXiangqiDocumentPersistenceAdmission.reservedNavigationMutationBytes + 1
      )
      defer { document.setPersistenceByteCountOverrideForTesting(nil) }

      document.requestNavigate(to: 0)
      try await document.waitUntilIdleForTesting()
      let afterFEN = try await document.fenForTesting()
      XCTAssertEqual(afterFEN, beforeFEN)
      XCTAssertEqual(document.snapshotForTesting?.currentNode, beforeNode)
      XCTAssertEqual(try document.data(ofType: NativeXiangqiDocument.documentTypeName), beforeBytes)
      XCTAssertTrue(document.hasLiveCoreForTesting)
      XCTAssertTrue(document.visibleStatusText.contains("资源上限"))
    }
  #endif

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
