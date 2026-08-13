import Foundation
import XCTest

@testable import PikafishKit

/// Actor-isolated collector for typed search updates consumed off the session
/// actor during a concurrent search.
private actor UpdateCollector {
  private var updates: [PikafishSearchUpdate] = []

  func append(_ update: PikafishSearchUpdate) {
    updates.append(update)
  }

  func snapshot() -> [PikafishSearchUpdate] {
    updates
  }
}

/// Compiles the deterministic C fake engine once per test process.
private enum FakeEngine {
  static let binaryURL: URL = {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("EngineFakes/fake_engine.c")
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nx-fake-engine-\(getpid())", isDirectory: true)
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
}

final class PikafishSessionTests: XCTestCase {
  private let initialFEN =
    "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"

  private func makeSession(
    scenario: String,
    handshakeTimeout: Duration = .milliseconds(2_000),
    readinessTimeout: Duration = .milliseconds(2_000),
    terminalWait: Duration = .milliseconds(400),
    maximumRestartAttempts: Int = 2
  ) async throws -> (PikafishSession, URL) {
    let logURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nx-fake-log-\(UUID().uuidString)")
    let configuration = PikafishConfiguration(
      executableURL: FakeEngine.binaryURL,
      environment: ["FAKE_LOG_PATH": logURL.path, "FAKE_SCENARIO": scenario],
      handshakeTimeout: handshakeTimeout,
      readinessTimeout: readinessTimeout,
      terminalWait: terminalWait,
      exitWait: .milliseconds(2_000),
      maximumRestartAttempts: maximumRestartAttempts
    )
    let session = PikafishSession(configuration: configuration)
    try await session.start()
    return (session, logURL)
  }

  private func readLog(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }

  /// Reads the fake's stdin log, polling until it contains `needle` or the
  /// bounded deadline passes. The fake logs asynchronously relative to the
  /// test process, so direct reads can race with the child process.
  private func waitForLog(_ url: URL, containing needle: String, timeout: Duration = .seconds(2))
    async -> Bool
  {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
      if readLog(url).contains(needle) {
        return true
      }
      try? await clock.sleep(for: .milliseconds(10))
    }
    return readLog(url).contains(needle)
  }

