import AppKit
import CoreGraphics
import XCTest

@testable import XiangqiUI

final class XiangqiBoardGeometryTests: XCTestCase {
  func testAllCanonicalSquaresRoundTripAtRedAndBlackPerspectives() throws {
    for perspective in [XiangqiBoardPerspective.redAtBottom, .blackAtBottom] {
      let geometry = try XCTUnwrap(
        XiangqiBoardGeometry(
          bounds: CGRect(x: 0, y: 0, width: 900, height: 1_000),
          backingScaleFactor: 2,
          perspective: perspective
        )
      )
      for square in UInt8(0)..<90 {
        let point = try XCTUnwrap(geometry.point(forCanonicalSquare: square))
        XCTAssertEqual(geometry.canonicalSquare(at: point), square)
      }
    }
  }

  func testFlippingChangesVisibleLocationButNotCanonicalSquare() throws {
    let bounds = CGRect(x: 11, y: 17, width: 700, height: 830)
    let red = try XCTUnwrap(
      XiangqiBoardGeometry(bounds: bounds, backingScaleFactor: 3, perspective: .redAtBottom))
    let black = try XCTUnwrap(
      XiangqiBoardGeometry(bounds: bounds, backingScaleFactor: 3, perspective: .blackAtBottom))
    let redPoint = try XCTUnwrap(red.point(forCanonicalSquare: 0))
    let blackPoint = try XCTUnwrap(black.point(forCanonicalSquare: 0))
    XCTAssertNotEqual(redPoint, blackPoint)
    XCTAssertEqual(red.canonicalSquare(at: redPoint), 0)
    XCTAssertEqual(black.canonicalSquare(at: blackPoint), 0)
    XCTAssertEqual(red.displayedCoordinateLabel(forCanonicalSquare: 0), "a0")
    XCTAssertEqual(black.displayedCoordinateLabel(forCanonicalSquare: 0), "i9")
  }

  func testEdgesToleranceAndInvalidGeometryFailClosed() throws {
    let geometry = try XCTUnwrap(
      XiangqiBoardGeometry(
        bounds: CGRect(x: 0, y: 0, width: 620, height: 720),
        backingScaleFactor: 1,
        perspective: .redAtBottom
      )
    )
    XCTAssertNil(geometry.canonicalSquare(at: CGPoint(x: -.infinity, y: 0)))
    XCTAssertNil(geometry.canonicalSquare(at: CGPoint(x: CGFloat.nan, y: 0)))
    XCTAssertNil(
      geometry.canonicalSquare(
        at: CGPoint(x: geometry.gridRect.minX - geometry.spacing, y: geometry.gridRect.minY)))
    XCTAssertNil(
      XiangqiBoardGeometry(bounds: .zero, backingScaleFactor: 2, perspective: .redAtBottom))
    XCTAssertNil(
      XiangqiBoardGeometry(
        bounds: CGRect(x: 0, y: 0, width: 100, height: 100), backingScaleFactor: 0,
        perspective: .redAtBottom))
    let rect = try XCTUnwrap(geometry.invalidationRect(forCanonicalSquare: 89))
    XCTAssertTrue(geometry.bounds.contains(rect))
  }
}

@MainActor
final class XiangqiBoardViewAccessibilityTests: XCTestCase {
  private final class Delegate: XiangqiBoardViewDelegate {
    var requestedSquares: [UInt8] = []
    var navigationRequests: [XiangqiBoardNavigation] = []

    func boardView(_ boardView: XiangqiBoardView, didRequestSquare square: UInt8) {
      requestedSquares.append(square)
    }

    func boardViewDidRequestCancel(_ boardView: XiangqiBoardView) {}

    func boardView(
      _ boardView: XiangqiBoardView, didRequestNavigation navigation: XiangqiBoardNavigation
    ) {
      navigationRequests.append(navigation)
    }
  }

  func testBoardUsesOneViewAndStableVirtualAccessibilitySquares() throws {
    _ = NSApplication.shared
    let board = XiangqiBoardView(frame: NSRect(x: 0, y: 0, width: 720, height: 820))
    let delegate = Delegate()
    board.delegate = delegate
    board.setPresentation(try makePresentation(perspective: .redAtBottom))
    board.layoutSubtreeIfNeeded()

    let initialElements = board.virtualAccessibilityElements()
    XCTAssertEqual(board.subviews.count, 0)
    XCTAssertNil(board.layer)
    XCTAssertEqual(initialElements.count, 90)
    XCTAssertEqual(board.accessibilityChildren()?.count, 90)
    let redLabel = try XCTUnwrap(initialElements[19].accessibilityLabel())
    XCTAssertTrue(redLabel.contains("规范坐标b2"))

    XCTAssertTrue(initialElements[19].accessibilityPerformPress())
    XCTAssertEqual(delegate.requestedSquares, [19])
    XCTAssertTrue(try XCTUnwrap(initialElements[19].accessibilityLabel()).contains("键盘焦点"))

    board.setPresentation(try makePresentation(perspective: .blackAtBottom))
    let flippedElements = board.virtualAccessibilityElements()
    XCTAssertEqual(flippedElements.count, 90)
    XCTAssertTrue(zip(initialElements, flippedElements).allSatisfy { $0 === $1 })
    let blackLabel = try XCTUnwrap(flippedElements[19].accessibilityLabel())
    XCTAssertTrue(blackLabel.contains("显示坐标h7"))
  }

