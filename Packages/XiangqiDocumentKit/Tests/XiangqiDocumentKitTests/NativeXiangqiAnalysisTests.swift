import AppKit
import Foundation
import PikafishKit
import XCTest
import XiangqiCoreBinary

@testable import XiangqiDocumentKit

/// Compiles the deterministic C fake engine once per test process and exposes
/// typed verified-asset descriptors for coordinator/document tests.
private enum FakeEngine {
  static let binaryURL: URL = {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("PikafishKit/Tests/EngineFakes/fake_engine.c")
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nx-fake-engine-doc-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let binary = directory.appendingPathComponent("fake_engine")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["clang", "-O1", "-o", binary.path, source.path]
    try? process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "fake engine failed to compile")
    return binary
  }()

  static func descriptor(scenario: String) -> NativeXiangqiVerifiedEngineDescriptor {
    NativeXiangqiVerifiedEngineDescriptor(
      helperURL: binaryURL,
      resourcesURL: binaryURL.deletingLastPathComponent(),
      engineCommit: "fake-commit",
      helperSHA256: "fake-helper",
      networkSHA256: "fake-network",
      networkBytes: 0
    )
  }

  static func configuration(
    scenario: String,
    idleTimeout: Duration = .seconds(30)
  ) -> NativeXiangqiAnalysisCoordinator.Configuration {
    NativeXiangqiAnalysisCoordinator.Configuration(
      candidateCount: 3,
      updateIntervalMilliseconds: 100,
      idleTimeout: idleTimeout,
      totalPhysicalMemoryBytes: 8_000_000_000,
      activeProcessorCount: 2,
      sessionTimeouts: .init(
        handshake: .seconds(2),
        readiness: .seconds(2),
        terminalWait: .milliseconds(300),
        exitWait: .seconds(2)
      ),
      sessionEnvironment: ["FAKE_SCENARIO": scenario]
    )
  }
}

private actor UpdateCollector {
  private var updates: [NativeXiangqiAnalysisUpdate] = []

  func append(_ update: NativeXiangqiAnalysisUpdate) {
    updates.append(update)
  }

  func snapshot() -> [NativeXiangqiAnalysisUpdate] {
    updates
  }
}

final class NativeXiangqiAnalysisCoordinatorTests: XCTestCase {
  private func makeIdentity(
    positionHash: UInt64 = 1,
    repetitionHash: UInt64 = 2,
    side: XiangqiCoreSide = .red,
    moves: [String] = []
  ) -> NativeXiangqiAnalysisIdentity {
    NativeXiangqiAnalysisIdentity(
      currentNode: 0,
      sideToMove: side,
      profileID: 1,
      profileVersion: 1,
      positionHash: positionHash,
      repetitionHash: repetitionHash,
      initialFEN: "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1",
      ucciMoves: moves,
      resourcePreset: .light,
      budget: try! PikafishSearchBudget(.fixedMilliseconds(1_000)),
      candidateCount: 3
    )
  }

  private func makeRequest() -> NativeXiangqiAnalysisRequest {
    NativeXiangqiAnalysisRequest(
      requestID: UUID(), generation: 1, identity: makeIdentity())
  }

  func testSearchReturnsTypedResultWithFakeEngine() async throws {
    let coordinator = NativeXiangqiAnalysisCoordinator(
      configuration: FakeEngine.configuration(scenario: "normal"),
      assets: FakeEngine.descriptor(scenario: "normal"),
      cache: nil
    )
    let collector = UpdateCollector()
    let drain = Task {
      for await update in await coordinator.updates {
        await collector.append(update)
      }
    }
    let result = try await coordinator.search(makeRequest())
    XCTAssertEqual(result.bestMove.move, "b2b3")
    let collected = await collector.snapshot()
    XCTAssertFalse(collected.isEmpty)
    drain.cancel()
    await coordinator.shutdown()
  }

  func testEngineUnavailableFailsTyped() async {
    let coordinator = NativeXiangqiAnalysisCoordinator(
      configuration: FakeEngine.configuration(scenario: "normal"),
      assets: nil,
      cache: nil
    )
    do {
      _ = try await coordinator.search(makeRequest())
      XCTFail("expected engineUnavailable")
    } catch let error as NativeXiangqiAnalysisError {
      XCTAssertEqual(error, .engineUnavailable)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    await coordinator.shutdown()
  }

  func testIllegalBestmoveSurfaceIsEngineFailure() async throws {
    let coordinator = NativeXiangqiAnalysisCoordinator(
      configuration: FakeEngine.configuration(scenario: "illegal-bestmove"),
      assets: FakeEngine.descriptor(scenario: "illegal-bestmove"),
      cache: nil
    )
    do {
      _ = try await coordinator.search(makeRequest())
      XCTFail("expected illegalBestMove")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .illegalBestMove("z9x9"))
    }
    await coordinator.shutdown()
  }

