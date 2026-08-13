import XCTest

@testable import XiangqiCoreBinary

final class XiangqiCoreBinaryTests: XCTestCase {
  private let requiredCapabilities =
    GeneratedFFIABI.capabilityAbiInfo
    | GeneratedFFIABI.capabilityBuildInfo
    | GeneratedFFIABI.capabilityOwnedBuffers
    | GeneratedFFIABI.capabilityGameHandles
    | GeneratedFFIABI.capabilityBatchRules
    | GeneratedFFIABI.capabilityFenUcci
    | GeneratedFFIABI.capabilityBaseHistory
    | GeneratedFFIABI.capabilityDocumentTree
    | GeneratedFFIABI.capabilityDocumentRestore

  func testLinkedABIAndBuildInfoRoundTrip() {
    let validation = XiangqiCoreBinary.validateABIForDebug()
    guard case .success(let info) = validation else {
      return XCTFail("expected linked ABI validation to pass, got \(validation)")
    }
    XCTAssertEqual(info.major, GeneratedFFIABI.major)
    XCTAssertGreaterThanOrEqual(info.minor, GeneratedFFIABI.minimumMinor)

    let buildInfo = XiangqiCoreBinary.buildInfo()
    guard case .success(let value) = buildInfo else {
      return XCTFail("expected owned build-info buffer to round trip, got \(buildInfo)")
    }
    XCTAssertTrue(value.contains("product=NativeXiangqi"))
    XCTAssertTrue(value.contains(GeneratedFFIABI.sourceSHA256))
  }

  func testCompatibilityRejectsMajorMinorCapabilitiesAndReservedField() {
    XCTAssertEqual(
      XiangqiCoreBinary.evaluateABI(
        major: GeneratedFFIABI.major &+ 1,
        minor: GeneratedFFIABI.minimumMinor,
        capabilities: GeneratedFFIABI.capabilityAbiInfo,
        buildInfoFormat: GeneratedFFIABI.buildInfoFormat,
        reserved: 0
      ),
      .failure(.abiMajor(found: GeneratedFFIABI.major &+ 1, expected: GeneratedFFIABI.major))
    )
    XCTAssertEqual(
      XiangqiCoreBinary.evaluateABI(
        major: GeneratedFFIABI.major,
        minor: 0,
        capabilities: GeneratedFFIABI.capabilityAbiInfo,
        buildInfoFormat: GeneratedFFIABI.buildInfoFormat,
        reserved: 0,
        minimumMinor: 1
      ),
      .failure(.abiMinor(found: 0, minimum: 1))
    )
    XCTAssertEqual(
      XiangqiCoreBinary.evaluateABI(
        major: GeneratedFFIABI.major,
        minor: GeneratedFFIABI.minimumMinor,
        capabilities: 0,
        buildInfoFormat: GeneratedFFIABI.buildInfoFormat,
        reserved: 0
      ),
      .failure(
        .capabilities(
          found: 0,
          required: requiredCapabilities
        )
      )
    )
    XCTAssertEqual(
      XiangqiCoreBinary.evaluateABI(
        major: GeneratedFFIABI.major,
        minor: GeneratedFFIABI.minimumMinor,
        capabilities: requiredCapabilities,
        buildInfoFormat: GeneratedFFIABI.buildInfoFormat,
        reserved: 1
      ),
      .failure(.reservedField(1))
    )
  }

