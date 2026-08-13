import CSQLite3
import Foundation
import XCTest

@testable import PikafishKit

/// SQLite's `SQLITE_TRANSIENT` is a macro and is not imported into Swift; this
/// is the standard re-derivation used by SwiftPM SQLite bindings.
private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Bounded SQLite cache behavior: identity, LRU, caps, final-only, corruption.
final class AnalysisCacheTests: XCTestCase {
  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("nx-cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeCache(
    directory: URL,
    diskCapMiB: Int64 = 1,
    memoryEntryCap: Int = 3,
    memoryByteMiB: Int64 = 1
  ) throws -> AnalysisCache {
    try AnalysisCache(
      configuration: AnalysisCacheConfiguration(
        directory: directory,
        diskCapMiB: diskCapMiB,
        memoryEntryCap: memoryEntryCap,
        memoryByteMiB: memoryByteMiB
      )
    )
  }

  private func makeMaterial(
    fen: String = "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1",
    moves: [String] = ["b2b3"],
    profileID: UInt32 = 1,
    profileVersion: UInt32 = 1,
    positionHash: UInt64 = 1,
    repetitionHash: UInt64 = 2,
    engineCommit: String = "ce0679e00ee196f7ba17f6ec18941b9a5036f8cf",
    networkHash: Data = Data(repeating: 0xAB, count: 32),
    presetName: String = "light",
    budgetKind: String = "fixed",
    budgetMilliseconds: Int = 2_000,
    candidateCount: Int = 1
  ) -> AnalysisCacheKey.Material {
    AnalysisCacheKey.Material(
      initialFEN: fen,
      ucciMoves: moves,
      profileID: profileID,
      profileVersion: profileVersion,
      positionHash: positionHash,
      repetitionHash: repetitionHash,
      engineCommit: engineCommit,
      networkHash: networkHash,
      presetName: presetName,
      budgetKind: budgetKind,
      budgetMilliseconds: budgetMilliseconds,
      candidateCount: candidateCount
    )
  }

  private func makeResult() -> PikafishValidatedFinalResult {
    let info = PikafishInfo(
      depth: 12,
      seldepth: 14,
      multipv: 1,
      score: PikafishScore(kind: .centipawn(33), bound: nil),
      nodes: 12_345,
      nps: 6_000,
      timeMilliseconds: 2_000,
      hashfull: 12,
      pv: ["b2b3", "b7b6"]
    )
    return PikafishValidatedFinalResult(
      searchGeneration: 1,
      bestMove: PikafishBestMove(move: "b2b3", ponder: "b7b6"),
      candidates: [PikafishCandidate(rank: 1, info: info)],
      elapsedMilliseconds: 2_000,
      sideToMove: .red
    )
  }

  // MARK: - Key identity

  func testKeyIsStableAndEveryIdentityDimensionChangesIt() async {
    let base = makeMaterial()
    let baseKey = AnalysisCacheKey.make(from: base)
    XCTAssertEqual(AnalysisCacheKey.make(from: base), baseKey)

    XCTAssertNotEqual(
      AnalysisCacheKey.make(from: makeMaterial(fen: "9/9/9/9/9/9/9/9/9/9 w - - 0 1")), baseKey)
    XCTAssertNotEqual(AnalysisCacheKey.make(from: makeMaterial(moves: [])), baseKey)
    XCTAssertNotEqual(AnalysisCacheKey.make(from: makeMaterial(profileID: 2)), baseKey)
    XCTAssertNotEqual(AnalysisCacheKey.make(from: makeMaterial(profileVersion: 2)), baseKey)
    XCTAssertNotEqual(AnalysisCacheKey.make(from: makeMaterial(positionHash: 99)), baseKey)
    // The critical dimension: identical FEN with a different repetition history.
    XCTAssertNotEqual(AnalysisCacheKey.make(from: makeMaterial(repetitionHash: 99)), baseKey)
    XCTAssertNotEqual(AnalysisCacheKey.make(from: makeMaterial(engineCommit: "other")), baseKey)
    XCTAssertNotEqual(
      AnalysisCacheKey.make(from: makeMaterial(networkHash: Data(repeating: 0xCD, count: 32))),
      baseKey)
    XCTAssertNotEqual(AnalysisCacheKey.make(from: makeMaterial(presetName: "deep")), baseKey)
    XCTAssertNotEqual(AnalysisCacheKey.make(from: makeMaterial(budgetKind: "timeAware")), baseKey)
    XCTAssertNotEqual(AnalysisCacheKey.make(from: makeMaterial(budgetMilliseconds: 3_000)), baseKey)
    XCTAssertNotEqual(AnalysisCacheKey.make(from: makeMaterial(candidateCount: 3)), baseKey)
  }

