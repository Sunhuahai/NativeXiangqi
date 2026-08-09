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
      XCTAssertEqual(error, .ffiStatus(GeneratedFFIABI.statusInputTooLarge))
    }

    let game = try await XiangqiCoreGame.createInitial()
    let before = try await game.fen()
    do {
      try await game.replace(fromFEN: overLimit)
      XCTFail("expected bounded FEN replacement to fail")
    } catch let error as XiangqiCoreError {
      XCTAssertEqual(error, .ffiStatus(GeneratedFFIABI.statusInputTooLarge))
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
}