  func testGameLifecycleUsesImmutableBatchesAndTransactionalUCCI() async throws {
    let game = try await XiangqiCoreGame.createInitial()
    let initialFEN = try await game.fen()
    let initialSnapshot = try await game.snapshot()
    XCTAssertEqual(initialSnapshot.cells.count, 90)
    XCTAssertEqual(initialSnapshot.sideToMove, .red)
    XCTAssertEqual(initialSnapshot.historyLength, 1)  // Initial position is history entry zero.
    let selectable = try await game.selectableSquares()
    XCTAssertTrue(selectable.contains(27))  // a3
    let destinations = try await game.legalDestinations(from: 27)
    XCTAssertEqual(destinations, [36])  // a3 -> a4

    try await game.apply(from: 27, to: 36)
    let mainlineAfterApply = try await game.ucciMainline()
    XCTAssertEqual(mainlineAfterApply, "a3a4")
    let snapshotAfterApply = try await game.snapshot()
    XCTAssertEqual(snapshotAfterApply.sideToMove, .black)
    try await game.undo()
    let fenAfterUndo = try await game.fen()
    XCTAssertEqual(fenAfterUndo, initialFEN)
    try await game.redo()

    let beforeRejectedMainline = try await game.fen()
    do {
      _ = try await game.applyUCCIMainline("b7b6 a0a9")
      XCTFail("expected a typed transactional mainline error")
    } catch let error as XiangqiCoreError {
      guard case .mainlineFailure(_, let ply) = error else {
        return XCTFail("expected a typed transactional mainline error, got \(error)")
      }
      XCTAssertEqual(ply, 2)
    }
    let fenAfterRejectedMainline = try await game.fen()
    XCTAssertEqual(fenAfterRejectedMainline, beforeRejectedMainline)

    let copied = try await game.clone()
    let copiedFEN = try await copied.fen()
    XCTAssertEqual(copiedFEN, beforeRejectedMainline)
    try await copied.close()
    do {
      _ = try await copied.snapshot()
      XCTFail("expected a closed handle error")
    } catch let error as XiangqiCoreError {
      XCTAssertEqual(error, .closed)
    }

    let terminalGame = try await XiangqiCoreGame.fromFEN(
      "3RkR3/9/4P4/9/9/9/9/9/9/4K4 b - - 0 1"
    )
    let terminalSnapshot = try await terminalGame.snapshot()
    XCTAssertEqual(terminalSnapshot.terminal, .checkmate(winner: .red))
    try await terminalGame.close()
    try await game.close()
  }

  func testGameWrapperRejectsOverLimitInputsBeforeCopying() async throws {
    let overLimit = String(repeating: "x", count: GeneratedFFIABI.maximumInputBytes + 1)
    do {
      _ = try await XiangqiCoreGame.fromFEN(overLimit)
      XCTFail("expected bounded FEN creation to fail")
    } catch let error as XiangqiCoreError {
      XCTAssertEqual(
        error,
        .fenFailure(status: GeneratedFFIABI.statusInputTooLarge, field: .inputBytes)
      )
    }

    let game = try await XiangqiCoreGame.createInitial()
    let before = try await game.fen()
    do {
      try await game.replace(fromFEN: overLimit)
      XCTFail("expected bounded FEN replacement to fail")
    } catch let error as XiangqiCoreError {
      XCTAssertEqual(
        error,
        .fenFailure(status: GeneratedFFIABI.statusInputTooLarge, field: .inputBytes)
      )
    }
    let fenAfterRejectedReplacement = try await game.fen()
    XCTAssertEqual(fenAfterRejectedReplacement, before)

    do {
      _ = try await game.applyUCCIMainline(overLimit)
      XCTFail("expected bounded UCCI import to fail")
    } catch let error as XiangqiCoreError {
      XCTAssertEqual(
        error,
        .mainlineFailure(status: GeneratedFFIABI.statusInputTooLarge, ply: nil)
      )
    }
    let fenAfterRejectedMainline = try await game.fen()
    XCTAssertEqual(fenAfterRejectedMainline, before)
    try await game.close()
  }