  // MARK: - Round trip

  func testValidatedResultRoundTrips() async throws {
    let cache = try makeCache(directory: makeDirectory())
    let cacheToClose = cache
    addTeardownBlock { await cacheToClose.close() }
    let key = AnalysisCacheKey.make(from: makeMaterial())
    try await cache.store(
      key: key,
      validated: makeResult(),
      engineCommit: "ce0679e00ee196f7ba17f6ec18941b9a5036f8cf",
      networkHash: Data(repeating: 0xAB, count: 32),
      budget: try PikafishSearchBudget(.fixedMilliseconds(2_000))
    )
    let lookedUp = await cache.lookup(key: key)
    let payload = try XCTUnwrap(lookedUp)
    XCTAssertEqual(payload.bestMove, "b2b3")
    XCTAssertEqual(payload.ponder, "b7b6")
    XCTAssertEqual(payload.candidates.count, 1)
    XCTAssertEqual(payload.candidates[0].rank, 1)
    XCTAssertEqual(payload.candidates[0].depth, 12)
    XCTAssertEqual(payload.candidates[0].scoreKind, "cp")
    XCTAssertEqual(payload.candidates[0].scoreValue, 33)
    XCTAssertEqual(payload.candidates[0].pv, ["b2b3", "b7b6"])
    XCTAssertEqual(payload.sideToMove, 0)
    // A different identity misses.
    let otherKey = AnalysisCacheKey.make(from: makeMaterial(positionHash: 9))
    let otherHit = await cache.lookup(key: otherKey)
    XCTAssertNil(otherHit)
  }

  // MARK: - Bounds and LRU

  func testMemoryEntryCapEvictsLeastRecentlyUsed() async throws {
    let cache = try makeCache(directory: makeDirectory(), memoryEntryCap: 2)
    let cacheToClose = cache
    addTeardownBlock { await cacheToClose.close() }
    let keyA = AnalysisCacheKey.make(from: makeMaterial(positionHash: 1))
    let keyB = AnalysisCacheKey.make(from: makeMaterial(positionHash: 2))
    let keyC = AnalysisCacheKey.make(from: makeMaterial(positionHash: 3))
    try await cache.store(
      key: keyA, validated: makeResult(), engineCommit: "e",
      networkHash: Data(repeating: 1, count: 32),
      budget: try PikafishSearchBudget(.fixedMilliseconds(100)))
    try await cache.store(
      key: keyB, validated: makeResult(), engineCommit: "e",
      networkHash: Data(repeating: 1, count: 32),
      budget: try PikafishSearchBudget(.fixedMilliseconds(100)))
    // Touch A so B becomes the eviction candidate.
    _ = await cache.lookup(key: keyA)
    try await cache.store(
      key: keyC, validated: makeResult(), engineCommit: "e",
      networkHash: Data(repeating: 1, count: 32),
      budget: try PikafishSearchBudget(.fixedMilliseconds(100)))
    // The memory cache stays bounded, and the evicted entry reloads from disk.
    let (memoryEntries, _) = await cache.summary()
    XCTAssertLessThanOrEqual(memoryEntries, 2)
    let bHit = await cache.lookup(key: keyB)
    XCTAssertNotNil(bHit)
    let aHit = await cache.lookup(key: keyA)
    XCTAssertNotNil(aHit)
    let cHit = await cache.lookup(key: keyC)
    XCTAssertNotNil(cHit)
    let (memoryEntriesAfter, _) = await cache.summary()
    XCTAssertLessThanOrEqual(memoryEntriesAfter, 2)
  }