  private func waitForPhase(
    _ expected: PikafishSession.Phase,
    session: PikafishSession,
    timeout: Duration = .seconds(2)
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
      if await session.summary().phase == expected {
        return
      }
      try await clock.sleep(for: .milliseconds(10))
    }
    XCTFail("session did not reach phase \(expected)")
  }

  // MARK: - Handshake

  func testHandshakeDiscoversIdentityAndOptions() async throws {
    let (session, _) = try await makeSession(scenario: "normal")
    let summary = await session.summary()
    XCTAssertEqual(summary.phase, .ready)
    XCTAssertEqual(summary.idName, "FakeEngine normal")
    XCTAssertEqual(summary.optionCount, 6)
    let options = await session.discoveredOptions
    let hash = try XCTUnwrap(options.first { $0.name == "Hash" })
    XCTAssertEqual(hash.kind, .spin)
    XCTAssertEqual(hash.min, 1)
    XCTAssertEqual(hash.max, 33_554_432)
    await session.shutdown()
  }

  func testOptionVariantsAreToleratedAndHandshakeSucceeds() async throws {
    let (session, _) = try await makeSession(scenario: "option-variants")
    let summary = await session.summary()
    XCTAssertEqual(summary.phase, .ready)
    // The malformed spin (no min/max) is rejected; valid variants survive.
    let options = await session.discoveredOptions
    let style = try XCTUnwrap(options.first { $0.name == "Style" })
    XCTAssertEqual(style.kind, .combo)
    XCTAssertEqual(style.variables, ["Normal", "Aggressive"])
    let clearHash = try XCTUnwrap(options.first { $0.name == "Clear Hash" })
    XCTAssertEqual(clearHash.kind, .button)
    XCTAssertNil(options.first { $0.name == "MalformedSpin" })
    let spaced = try XCTUnwrap(options.first { $0.name == "Spaces In Name" })
    XCTAssertEqual(spaced.kind, .string)
    XCTAssertEqual(spaced.defaultValue, "hello")
    await session.shutdown()
  }

  // MARK: - Presets

  func testPresetAppliesOnlyAdvertisedOptions() async throws {
    let (session, logURL) = try await makeSession(scenario: "normal")
    try await session.applyPreset(PikafishPresets.light)
    let loggedHash = await waitForLog(logURL, containing: "setoption name Hash value 16")
    XCTAssertTrue(loggedHash)
    let log = readLog(logURL)
    XCTAssertTrue(log.contains("setoption name Threads value 1"))
    XCTAssertTrue(log.contains("setoption name Ponder value false"))

    let deep = PikafishPreset(
      name: "deep-custom",
      options: [("Hash", "128"), ("Threads", "4"), ("Ponder", "false")]
    )
    try await session.applyPreset(deep)

    let bogus = PikafishPreset(
      name: "bogus",
      options: [("Hash", "16"), ("NotAdvertised", "1")]
    )
    do {
      try await session.applyPreset(bogus)
      XCTFail("expected optionNotAdvertised")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .optionNotAdvertised("NotAdvertised"))
    }
    // The failed preset must not have sent a partial setoption sequence.
    let logAfterFailure = readLog(logURL)
    XCTAssertFalse(logAfterFailure.contains("NotAdvertised"))
    // light (Hash 16) + deep (Hash 128) = 6 setoption lines total.
    XCTAssertEqual(
      logAfterFailure.components(separatedBy: "setoption").count - 1, 6)
    XCTAssertEqual(
      logAfterFailure.components(separatedBy: "setoption name Hash value 16").count - 1, 1)
    XCTAssertTrue(logAfterFailure.contains("setoption name Hash value 128"))
    await session.shutdown()
  }

  func testPresetStringValueRejectsCommandSeparators() async throws {
    let (session, logURL) = try await makeSession(scenario: "normal")
    let injected = PikafishPreset(
      name: "injected",
      options: [("EvalFile", "pikafish.nnue\nquit")]
    )
    do {
      try await session.applyPreset(injected)
      XCTFail("expected malformed option value")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .malformedOptionValue("EvalFile"))
    }
    XCTAssertFalse(readLog(logURL).contains("setoption name EvalFile"))
    await session.shutdown()
  }

  func testPresetValueOutOfRangeFailsClosed() async throws {
    let (session, _) = try await makeSession(scenario: "normal")
    let oversized = PikafishPreset(
      name: "oversized",
      options: [("Threads", "9999")]
    )
    do {
      try await session.applyPreset(oversized)
      XCTFail("expected optionValueOutOfRange")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(
        error,
        .optionValueOutOfRange(name: "Threads", value: 9_999, min: 1, max: 1_024))
    }
    await session.shutdown()
  }

  func testPresetOnMissingOptionFailsClosed() async throws {
    let (session, _) = try await makeSession(scenario: "option-not-advertised")
    do {
      try await session.applyPreset(PikafishPresets.light)
      XCTFail("expected optionNotAdvertised")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .optionNotAdvertised("Hash"))
    }
    await session.shutdown()
  }

  // MARK: - Timeouts

  func testSlowHandshakeTimesOutWithTypedFailure() async throws {
    do {
      _ = try await makeSession(scenario: "slow-handshake", handshakeTimeout: .milliseconds(250))
      XCTFail("expected handshakeTimeout")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .handshakeTimeout)
    }
  }

  func testSlowIsreadyTimesOutWithTypedFailure() async throws {
    do {
      _ = try await makeSession(scenario: "slow-isready", readinessTimeout: .milliseconds(250))
      XCTFail("expected readinessTimeout")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .readinessTimeout)
    }
  }

  // MARK: - Search

  func testSearchReturnsTypedResult() async throws {
    let (session, _) = try await makeSession(scenario: "normal")
    try await session.newGame()
    try await session.position(
      fen: "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1")
    let result = try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(2_000)))
    XCTAssertEqual(result.bestMove.move, "b2b3")
    XCTAssertEqual(result.bestMove.ponder, "b7b6")
    let info = try XCTUnwrap(result.finalInfo)
    XCTAssertEqual(info.depth, 3)
    XCTAssertEqual(info.nodes, 3_000)
    XCTAssertEqual(info.score, PikafishScore(kind: .centipawn(33), bound: nil))
    XCTAssertEqual(info.pv, ["b2b3", "b7b6", "b3b4"])
    XCTAssertEqual(info.seldepth, 4)
    await session.shutdown()
  }

  func testImmediateBestmoveCannotBeatSearchContinuationInstallation() async throws {
    let (session, _) = try await makeSession(scenario: "immediate-bestmove")
    try await session.position(fen: initialFEN)
    let result = try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(2_000)))
    XCTAssertEqual(result.bestMove.move, "b2b3")
    let phase = await session.summary().phase
    XCTAssertEqual(phase, .ready)
    await session.shutdown()
  }

  func testLatestInfoRemainsCurrentAfterLineAccountingLimit() async throws {
    let (session, _) = try await makeSession(scenario: "many-info-lines")
    try await session.position(fen: initialFEN)
    let result = try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(2_000)))
    XCTAssertEqual(result.finalInfo?.depth, 4_105)
    XCTAssertEqual(result.finalInfo?.nodes, 4_105)
    await session.shutdown()
  }

  func testMultiPVLinesAreAggregatedByRankAndDeliveredAsUpdates() async throws {
    let collector = UpdateCollector()
    let (session, _) = try await makeSession(scenario: "multipv-interleave")
    try await session.position(fen: initialFEN)
    let drain = Task {
      for await update in await session.searchUpdates {
        await collector.append(update)
      }
    }
    let result = try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(2_000)))
    XCTAssertEqual(result.candidates.count, 3)
    XCTAssertEqual(result.candidates.map(\.rank), [1, 2, 3])
    XCTAssertEqual(result.candidates[0].info.depth, 6)
    XCTAssertEqual(result.candidates[0].info.pv, ["b2b3", "b7b6"])
    XCTAssertEqual(result.candidates[2].info.pv, ["h2h3", "h7h6"])
    XCTAssertEqual(result.finalInfo?.depth, 6)
    let collected = await collector.snapshot()
    let fullRankUpdate = try XCTUnwrap(collected.first { $0.candidates.count == 3 })
    XCTAssertGreaterThanOrEqual(fullRankUpdate.coalescedInfoLines, 1)
    XCTAssertEqual(fullRankUpdate.candidates.map(\.rank), [1, 2, 3])
    drain.cancel()
    await session.shutdown()
  }

  func testConfigureCandidatesClampsToBoundedRange() async throws {
    let (session, logURL) = try await makeSession(scenario: "normal")
    let applied = try await session.configureCandidates(desired: 3)
    XCTAssertEqual(applied, 3)
    let count = await session.resolvedCandidateCount
    XCTAssertEqual(count, 3)
    // Clamped to the kit-wide candidate cap even though the engine advertises 128.
    let clamped = try await session.configureCandidates(desired: 99)
    XCTAssertEqual(clamped, 3)
    let logged = await waitForLog(logURL, containing: "setoption name MultiPV value 3")
    XCTAssertTrue(logged)
    await session.shutdown()
  }

  func testConfigureCandidatesDegradesToOneWhenMultiPVIsMissing() async throws {
    let (session, logURL) = try await makeSession(scenario: "no-multipv")
    let applied = try await session.configureCandidates(desired: 3)
    XCTAssertEqual(applied, 1)
    let count = await session.resolvedCandidateCount
    XCTAssertEqual(count, 1)
    XCTAssertFalse(readLog(logURL).contains("MultiPV"))
    await session.shutdown()
  }

  func testTypedResourcePresetAppliesFixedValues() async throws {
    let (session, logURL) = try await makeSession(scenario: "normal")
    try await session.applyPreset(
      .light, totalPhysicalMemoryBytes: 8_000_000_000, activeProcessorCount: 2)
    let log = readLog(logURL)
    let loggedHash16 = await waitForLog(logURL, containing: "setoption name Hash value 16")
    XCTAssertTrue(loggedHash16)
    XCTAssertTrue(log.contains("setoption name Threads value 1"))
    XCTAssertTrue(log.contains("setoption name Ponder value false"))
    try await session.applyPreset(
      .standard, totalPhysicalMemoryBytes: 24_000_000_000, activeProcessorCount: 8)
    let loggedHash64 = await waitForLog(logURL, containing: "setoption name Hash value 64")
    XCTAssertTrue(loggedHash64)
    let standardLog = readLog(logURL)
    XCTAssertTrue(standardLog.contains("setoption name Threads value 2"))
    await session.shutdown()
  }

  func testPositionIsRejectedWhileSearchIsActive() async throws {
    let (session, _) = try await makeSession(scenario: "ignore-stop")
    try await session.position(fen: initialFEN)
    let searchTask = Task {
      try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(5_000)))
    }
    try await waitForPhase(.searching, session: session)
    do {
      try await session.position(fen: initialFEN)
      XCTFail("expected invalidState")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .invalidState(expected: "ready", actual: "searching"))
    }
    searchTask.cancel()
    _ = try? await searchTask.value
    await session.shutdown()
  }

  func testMalformedOutputIsTolerated() async throws {
    let (session, _) = try await makeSession(scenario: "malformed")
    try await session.position(
      fen: "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1")
    let result = try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(2_000)))
    XCTAssertEqual(result.bestMove.move, "b2b3")
    // The valid line after the malformed ones becomes the final info.
    XCTAssertEqual(result.finalInfo?.depth, 3)
    XCTAssertEqual(result.finalInfo?.score, PikafishScore(kind: .centipawn(38), bound: nil))
    XCTAssertEqual(result.finalInfo?.pv, ["b2b3", "b7b6"])
    await session.shutdown()
  }

  func testFloodAndStderrFloodRemainBounded() async throws {
    let (session, _) = try await makeSession(scenario: "flood")
    try await session.position(
      fen: "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1")
    let result = try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(2_000)))
    XCTAssertEqual(result.bestMove.move, "b2b3")
    let diagnostics = await session.outputReaderDiagnostics()
    // The flood stays bounded: bytes are accounted, capped, and the search
    // still completes with a typed bestmove. Diagnostics are not guaranteed
    // because the drain consumes lines as fast as the fake writes them.
    XCTAssertGreaterThan(diagnostics.stdout.totalLineBytes, 0)
    XCTAssertLessThanOrEqual(diagnostics.stdout.totalLineBytes, 2_000_000)
    let summary = await session.summary()
    XCTAssertEqual(summary.phase, .ready)
    await session.shutdown()

    let (stderrSession, _) = try await makeSession(scenario: "stderr-flood")
    try await stderrSession.position(
      fen: "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1")
    let stderrResult = try await stderrSession.search(
      limit: PikafishSearchLimit(.timeMilliseconds(2_000)))
    XCTAssertEqual(stderrResult.bestMove.move, "b2b3")
    let stderrDiagnostics = await stderrSession.outputReaderDiagnostics()
    XCTAssertGreaterThan(stderrDiagnostics.stderr.totalLineBytes, 0)
    await stderrSession.shutdown()
  }

  func testNoBestmoveFailsAtDeadline() async throws {
    let (session, _) = try await makeSession(scenario: "no-bestmove")
    try await session.position(
      fen: "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1")
    do {
      _ = try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(100)))
      XCTFail("expected searchDeadlineExceeded")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .searchDeadlineExceeded(generation: 1))
    }
    let summary = await session.summary()
    XCTAssertEqual(summary.phase, .failed)
    await session.shutdown()
  }

  func testStopSearchCancelsAndReapsTerminal() async throws {
    let (session, _) = try await makeSession(scenario: "normal")
    try await session.position(
      fen: "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1")
    let searchTask = Task {
      try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(5_000)))
    }
    try await Task.sleep(for: .milliseconds(200))
    await session.stopSearch()
    let result = try await searchTask.value
    // The fake honors stop with an immediate bestmove.
    XCTAssertEqual(result.bestMove.move, "b2b3")
    await session.shutdown()
  }

  func testSearchCancellationViaTaskCancellation() async throws {
    let (session, _) = try await makeSession(scenario: "ignore-stop")
    try await session.position(
      fen: "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1")
    let searchTask = Task {
      try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(5_000)))
    }
    try await Task.sleep(for: .milliseconds(200))
    searchTask.cancel()
    do {
      _ = try await searchTask.value
      XCTFail("expected searchCancelled")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .searchCancelled(generation: 1))
    }
    await session.shutdown()
  }

  func testIgnoreStopForcesTerminationWithTypedFailure() async throws {
    let (session, _) = try await makeSession(
      scenario: "ignore-stop", terminalWait: .milliseconds(300))
    try await session.position(
      fen: "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1")
    do {
      _ = try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(100)))
      XCTFail("expected a typed search failure")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .searchDeadlineExceeded(generation: 1))
    }
    await session.shutdown()
  }

  func testIllegalBestmoveIsTypedFailure() async throws {
    let (session, _) = try await makeSession(scenario: "illegal-bestmove")
    try await session.position(
      fen: "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1")
    do {
      _ = try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(2_000)))
      XCTFail("expected illegalBestMove")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .illegalBestMove("z9x9"))
    }
    await session.shutdown()
  }

  func testCrashDuringSearchIsTypedFailureAndRestartWorks() async throws {
    let (session, _) = try await makeSession(scenario: "crash-on-go")
    try await session.position(
      fen: "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1")
    do {
      _ = try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(2_000)))
      XCTFail("expected engineCrashed")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .engineCrashed(terminationStatus: 7))
    }
    // The crash only happens on `go`; a restart hands back a healthy session.
    try await session.restart()
    let summary = await session.summary()
    XCTAssertEqual(summary.phase, .ready)
    XCTAssertEqual(summary.launchCount, 2)
    await session.shutdown()
  }

  func testCrashWhileReadyTransitionsToFailedPromptly() async throws {
    let (session, _) = try await makeSession(scenario: "crash-while-ready")
    try await waitForPhase(.failed, session: session)
    let phase = await session.summary().phase
    XCTAssertEqual(phase, .failed)
    do {
      try await session.position(fen: initialFEN)
      XCTFail("expected invalidState")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .invalidState(expected: "ready", actual: "failed"))
    }
    await session.shutdown()
  }

  func testRestartAttemptsExhaustAfterRepeatedLaunchFailures() async throws {
    let configuration = PikafishConfiguration(
      executableURL: FakeEngine.binaryURL,
      environment: ["FAKE_SCENARIO": "crash-early"],
      maximumRestartAttempts: 2
    )
    let session = PikafishSession(configuration: configuration)
    // The fake exits before any handshake output, so start() fails.
    do {
      try await session.start()
      XCTFail("expected a launch failure")
    } catch {
      // Expected: the crash is observed as a typed handshake failure.
    }
    do {
      try await session.restart()
      XCTFail("expected restartAttemptsExhausted")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .restartAttemptsExhausted)
    }
  }

  // MARK: - Shutdown and validation

  func testGracefulShutdownClosesSession() async throws {
    let (session, logURL) = try await makeSession(scenario: "normal")
    await session.shutdown()
    let summary = await session.summary()
    XCTAssertEqual(summary.phase, .closed)
    let log = readLog(logURL)
    XCTAssertTrue(log.contains("quit"))
    // Shutdown again is a no-op.
    await session.shutdown()
    let finalPhase = await session.summary().phase
    XCTAssertEqual(finalPhase, .closed)
  }

  func testShutdownDuringSearchResolvesPendingSearch() async throws {
    let (session, _) = try await makeSession(scenario: "ignore-stop")
    try await session.position(fen: initialFEN)
    let searchTask = Task {
      try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(5_000)))
    }
    try await waitForPhase(.searching, session: session)
    await session.shutdown()
    do {
      _ = try await searchTask.value
      XCTFail("expected searchCancelled")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .searchCancelled(generation: 1))
    }
    let phase = await session.summary().phase
    XCTAssertEqual(phase, .closed)
  }

  func testSearchBeforeStartIsTypedFailure() async {
    let session = PikafishSession(
      configuration: PikafishConfiguration(executableURL: FakeEngine.binaryURL))
    do {
      _ = try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(10)))
      XCTFail("expected invalidState")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .invalidState(expected: "ready", actual: "idle"))
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testPositionValidationIsBounded() async throws {
    let (session, _) = try await makeSession(scenario: "normal")
    do {
      try await session.position(
        fen: String(repeating: "x", count: PikafishLimits.maximumFENBytes + 1))
      XCTFail("expected inputTooLong")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .inputTooLong("fen"))
    }
    do {
      try await session.position(
        fen: "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1",
        moves: ["z9x9"])
      XCTFail("expected malformedPosition")
    } catch let error as PikafishSessionError {
      XCTAssertEqual(error, .malformedPosition)
    }
    try await session.position(
      fen: "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1",
      moves: ["b2b3", "b7b6"])
    await session.shutdown()
  }

  // MARK: - Real helper (gated on the verified artifacts)

  func testRealHelperHandshakeAndSearch() async throws {
    let artifacts = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Engines/Pikafish/artifacts")
    let helper = artifacts.appendingPathComponent("pikafish-2026-01-02-apple-silicon")
    let network = artifacts.appendingPathComponent("pikafish.nnue")
    guard FileManager.default.fileExists(atPath: helper.path),
      FileManager.default.fileExists(atPath: network.path)
    else {
      throw XCTSkip("real helper artifacts not present; run make vendor-verify first")
    }
    let session = PikafishSession(
      configuration: PikafishConfiguration(
        executableURL: helper,
        handshakeTimeout: .seconds(15),
        readinessTimeout: .seconds(15),
        terminalWait: .seconds(3),
        exitWait: .seconds(5)
      )
    )
    try await session.start()
    let summary = await session.summary()
    XCTAssertEqual(summary.idName, "Pikafish 2026-01-02")
    try await session.applyPreset(PikafishPresets.light)
    try await session.newGame()
    try await session.position(
      fen: "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1")
    let result = try await session.search(limit: PikafishSearchLimit(.timeMilliseconds(400)))
    XCTAssertNotNil(result.bestMove.move)
    XCTAssertTrue(PikafishUCI.isValidMoveToken(result.bestMove.move ?? ""))
    await session.shutdown()
  }
}