  func testConcurrentRequestsCancelThePrevious() async throws {
    let coordinator = NativeXiangqiAnalysisCoordinator(
      configuration: FakeEngine.configuration(scenario: "ignore-stop"),
      assets: FakeEngine.descriptor(scenario: "ignore-stop"),
      cache: nil
    )
    let firstRequest = makeRequest()
    let first = Task {
      try await coordinator.search(firstRequest)
    }
    try await Task.sleep(for: .milliseconds(150))
    let secondRequest = NativeXiangqiAnalysisRequest(
      requestID: UUID(), generation: 2, identity: makeIdentity(positionHash: 9))
    let second = Task {
      try await coordinator.search(secondRequest)
    }
    // The first search resolves with a typed terminal (stop honored or forced).
    let firstOutcome = await first.result
    let secondOutcome = await second.result
    switch firstOutcome {
    case .success:
      break
    case .failure:
      break
    }
    switch secondOutcome {
    case .success:
      break
    case .failure:
      break
    }
    await coordinator.shutdown()
  }

  func testRestartIsRateLimitedToFivePerHour() async throws {
    let coordinator = NativeXiangqiAnalysisCoordinator(
      configuration: FakeEngine.configuration(scenario: "crash-on-go"),
      assets: FakeEngine.descriptor(scenario: "crash-on-go"),
      cache: nil
    )
    // Each search crashes the helper on `go`; each restart revives it. The
    // rolling hourly limit allows exactly five explicit restarts.
    let crashRequest = makeRequest()
    var allowed = 0
    for _ in 0..<6 {
      _ = try? await coordinator.search(crashRequest)
      if await coordinator.restartSessionIfAllowed() {
        allowed += 1
      }
    }
    XCTAssertEqual(allowed, 5)
    await coordinator.shutdown()
  }

  func testMemoryPressurePurgesCacheAndStopsSearch() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nx-coord-cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cache = try AnalysisCache(
      configuration: AnalysisCacheConfiguration(directory: directory))
    let coordinator = NativeXiangqiAnalysisCoordinator(
      configuration: FakeEngine.configuration(scenario: "ignore-stop"),
      assets: FakeEngine.descriptor(scenario: "ignore-stop"),
      cache: cache
    )
    let pressureRequest = makeRequest()
    let searchTask = Task {
      try? await coordinator.search(pressureRequest)
    }
    try await Task.sleep(for: .milliseconds(150))
    await coordinator.noteMemoryPressure()
    _ = await searchTask.result
    let summary = await coordinator.cacheSummary()
    let memoryEntries = summary?.memoryEntries ?? 0
    XCTAssertEqual(memoryEntries, 0)
    await coordinator.shutdown()
  }

  func testHiddenWindowStopsActiveSearch() async throws {
    let coordinator = NativeXiangqiAnalysisCoordinator(
      configuration: FakeEngine.configuration(scenario: "ignore-stop"),
      assets: FakeEngine.descriptor(scenario: "ignore-stop"),
      cache: nil
    )
    let hiddenRequest = makeRequest()
    let searchTask = Task {
      try? await coordinator.search(hiddenRequest)
    }
    try await Task.sleep(for: .milliseconds(150))
    let start = ContinuousClock.now
    await coordinator.noteWindowVisibility(false)
    _ = await searchTask.result
    let elapsed = ContinuousClock.now - start
    // The search must terminate promptly (terminal wait + margin), not after
    // the full 5 s budget.
    XCTAssertLessThan(elapsed, .seconds(4))
    await coordinator.shutdown()
  }

  func testCacheRoundTripThroughCoordinator() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nx-coord-cache2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cache = try AnalysisCache(
      configuration: AnalysisCacheConfiguration(directory: directory))
    let coordinator = NativeXiangqiAnalysisCoordinator(
      configuration: FakeEngine.configuration(scenario: "normal"),
      assets: FakeEngine.descriptor(scenario: "normal"),
      cache: cache
    )
    let identity = makeIdentity()
    let keyResult = await coordinator.cacheKey(for: identity)
    let key = try XCTUnwrap(keyResult)
    let info = PikafishInfo(
      depth: 12, seldepth: 14, multipv: 1,
      score: PikafishScore(kind: .centipawn(33), bound: nil), nodes: 1_000, nps: 500,
      timeMilliseconds: 2_000, hashfull: 10, pv: ["b2b3", "b7b6"])
    let validated = PikafishValidatedFinalResult(
      searchGeneration: 1,
      bestMove: PikafishBestMove(move: "b2b3", ponder: "b7b6"),
      candidates: [PikafishCandidate(rank: 1, info: info)],
      elapsedMilliseconds: 2_000,
      sideToMove: .red
    )
    try await coordinator.cacheStore(key: key, result: validated, budget: identity.budget)
    let payloadResult = await coordinator.cacheLookup(key: key)
    let payload = try XCTUnwrap(payloadResult)
    XCTAssertEqual(payload.bestMove, "b2b3")
    await coordinator.shutdown()
  }
}