  func testDocumentSnapshotRoundTripsBranchesAnnotationsAndRedoSelection() async throws {
    let game = try await XiangqiCoreGame.createInitial()
    let initialFEN = try await game.fen()

    try await game.apply(from: 27, to: 36)  // a3a4, node 1
    try await game.apply(from: 54, to: 45)  // a6a5, node 2
    try await game.setAnnotation(node: 0, text: "根注释")
    try await game.setAnnotation(node: 1, text: "主分支")
    try await game.setAnnotation(node: 2, text: "黑方应手")
    try await game.undo()
    try await game.undo()
    try await game.apply(from: 29, to: 38)  // c3c4, node 3
    try await game.setAnnotation(node: 3, text: "替代分支")
    try await game.selectChild(parentNode: 0, childNode: 1)
    let expectedFEN = try await game.fen()

    let document = try await game.documentSnapshot()
    XCTAssertEqual(document.initialFEN, initialFEN)
    XCTAssertEqual(document.currentNodeID, 3)
    XCTAssertEqual(document.nodes.map(\.nodeID), [0, 1, 2, 3])
    XCTAssertEqual(document.nodes[0].childNodeIDs, [1, 3])
    XCTAssertEqual(document.nodes[0].selectedChildNodeID, 1)
    XCTAssertEqual(document.nodes[1].annotation, "主分支")
    XCTAssertEqual(document.nodes[3].annotation, "替代分支")

    let restored = try await XiangqiCoreGame.fromDocumentSnapshot(document)
    let restoredFEN = try await restored.fen()
    let restoredInitialSnapshot = try await restored.snapshot()
    XCTAssertEqual(restoredFEN, expectedFEN)
    XCTAssertEqual(restoredInitialSnapshot.currentNode, 3)
    try await restored.navigate(to: 0)
    try await restored.redo()
    let restoredFirstRedo = try await restored.snapshot()
    XCTAssertEqual(restoredFirstRedo.currentNode, 1)
    try await restored.redo()
    let restoredSecondRedo = try await restored.snapshot()
    let restoredAnnotation = try await restored.annotation(node: 2)
    XCTAssertEqual(restoredSecondRedo.currentNode, 2)
    XCTAssertEqual(restoredAnnotation, "黑方应手")
    try await restored.close()
    try await game.close()
  }

  func testPreparedDocumentOpenTransfersOneRustOwnerAndRejectsSecondConsumption() async throws {
    let source = try await XiangqiCoreGame.createInitial()
    try await source.apply(from: 19, to: 28)
    try await source.setAnnotation(node: 1, text: "prepared-open")
    let record = try await source.documentSnapshot()
    let expectedFEN = try await source.fen()

    let prepared = try XiangqiCoreGame.prepareDocumentSnapshotForOpen(record)
    let aliasedPrepared = prepared
    XCTAssertEqual(prepared.snapshot.currentNode, 1)
    let restored = try XiangqiCoreGame.consumePreparedDocument(prepared)
    let restoredFEN = try await restored.fen()
    let restoredAnnotation = try await restored.annotation(node: 1)
    XCTAssertEqual(restoredFEN, expectedFEN)
    XCTAssertEqual(restoredAnnotation, "prepared-open")
    XCTAssertThrowsError(try XiangqiCoreGame.consumePreparedDocument(aliasedPrepared)) { error in
      XCTAssertEqual(error as? XiangqiCoreError, .closed)
    }
    XiangqiCoreGame.discardPreparedDocument(aliasedPrepared)
    try await restored.close()
    try await source.close()
  }

  func testPreparedDocumentRestoreAcceptsTheExact4096NodeCoreBoundary() async throws {
    let initialFEN = "4k4/4a4/9/9/9/4P4/9/9/4A4/4K4 w - - 0 1"
    let cycle = [
      XiangqiCoreVariationMove(from: 13, to: 3),  // e1 → d0
      XiangqiCoreVariationMove(from: 76, to: 66),  // e8 → d7
      XiangqiCoreVariationMove(from: 3, to: 13),  // d0 → e1
      XiangqiCoreVariationMove(from: 66, to: 76),  // d7 → e8
    ]
    var nodes: [XiangqiCoreDocumentNode] = []
    nodes.reserveCapacity(XiangqiCoreDocumentSnapshot.maximumNodes)
    nodes.append(
      XiangqiCoreDocumentNode(
        nodeID: 0,
        parentNodeID: nil,
        move: nil,
        childNodeIDs: [1],
        selectedChildNodeID: 1,
        annotation: ""
      )
    )
    for rawNodeID in 1..<XiangqiCoreDocumentSnapshot.maximumNodes {
      let nodeID = UInt32(rawNodeID)
      let nextNodeID =
        rawNodeID + 1 < XiangqiCoreDocumentSnapshot.maximumNodes
        ? UInt32(rawNodeID + 1) : nil
      nodes.append(
        XiangqiCoreDocumentNode(
          nodeID: nodeID,
          parentNodeID: nodeID - 1,
          move: cycle[(rawNodeID - 1) % cycle.count],
          childNodeIDs: nextNodeID.map { [$0] } ?? [],
          selectedChildNodeID: nextNodeID,
          annotation: ""
        )
      )
    }
    let boundarySnapshot = XiangqiCoreDocumentSnapshot(
      initialFEN: initialFEN,
      profileID: 1,
      profileVersion: 1,
      currentNodeID: UInt32(XiangqiCoreDocumentSnapshot.maximumNodes - 1),
      nodes: nodes
    )

    let prepared = try XiangqiCoreGame.prepareDocumentSnapshotForOpen(boundarySnapshot)
    XCTAssertEqual(
      prepared.snapshot.currentNode, UInt32(XiangqiCoreDocumentSnapshot.maximumNodes - 1))
    let restored = try XiangqiCoreGame.consumePreparedDocument(prepared)
    let restoredSnapshot = try await restored.snapshot()
    XCTAssertEqual(
      restoredSnapshot.currentNode, UInt32(XiangqiCoreDocumentSnapshot.maximumNodes - 1))
    try await restored.close()
  }