// MARK: - Parser unit tests

final class PikafishParserTests: XCTestCase {
  func testMoveTokenValidation() {
    XCTAssertTrue(PikafishUCI.isValidMoveToken("b2b3"))
    XCTAssertTrue(PikafishUCI.isValidMoveToken("a0a9"))
    XCTAssertFalse(PikafishUCI.isValidMoveToken("z9x9"))
    XCTAssertFalse(PikafishUCI.isValidMoveToken("b2b2"))
    XCTAssertFalse(PikafishUCI.isValidMoveToken("b23"))
    XCTAssertFalse(PikafishUCI.isValidMoveToken("b2b"))
    XCTAssertFalse(PikafishUCI.isValidMoveToken(""))
    XCTAssertFalse(PikafishUCI.isValidMoveToken("B2B3"))
  }

  func testInfoParsingValidatesNumbers() {
    let tokens =
      "info depth 12 seldepth 14 multipv 1 score cp 45 nodes 12345 nps 6789 time 321 hashfull 78 pv b2b3 b7b6"
      .split(separator: " ")
    let info = PikafishUCI.parseInfo(tokens)
    XCTAssertEqual(info?.depth, 12)
    XCTAssertEqual(info?.seldepth, 14)
    XCTAssertEqual(info?.score, PikafishScore(kind: .centipawn(45), bound: nil))
    XCTAssertEqual(info?.nodes, 12_345)
    XCTAssertEqual(info?.hashfull, 78)
    XCTAssertEqual(info?.pv, ["b2b3", "b7b6"])

    let mate = PikafishUCI.parseInfo("info depth 30 score mate -3 pv b2b3".split(separator: " "))
    XCTAssertEqual(mate?.score, PikafishScore(kind: .mate(-3), bound: nil))

    let bound = PikafishUCI.parseInfo("info depth 5 score cp 10 lowerbound".split(separator: " "))
    XCTAssertEqual(bound?.score, PikafishScore(kind: .centipawn(10), bound: .lowerbound))

    // Malformed numbers are dropped, not fatal.
    let malformed = PikafishUCI.parseInfo(
      "info depth notanumber score cp 99999999999999999999 nodes 5 pv b2b3 z9x9 b7b6".split(
        separator: " "))
    XCTAssertNil(malformed?.depth)
    XCTAssertNil(malformed?.score)
    XCTAssertEqual(malformed?.nodes, 5)
    XCTAssertEqual(malformed?.pv, ["b2b3"])
  }