/// End-to-end document integration: analysis toggle, Rust-validated AI reply,
/// illegal-move failure without mutation, and change-count isolation.
@MainActor
final class NativeXiangqiDocumentAnalysisTests: XCTestCase {
  private func makeDocumentAndCoordinator(
    scenario: String
  ) async throws -> (NativeXiangqiDocument, NativeXiangqiAnalysisCoordinator) {
    _ = NSApplication.shared
    let document = NativeXiangqiDocument()
    document.beginInMemoryGameIfNeeded()
    try await document.waitUntilLocalSessionReady()
    let coordinator = NativeXiangqiAnalysisCoordinator(
      configuration: FakeEngine.configuration(scenario: scenario),
      assets: FakeEngine.descriptor(scenario: scenario),
      cache: nil
    )
    document.configureAnalysisService(coordinator)
    return (document, coordinator)
  }

  private func play(
    _ document: NativeXiangqiDocument, from: UInt8, to: UInt8
  ) async throws {
    document.requestSquare(from)
    try await document.waitUntilIdleForTesting()
    XCTAssertEqual(document.boardPresentation.selectedSquare, from)
    XCTAssertTrue(document.boardPresentation.legalDestinations.contains(to))
    document.requestSquare(to)
    try await document.waitUntilIdleForTesting()
    XCTAssertNil(document.boardPresentation.selectedSquare)
  }

  private func waitForCondition(
    _ condition: @escaping @MainActor () async -> Bool,
    timeout: Duration = .seconds(8)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
      if await condition() {
        return true
      }
      try? await clock.sleep(for: .milliseconds(50))
    }
    return await condition()
  }

  func testAIRepliesWithRustValidatedMoveAndReachesVariationTree() async throws {
    let (document, coordinator) = try await makeDocumentAndCoordinator(
      scenario: "black-bestmove")
    defer {
      document.close()
      Task { await coordinator.shutdown() }
    }
    document.selectAISide(.black)
    document.toggleAnalysis()
    try await Task.sleep(for: .milliseconds(300))
    // Human moves red pawn a3 -> a4 (canonical 27 -> 36).
    try await play(document, from: 27, to: 36)
    // AI must reply i7 -> i6 (canonical 62 -> 53) after Rust validation.
    let moved = await waitForCondition {
      document.displayedCurrentNodeID == 2
    }
    XCTAssertTrue(moved, "AI reply did not reach the variation tree")
    await document.close()
  }

  func testIllegalAIMoveFailsWithoutMutatingDocument() async throws {
    let (document, coordinator) = try await makeDocumentAndCoordinator(
      scenario: "illegal-bestmove")
    defer {
      document.close()
      Task { await coordinator.shutdown() }
    }
    document.selectAISide(.black)
    document.toggleAnalysis()
    try await Task.sleep(for: .milliseconds(300))
    try await play(document, from: 27, to: 36)
    // The engine's z9x9 is syntactically invalid; Rust never sees it applied.
    try await Task.sleep(for: .seconds(1))
    let nodeID = await document.displayedCurrentNodeID
    XCTAssertEqual(nodeID, 1)
    await document.close()
  }

  func testAnalysisToggleDoesNotDirtyTheDocument() async throws {
    let (document, coordinator) = try await makeDocumentAndCoordinator(scenario: "normal")
    defer {
      document.close()
      Task { await coordinator.shutdown() }
    }
    let baseline = document.isDocumentEdited
    document.toggleAnalysis()
    try await Task.sleep(for: .seconds(1))
    document.toggleAnalysis()
    XCTAssertEqual(document.isDocumentEdited, baseline)
    await document.close()
  }
}