  func testFENDiagnosticNamesRustFieldAndLeavesLiveGameUntouched() async throws {
    let game = try await XiangqiCoreGame.createInitial()
    let before = try await game.fen()
    let malformed = "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR x - - 0 1"

    do {
      try await game.replace(fromFEN: malformed)
      XCTFail("expected a field-specific FEN failure")
    } catch let error as XiangqiCoreError {
      XCTAssertEqual(
        error,
        .fenFailure(status: GeneratedFFIABI.statusParseError, field: .sideToMove)
      )
    }
    let afterRejectedReplacement = try await game.fen()
    XCTAssertEqual(afterRejectedReplacement, before)

    do {
      _ = try await XiangqiCoreGame.fromFEN(malformed)
      XCTFail("expected a field-specific FEN creation failure")
    } catch let error as XiangqiCoreError {
      XCTAssertEqual(
        error,
        .fenFailure(status: GeneratedFFIABI.statusParseError, field: .sideToMove)
      )
    }
    try await game.close()
  }

  func testWxfProfileAdjudicatesLongCheck() async throws {
    // Long-check fixture from the T070 corpus: red rook a9 shuttles b9/b8,
    // black general alternates e9/e8.
    let game = try await XiangqiCoreGame.fromFEN(
      "R3k4/9/9/9/4P4/9/9/9/9/4K4 w - - 0 1")
    // Switch to the WXF-style profile at the root (empty history only).
    try await game.setProfile(id: 2, version: 1)
    let summary = try await game.historySummary()
    XCTAssertTrue(summary.wxfResponsibilitySupported)
    XCTAssertEqual(summary.profileID, 2)
    // Replay the corpus long-check game via UCCI.
    _ = try await game.applyUCCIMainline(
      "a9b9 e9e8 b9b8 e8e9 b8b9 e9e8 b9b8 e8e9 b8b9")
    let adjudication = try await game.adjudication()
    XCTAssertEqual(adjudication.verdict, .mustChangeRed)
    XCTAssertEqual(adjudication.profileID, 2)
    XCTAssertNotNil(adjudication.cycle)
    XCTAssertEqual(adjudication.cycle?.repeatCount, 3)
    XCTAssertEqual(adjudication.labels.count, 4)
    XCTAssertTrue(adjudication.explanation.contains("红方长将"))
    XCTAssertFalse(adjudication.explanationTruncated)
    try await game.close()
  }

  func testProfileSwitchAfterMovesIsRejected() async throws {
    let game = try await XiangqiCoreGame.createInitial()
    _ = try await game.applyUCCIMainline("a3a4")
    do {
      try await game.setProfile(id: 2, version: 1)
      XCTFail("expected profile switch rejection")
    } catch let error as XiangqiCoreError {
      XCTAssertEqual(error, .ffiStatus(GeneratedFFIABI.statusInvalidArgument))
    }
    try await game.close()
  }
}