  func testBestMoveParsing() throws {
    let valid = try PikafishUCI.parseBestMove("bestmove b2b3 ponder b7b6".split(separator: " "))
    XCTAssertEqual(valid?.move, "b2b3")
    XCTAssertEqual(valid?.ponder, "b7b6")

    let none = try PikafishUCI.parseBestMove("bestmove (none)".split(separator: " "))
    XCTAssertNil(none?.move)

    XCTAssertThrowsError(try PikafishUCI.parseBestMove("bestmove z9x9".split(separator: " "))) {
      error in
      XCTAssertEqual(error as? PikafishSessionError, .illegalBestMove("z9x9"))
    }
    XCTAssertThrowsError(try PikafishUCI.parseBestMove("bestmove".split(separator: " "))) {
      error in
      XCTAssertEqual(error as? PikafishSessionError, .malformedBestMove)
    }
    XCTAssertNil(try PikafishUCI.parseBestMove("info depth 1".split(separator: " ")))
  }

  func testOptionParsing() {
    let option = PikafishUCI.parseOption(
      "option name Hash type spin default 16 min 1 max 33554432".split(separator: " "))
    XCTAssertEqual(option?.name, "Hash")
    XCTAssertEqual(option?.kind, .spin)
    XCTAssertEqual(option?.min, 1)
    XCTAssertEqual(option?.max, 33_554_432)
    XCTAssertEqual(option?.defaultValue, "16")

    let combo = PikafishUCI.parseOption(
      "option name Style type combo default Normal var Normal var Aggressive".split(separator: " "))
    XCTAssertEqual(combo?.variables, ["Normal", "Aggressive"])

    let spaced = PikafishUCI.parseOption(
      "option name Move Overhead type spin default 10 min 0 max 5000".split(separator: " "))
    XCTAssertEqual(spaced?.name, "Move Overhead")

    // Spin without min/max is malformed.
    XCTAssertNil(
      PikafishUCI.parseOption("option name Bad type spin default 1".split(separator: " ")))
  }