  func testKeyboardHistoryCommandsAndFlippedGridNavigation() throws {
    _ = NSApplication.shared
    let board = XiangqiBoardView(frame: NSRect(x: 0, y: 0, width: 720, height: 820))
    let delegate = Delegate()
    board.delegate = delegate
    board.setPresentation(try makePresentation(perspective: .redAtBottom))

    board.keyDown(with: try keyEvent(keyCode: 123, modifiers: []))
    board.keyDown(with: try keyEvent(keyCode: 124, modifiers: []))
    board.keyDown(with: try keyEvent(keyCode: 123, modifiers: .command))
    board.keyDown(with: try keyEvent(keyCode: 124, modifiers: .command))
    XCTAssertEqual(delegate.navigationRequests, [.previous, .next, .first, .last])

    board.keyDown(with: try keyEvent(keyCode: 124, modifiers: .option))
    XCTAssertEqual(board.keyboardFocusSquare, 20)

    board.setPresentation(try makePresentation(perspective: .blackAtBottom))
    XCTAssertTrue(board.virtualAccessibilityElements()[40].accessibilityPerformPress())
    board.keyDown(with: try keyEvent(keyCode: 124, modifiers: .option))
    XCTAssertEqual(board.keyboardFocusSquare, 39)

    board.acceptsBoardInput = false
    XCTAssertFalse(board.virtualAccessibilityElements()[39].accessibilityPerformPress())
  }

  func testAccessibilityRegistryReleasesClosedBoardsAndHasABound() {
    let baseline = XiangqiBoardView.accessibilityRegistryCountForTesting
    var board: XiangqiBoardView? = XiangqiBoardView(frame: .zero)
    XCTAssertNotNil(board)
    XCTAssertLessThanOrEqual(XiangqiBoardView.accessibilityRegistryCountForTesting, baseline + 1)
    board = nil
    XCTAssertEqual(XiangqiBoardView.accessibilityRegistryCountForTesting, baseline)
  }

  func testAccessibilityRegistryRefusesTheSixtyFifthLiveBoard() throws {
    let baseline = XiangqiBoardView.accessibilityRegistryCountForTesting
    var boards: [XiangqiBoardView] = []
    boards.reserveCapacity(65)
    for _ in 0..<65 {
      boards.append(XiangqiBoardView(frame: .zero))
    }
    XCTAssertLessThanOrEqual(XiangqiBoardView.accessibilityRegistryCountForTesting, 64)
    let lastBoard = try XCTUnwrap(boards.last)
    XCTAssertFalse(lastBoard.virtualAccessibilityElements()[0].accessibilityPerformPress())
    boards.removeAll()
    XCTAssertEqual(XiangqiBoardView.accessibilityRegistryCountForTesting, baseline)
  }

  func testPresentationInvalidationIncludesCandidatePreviewAndCheckMarker() throws {
    _ = NSApplication.shared
    let board = XiangqiBoardView(frame: NSRect(x: 0, y: 0, width: 720, height: 820))
    var cells = Array(repeating: UInt8(0), count: 90)
    cells[4] = 1
    cells[85] = 8
    let old = try XCTUnwrap(
      XiangqiBoardPresentation(
        cells: cells,
        sideToMove: .red,
        checkedSide: nil,
        terminal: .ongoing,
        selectedSquare: nil,
        legalDestinations: [],
        lastMove: nil,
        perspective: .redAtBottom,
        fakeCandidates: []
      ))
    let new = try XCTUnwrap(
      XiangqiBoardPresentation(
        cells: cells,
        sideToMove: .red,
        checkedSide: .red,
        terminal: .ongoing,
        selectedSquare: nil,
        legalDestinations: [],
        lastMove: nil,
        perspective: .redAtBottom,
        fakeCandidates: [XiangqiBoardCandidate(title: "候选 1", detail: "非引擎")]
      ))
    board.setPresentation(old)
    board.layoutSubtreeIfNeeded()
    let invalidation = try XCTUnwrap(
      board.invalidationRectForPresentationChange(from: old, to: new))
    XCTAssertTrue(
      invalidation.contains(CGPoint(x: board.bounds.minX + 9, y: board.bounds.minY + 9)))
    let geometry = try XCTUnwrap(
      XiangqiBoardGeometry(
        bounds: board.bounds,
        backingScaleFactor: max(NSScreen.main?.backingScaleFactor ?? 1, 1),
        perspective: .redAtBottom
      ))
    let generalRect = try XCTUnwrap(geometry.invalidationRect(forCanonicalSquare: 4))
    XCTAssertTrue(invalidation.intersects(generalRect))
  }

  func testCandidatePresentationHardCapRejectsTheFourthCandidate() {
    let candidates = (0..<4).map { index in
      XiangqiBoardCandidate(title: "候选 \(index)", detail: "非引擎")
    }
    XCTAssertNil(
      XiangqiBoardPresentation(
        cells: Array(repeating: 0, count: 90),
        sideToMove: .red,
        checkedSide: nil,
        terminal: .ongoing,
        selectedSquare: nil,
        legalDestinations: [],
        lastMove: nil,
        perspective: .redAtBottom,
        fakeCandidates: candidates
      ))
  }

  private func makePresentation(perspective: XiangqiBoardPerspective) throws
    -> XiangqiBoardPresentation
  {
    let cells = Array(repeating: UInt8(0), count: 90)
    return try XCTUnwrap(
      XiangqiBoardPresentation(
        cells: cells,
        sideToMove: .red,
        checkedSide: nil,
        terminal: .ongoing,
        selectedSquare: 19,
        legalDestinations: [28],
        lastMove: XiangqiBoardDisplayedMove(from: 19, to: 28),
        perspective: perspective,
        fakeCandidates: [XiangqiBoardCandidate(title: "候选 1", detail: "非引擎界面提示")]
      )
    )
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
}