  func testMemoryPurgeClearsEntriesWithoutDisk() async throws {
    let cache = try makeCache(directory: makeDirectory())
    let cacheToClose = cache
    addTeardownBlock { await cacheToClose.close() }
    let key = AnalysisCacheKey.make(from: makeMaterial())
    try await cache.store(
      key: key, validated: makeResult(), engineCommit: "e",
      networkHash: Data(repeating: 1, count: 32),
      budget: try PikafishSearchBudget(.fixedMilliseconds(100)))
    await cache.purgeMemory()
    let (memoryEntries, _) = await cache.summary()
    XCTAssertEqual(memoryEntries, 0)
  }

  func testDiskByteCapEvictsOldestRows() async throws {
    // One row is roughly 400 bytes; a 1 KiB cap fits two rows, so storing a
    // third row must evict the least-recently-written first row from disk.
    let directory = try makeDirectory()
    let cache = try AnalysisCache(
      configuration: AnalysisCacheConfiguration(
        directory: directory,
        diskCapBytes: 1_024,
        memoryEntryCap: 16,
        memoryByteBytes: 1 * 1_024 * 1_024
      )
    )
    let cacheToClose = cache
    addTeardownBlock { await cacheToClose.close() }
    let keyA = AnalysisCacheKey.make(from: makeMaterial(positionHash: 1))
    let keyB = AnalysisCacheKey.make(from: makeMaterial(positionHash: 2))
    let keyC = AnalysisCacheKey.make(from: makeMaterial(positionHash: 3))
    try await cache.store(
      key: keyA, validated: makeResult(), engineCommit: "e",
      networkHash: Data(repeating: 1, count: 32),
      budget: try PikafishSearchBudget(.fixedMilliseconds(100)))
    try await cache.store(
      key: keyB, validated: makeResult(), engineCommit: "e",
      networkHash: Data(repeating: 1, count: 32),
      budget: try PikafishSearchBudget(.fixedMilliseconds(100)))
    try await cache.store(
      key: keyC, validated: makeResult(), engineCommit: "e",
      networkHash: Data(repeating: 1, count: 32),
      budget: try PikafishSearchBudget(.fixedMilliseconds(100)))
    // Fresh memory lookups would hide the eviction, so purge memory first to
    // prove the disk layer actually bounded.
    await cache.purgeMemory()
    let aMiss = await cache.lookup(key: keyA)
    XCTAssertNil(aMiss)
    let bHit = await cache.lookup(key: keyB)
    XCTAssertNotNil(bHit)
    let cHit = await cache.lookup(key: keyC)
    XCTAssertNotNil(cHit)
  }

  func testCloseFailsClosed() async throws {
    let cache = try makeCache(directory: makeDirectory())
    await cache.close()
    do {
      try await cache.store(
        key: AnalysisCacheKey.make(from: makeMaterial()),
        validated: makeResult(),
        engineCommit: "e",
        networkHash: Data(repeating: 1, count: 32),
        budget: try PikafishSearchBudget(.fixedMilliseconds(100))
      )
      XCTFail("expected closed failure")
    } catch {
      // Expected: closed caches fail closed.
    }
  }

  // MARK: - Corruption isolation