  func testScorePerspectiveConversion() {
    let red = PikafishScore(kind: .centipawn(40), bound: nil)
    XCTAssertEqual(red.centipawnsFromRedPerspective(sideToMove: .red), 40)
    XCTAssertEqual(red.centipawnsFromRedPerspective(sideToMove: .black), -40)
    let mate = PikafishScore(kind: .mate(3), bound: nil)
    XCTAssertNil(mate.centipawnsFromRedPerspective(sideToMove: .red))
  }

  func testDisplayedEvaluationMatrix() {
    // Red to move, Red is better by 40 cp.
    let redCp = PikafishScore(kind: .centipawn(40), bound: nil)
    let redView = redCp.displayed(in: .red, sideToMove: .red)
    XCTAssertEqual(redView.centipawnsFromRedPerspective, 40)
    XCTAssertNil(redView.matePly)
    let sideView = redCp.displayed(in: .sideToMove, sideToMove: .red)
    XCTAssertEqual(sideView.centipawnsFromRedPerspective, 40)
    XCTAssertEqual(sideView.perspective, .sideToMove)

    // Black to move, engine reports -200 cp (Black better).
    let blackCp = PikafishScore(kind: .centipawn(-200), bound: nil)
    let redViewBlack = blackCp.displayed(in: .red, sideToMove: .black)
    XCTAssertEqual(redViewBlack.centipawnsFromRedPerspective, 200)
    XCTAssertNil(redViewBlack.redMates)

    // Red to move mates in 1 ply: raw mate +1.
    let mate1 = PikafishScore(kind: .mate(1), bound: nil)
    XCTAssertEqual(mate1.displayed(in: .red, sideToMove: .red).matePly, 1)
    XCTAssertEqual(mate1.displayed(in: .red, sideToMove: .red).redMates, true)
    // Same engine score from Black's perspective means Black mates.
    XCTAssertEqual(mate1.displayed(in: .red, sideToMove: .black).matePly, 1)
    XCTAssertEqual(mate1.displayed(in: .red, sideToMove: .black).redMates, false)

    // Black to move gets mated: raw mate -2 means the side to move is mated.
    let mated = PikafishScore(kind: .mate(-2), bound: nil)
    XCTAssertEqual(mated.displayed(in: .red, sideToMove: .red).redMates, false)
    XCTAssertEqual(mated.displayed(in: .red, sideToMove: .black).redMates, true)

    // Bounds survive conversion.
    let bounded = PikafishScore(kind: .centipawn(10), bound: .lowerbound)
    XCTAssertEqual(bounded.displayed(in: .red, sideToMove: .red).bound, .lowerbound)
    // sideToMove perspective keeps the raw sign convention.
    let blackMates = PikafishScore(kind: .mate(3), bound: nil)
    XCTAssertEqual(blackMates.displayed(in: .sideToMove, sideToMove: .black).redMates, nil)
  }

  func testSearchBudgetValidationAndTimeAwareResolution() throws {
    let fixed = try PikafishSearchBudget(.fixedMilliseconds(2_000))
    XCTAssertEqual(fixed.resolvedMilliseconds, 2_000)
    XCTAssertEqual(fixed.uciSuffix, "movetime 2000")
    XCTAssertThrowsError(try PikafishSearchBudget(.fixedMilliseconds(0)))
    XCTAssertThrowsError(try PikafishSearchBudget(.fixedMilliseconds(-1)))
    XCTAssertThrowsError(
      try PikafishSearchBudget(.fixedMilliseconds(PikafishLimits.maximumSearchMilliseconds + 1)))

    let aware = try PikafishSearchBudget(
      .timeAware(
        remainingMilliseconds: 120_000, incrementMilliseconds: 10_000, estimatedMovesLeft: 40))
    // base = 3000, + increment/2 = 5000, so the budget is 8000, below the cap.
    XCTAssertEqual(aware.resolvedMilliseconds, 8_000)
    XCTAssertEqual(aware.uciSuffix, "movetime 8000")

    // Large time: the budget never exceeds remaining minus the safety reserve.
    let huge = try PikafishSearchBudget(
      .timeAware(
        remainingMilliseconds: 1_800_000, incrementMilliseconds: 60_000, estimatedMovesLeft: 2))
    XCTAssertEqual(huge.resolvedMilliseconds, 930_000)
    XCTAssertLessThanOrEqual(huge.resolvedMilliseconds, 1_800_000 - 90_000)

    // Critical time collapses to remaining/4 but never to zero.
    let critical = try PikafishSearchBudget(
      .timeAware(remainingMilliseconds: 1_200, incrementMilliseconds: 0, estimatedMovesLeft: 10))
    XCTAssertEqual(critical.resolvedMilliseconds, 300)

    XCTAssertThrowsError(
      try PikafishSearchBudget(
        .timeAware(remainingMilliseconds: 0, incrementMilliseconds: 0, estimatedMovesLeft: 10)))
    XCTAssertThrowsError(
      try PikafishSearchBudget(
        .timeAware(
          remainingMilliseconds: 10_000, incrementMilliseconds: 1_000_000, estimatedMovesLeft: 10)))
    XCTAssertThrowsError(
      try PikafishSearchBudget(
        .timeAware(remainingMilliseconds: 10_000, incrementMilliseconds: 0, estimatedMovesLeft: 1)))
  }

  func testResourcePresetResolution() {
    XCTAssertEqual(
      PikafishResourcePreset.light.resolvedHashMiB(totalPhysicalMemoryBytes: 8_000_000_000), 16)
    XCTAssertEqual(
      PikafishResourcePreset.standard.resolvedHashMiB(totalPhysicalMemoryBytes: 8_000_000_000), 32)
    XCTAssertEqual(
      PikafishResourcePreset.standard.resolvedHashMiB(totalPhysicalMemoryBytes: 24_000_000_000), 64)
    XCTAssertEqual(PikafishResourcePreset.standard.resolvedThreads(activeProcessorCount: 2), 1)
    XCTAssertEqual(PikafishResourcePreset.standard.resolvedThreads(activeProcessorCount: 8), 2)
    XCTAssertEqual(PikafishResourcePreset.deep.resolvedThreads(activeProcessorCount: 1), 4)
    XCTAssertEqual(PikafishResourcePreset.allCases, [.light, .standard, .deep])
  }
}