  func testCorruptDatabaseIsQuarantinedAndRebuilt() async throws {
    let directory = try makeDirectory()
    var cache = try makeCache(directory: directory)
    let key = AnalysisCacheKey.make(from: makeMaterial())
    try await cache.store(
      key: key, validated: makeResult(), engineCommit: "e",
      networkHash: Data(repeating: 1, count: 32),
      budget: try PikafishSearchBudget(.fixedMilliseconds(100)))
    await cache.close()

    // Overwrite the database with garbage so the next open must quarantine it.
    let dbURL = directory.appendingPathComponent("AnalysisCache.sqlite3")
    try Data(repeating: 0xFF, count: 4_096).write(to: dbURL)

    // The corrupt open path must quarantine and recreate without throwing.
    cache = try makeCache(directory: directory)
    let cacheToClose = cache
    addTeardownBlock { await cacheToClose.close() }
    let corruptMiss = await cache.lookup(key: key)
    XCTAssertNil(corruptMiss)
    try await cache.store(
      key: key, validated: makeResult(), engineCommit: "e",
      networkHash: Data(repeating: 1, count: 32),
      budget: try PikafishSearchBudget(.fixedMilliseconds(100)))
    let rebuiltHit = await cache.lookup(key: key)
    let payload = try XCTUnwrap(rebuiltHit)
    XCTAssertEqual(payload.bestMove, "b2b3")
    let quarantines = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasSuffix(".quarantine") }
    XCTAssertEqual(quarantines.count, 1)
  }

  func testMalformedPayloadIsMissAndDeletesOnlyThatRow() async throws {
    let directory = try makeDirectory()
    let cache = try makeCache(directory: directory)
    let cacheToClose = cache
    addTeardownBlock { await cacheToClose.close() }
    let goodKey = AnalysisCacheKey.make(from: makeMaterial(positionHash: 1))
    try await cache.store(
      key: goodKey, validated: makeResult(), engineCommit: "e",
      networkHash: Data(repeating: 1, count: 32),
      budget: try PikafishSearchBudget(.fixedMilliseconds(100)))
    // Close before the raw injection so no second connection contends with the
    // cache's WAL writer while the malformed row is added.
    await cache.close()

    // Insert a garbage payload row directly through the C API.
    let dbURL = directory.appendingPathComponent("AnalysisCache.sqlite3")
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
    guard let db else {
      return XCTFail("open failed")
    }
    let badKey = AnalysisCacheKey.make(from: makeMaterial(positionHash: 2))
    let badKeyPointer = (badKey as NSData).bytes
    let garbage = Data(repeating: 0x00, count: 32)
    let garbagePointer = (garbage as NSData).bytes
    let sql = "INSERT OR REPLACE INTO analysis_entry VALUES (?1, 'e', ?2, 1, 1, 1, ?3, 32)"
    var statement: OpaquePointer?
    XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
    sqlite3_bind_blob(statement, 1, badKeyPointer, Int32(badKey.count), sqliteTransientDestructor)
    sqlite3_bind_blob(statement, 2, garbagePointer, Int32(garbage.count), sqliteTransientDestructor)
    sqlite3_bind_blob(statement, 3, garbagePointer, Int32(garbage.count), sqliteTransientDestructor)
    XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    sqlite3_finalize(statement)
    sqlite3_close(db)

    // Reopen and verify: the malformed row decodes as a miss and is deleted.
    let reopened = try makeCache(directory: directory)
    let reopenedToClose = reopened
    addTeardownBlock { await reopenedToClose.close() }
    let badMiss = await reopened.lookup(key: badKey)
    XCTAssertNil(badMiss)
    let goodHit = await reopened.lookup(key: goodKey)
    XCTAssertNotNil(goodHit)
    // The bad row stays deleted from disk on a second pass.
    await reopened.purgeMemory()
    let badMissAgain = await reopened.lookup(key: badKey)
    XCTAssertNil(badMissAgain)
    let goodHitAgain = await reopened.lookup(key: goodKey)
    XCTAssertNotNil(goodHitAgain)
  }

  func testConcurrentStoresAreSerialized() async throws {
    let cache = try makeCache(directory: makeDirectory(), memoryEntryCap: 8)
    let cacheToClose = cache
    addTeardownBlock { await cacheToClose.close() }
    let keys = (1...6).map { AnalysisCacheKey.make(from: makeMaterial(positionHash: UInt64($0))) }
    let result = makeResult()
    await withTaskGroup(of: Void.self) { group in
      for (index, key) in keys.enumerated() {
        group.addTask {
          try? await cache.store(
            key: key,
            validated: result,
            engineCommit: "e",
            networkHash: Data(repeating: 1, count: 32),
            budget: try PikafishSearchBudget(.fixedMilliseconds(100))
          )
          _ = await cache.lookup(key: key)
          if index % 2 == 0 {
            await cache.purgeMemory()
          }
        }
      }
    }
    for key in keys {
      let hit = await cache.lookup(key: key)
      XCTAssertNotNil(hit)
    }
  }
}
