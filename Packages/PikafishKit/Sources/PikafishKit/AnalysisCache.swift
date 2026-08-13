//! Bounded persistent analysis cache backed by the system SQLite3 library.
//!
//! One actor owns the database connection, prepared statements, schema
//! migration, a small memory LRU, and disk LRU eviction. Only validated final
//! results (`PikafishValidatedFinalResult`) may be stored; partial info,
//! cancellations, crashes, and unvalidated outcomes never reach the cache.
//! Corruption is quarantined and rebuilt; cache failure never prevents
//! document open/save/close.

import CSQLite3
import CryptoKit
import Foundation

/// Cache limits and location. The default disk cap is 256 MiB with the
/// documented 64/256/1024 MiB choices; memory keeps at most 32 entries under a
/// byte cap.
public struct AnalysisCacheConfiguration: Sendable, Equatable {
  public static let allowedDiskMiB: [Int64] = [64, 256, 1_024]
  public static let defaultDiskMiB: Int64 = 256
  public static let defaultMemoryEntryCap = 32
  public static let defaultMemoryByteMiB: Int64 = 16

  public let directory: URL
  public let diskCapBytes: Int64
  public let memoryEntryCap: Int
  public let memoryByteCap: Int64

  public init(
    directory: URL,
    diskCapMiB: Int64 = AnalysisCacheConfiguration.defaultDiskMiB,
    memoryEntryCap: Int = AnalysisCacheConfiguration.defaultMemoryEntryCap,
    memoryByteMiB: Int64 = AnalysisCacheConfiguration.defaultMemoryByteMiB
  ) {
    self.directory = directory
    self.diskCapBytes = diskCapMiB * 1_024 * 1_024
    self.memoryEntryCap = memoryEntryCap
    self.memoryByteCap = memoryByteMiB * 1_024 * 1_024
  }

  /// Byte-precision configuration for tests and benchmarks. The public surface
  /// keeps the documented MiB choices; this is internal so resource gates
  /// remain explicit.
  init(
    directory: URL,
    diskCapBytes: Int64,
    memoryEntryCap: Int,
    memoryByteBytes: Int64
  ) {
    self.directory = directory
    self.diskCapBytes = diskCapBytes
    self.memoryEntryCap = memoryEntryCap
    self.memoryByteCap = memoryByteBytes
  }
}

/// Typed failures. Every failure keeps the cache isolated and the document
/// usable.
public enum AnalysisCacheError: Error, Sendable, Equatable, LocalizedError {
  case cannotOpen(String)
  case corrupt(String)
  case statement(String)
  case ioFailure(String)
  case outOfBounds(String)

  public var errorDescription: String? {
    switch self {
    case .cannotOpen(let detail):
      "无法打开分析缓存：\(detail)"
    case .corrupt(let detail):
      "分析缓存已损坏并隔离重建：\(detail)"
    case .statement(let detail):
      "分析缓存语句失败：\(detail)"
    case .ioFailure(let detail):
      "分析缓存文件操作失败：\(detail)"
    case .outOfBounds(let detail):
      "分析缓存参数越界：\(detail)"
    }
  }
}

/// The cache key is a SHA-256 over every identity dimension in a fixed field
/// order. Swift `Hasher` is never used (its seed is not stable across
/// processes); a single field change must produce a different key.
public enum AnalysisCacheKey {
  public static let schemaVersion = 1
  /// Payload encoding version; bumping it invalidates old payloads on decode.
  public static let payloadSchemaVersion = 1

  public struct Material: Sendable, Equatable {
    public let initialFEN: String
    public let ucciMoves: [String]
    public let profileID: UInt32
    public let profileVersion: UInt32
    public let positionHash: UInt64
    public let repetitionHash: UInt64
    public let engineCommit: String
    public let networkHash: Data
    public let presetName: String
    public let budgetKind: String
    public let budgetMilliseconds: Int
    public let candidateCount: Int

    public init(
      initialFEN: String,
      ucciMoves: [String],
      profileID: UInt32,
      profileVersion: UInt32,
      positionHash: UInt64,
      repetitionHash: UInt64,
      engineCommit: String,
      networkHash: Data,
      presetName: String,
      budgetKind: String,
      budgetMilliseconds: Int,
      candidateCount: Int
    ) {
      self.initialFEN = initialFEN
      self.ucciMoves = ucciMoves
      self.profileID = profileID
      self.profileVersion = profileVersion
      self.positionHash = positionHash
      self.repetitionHash = repetitionHash
      self.engineCommit = engineCommit
      self.networkHash = networkHash
      self.presetName = presetName
      self.budgetKind = budgetKind
      self.budgetMilliseconds = budgetMilliseconds
      self.candidateCount = candidateCount
    }
  }

  public static func make(from material: Material) -> Data {
    var hasher = SHA256()
    func append(_ text: String) {
      let bytes = Array(text.utf8)
      var length = UInt64(bytes.count)
      withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
      bytes.withUnsafeBytes { hasher.update(bufferPointer: $0) }
    }
    func append(_ value: UInt64) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { hasher.update(bufferPointer: $0) }
    }
    func append(_ value: UInt32) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { hasher.update(bufferPointer: $0) }
    }
    func append(_ data: Data) {
      var length = UInt64(data.count)
      withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
      data.withUnsafeBytes { hasher.update(bufferPointer: $0) }
    }
    hasher.update(data: Data("NXQ-ANALYSIS-CACHE".utf8))
    append(UInt64(schemaVersion))
    append(material.initialFEN)
    append(UInt64(material.ucciMoves.count))
    for move in material.ucciMoves {
      append(move)
    }
    append(material.profileID)
    append(material.profileVersion)
    append(material.positionHash)
    append(material.repetitionHash)
    append(material.engineCommit)
    append(material.networkHash)
    append(material.presetName)
    append(material.budgetKind)
    append(UInt64(material.budgetMilliseconds))
    append(UInt64(material.candidateCount))
    return Data(hasher.finalize())
  }
}

/// Decoded cache payload. Only validated final results are representable.
public struct AnalysisCachePayload: Sendable, Equatable {
  public struct Candidate: Sendable, Equatable {
    public let rank: Int
    public let depth: Int?
    public let seldepth: Int?
    public let scoreKind: String
    public let scoreValue: Int
    public let scoreBound: String?
    public let nodes: Int?
    public let nps: Int?
    public let timeMilliseconds: Int?
    public let hashfull: Int?
    public let pv: [String]

    public init(
      rank: Int,
      depth: Int?,
      seldepth: Int?,
      scoreKind: String,
      scoreValue: Int,
      scoreBound: String?,
      nodes: Int?,
      nps: Int?,
      timeMilliseconds: Int?,
      hashfull: Int?,
      pv: [String]
    ) {
      self.rank = rank
      self.depth = depth
      self.seldepth = seldepth
      self.scoreKind = scoreKind
      self.scoreValue = scoreValue
      self.scoreBound = scoreBound
      self.nodes = nodes
      self.nps = nps
      self.timeMilliseconds = timeMilliseconds
      self.hashfull = hashfull
      self.pv = pv
    }
  }

  public let schemaVersion: Int
  public let bestMove: String?
  public let ponder: String?
  public let candidates: [Candidate]
  public let elapsedMilliseconds: Int
  public let sideToMove: UInt8

  public init(
    schemaVersion: Int,
    bestMove: String?,
    ponder: String?,
    candidates: [Candidate],
    elapsedMilliseconds: Int,
    sideToMove: UInt8
  ) {
    self.schemaVersion = schemaVersion
    self.bestMove = bestMove
    self.ponder = ponder
    self.candidates = candidates
    self.elapsedMilliseconds = elapsedMilliseconds
    self.sideToMove = sideToMove
  }
}

/// One bounded SQLite-backed analysis cache. All access is serialized by the
/// actor; operations never block the main actor or the document.
public actor AnalysisCache {
  private struct MemoryEntry {
    var lastAccessed: Int64
    var payloadBytes: Int
    var value: AnalysisCachePayload
  }

  private static let schemaVersion = 1
  private static let maximumQuarantineFiles = 3

  private let configuration: AnalysisCacheConfiguration
  private var database: OpaquePointer?
  private var insertStatement: OpaquePointer?
  private var selectStatement: OpaquePointer?
  private var touchStatement: OpaquePointer?
  private var deleteStatement: OpaquePointer?
  private var totalBytesStatement: OpaquePointer?
  private var oldestKeysStatement: OpaquePointer?
  private var memoryCache: [Data: MemoryEntry] = [:]
  private var memoryBytes = 0
  private var isClosed = false
  /// Strictly increasing per-actor stamp so LRU ties never rely on wall-clock
  /// resolution or dictionary iteration order.
  private var monotonicStamp: Int64 = 0

  /// Opens (and migrates) the database synchronously. Callers must run this on
  /// a non-main executor, for example inside the analysis coordinator.
  public init(configuration: AnalysisCacheConfiguration) throws {
    self.configuration = configuration
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: configuration.directory, withIntermediateDirectories: true)
    } catch {
      throw AnalysisCacheError.ioFailure("\(error.localizedDescription)")
    }
    let opened = try Self.openAndPrepare(directory: configuration.directory)
    database = opened.database
    insertStatement = opened.insert
    selectStatement = opened.select
    touchStatement = opened.touch
    deleteStatement = opened.delete
    totalBytesStatement = opened.totalBytes
    oldestKeysStatement = opened.oldestKeys
  }

  // MARK: - Public operations

  /// Looks up a key. A decode failure is treated as a miss and deletes only
  /// that row; database corruption is quarantined and rebuilt.
  public func lookup(key: Data) -> AnalysisCachePayload? {
    if let value = memoryCache[key] {
      var entry = value
      entry.lastAccessed = nowStamp()
      memoryCache[key] = entry
      touchDisk(key: key)
      return entry.value
    }
    return readFromDisk(key: key)
  }

  /// Disk read path used on a memory miss: decode, delete malformed rows,
  /// refresh the LRU stamp, and insert into the memory cache.
  private func readFromDisk(key: Data) -> AnalysisCachePayload? {
    guard let statement = selectStatement, !isClosed else {
      return nil
    }
    sqlite3_reset(statement)
    sqlite3_clear_bindings(statement)
    bindBlob(statement, index: 1, data: key)
    let code = sqlite3_step(statement)
    guard code == SQLITE_ROW else {
      if code == SQLITE_ERROR || code == SQLITE_CORRUPT {
        recoverFromCorruption()
      }
      return nil
    }
    guard let payloadData = columnBlob(statement, index: 3) else {
      return nil
    }
    guard let payload = Self.decode(payloadData: payloadData) else {
      // Malformed payload: a miss that deletes only this row.
      deleteRow(key: key)
      return nil
    }
    touchDisk(key: key)
    insertMemory(key: key, payload: payload, payloadBytes: payloadData.count, now: nowStamp())
    evictMemory()
    return payload
  }

  /// Stores a validated final result. Partial, cancelled, stale, or
  /// unvalidated outcomes are rejected by construction (the caller must pass
  /// `PikafishValidatedFinalResult`). Eviction runs after the write.
  public func store(
    key: Data,
    validated result: PikafishValidatedFinalResult,
    engineCommit: String,
    networkHash: Data,
    budget: PikafishSearchBudget
  ) throws {
    guard !isClosed else {
      throw AnalysisCacheError.corrupt("closed")
    }
    let payload = Self.encode(
      result: result, engineCommit: engineCommit, networkHash: networkHash, budget: budget)
    let payloadData = try Self.encodedData(payload)
    guard payloadData.count <= 4 * 1_024 * 1_024 else {
      throw AnalysisCacheError.outOfBounds("payload \(payloadData.count) bytes")
    }
    let now = nowStamp()
    insertOrReplace(
      key: key, payload: payloadData, engineCommit: engineCommit, networkHash: networkHash,
      createdAt: now, lastAccessed: now)
    if let decoded = Self.decode(payloadData: payloadData) {
      insertMemory(key: key, payload: decoded, payloadBytes: payloadData.count, now: now)
    }
    evictMemory()
    try evictDiskIfNeeded()
  }

  /// Drops all in-memory cache entries (used on memory pressure). Disk data is
  /// preserved.
  public func purgeMemory() {
    memoryCache.removeAll(keepingCapacity: false)
    memoryBytes = 0
  }

  /// Bounded size summary for diagnostics and benchmarks.
  public func summary() -> (memoryEntries: Int, diskBytes: Int64) {
    let diskBytes = totalDiskBytes()
    return (memoryCache.count, diskBytes)
  }

  /// Closes the database. Subsequent calls fail closed.
  public func close() {
    guard !isClosed else {
      return
    }
    isClosed = true
    for statement in [
      insertStatement, selectStatement, touchStatement, deleteStatement, totalBytesStatement,
      oldestKeysStatement,
    ] {
      if let statement {
        sqlite3_finalize(statement)
      }
    }
    insertStatement = nil
    selectStatement = nil
    touchStatement = nil
    deleteStatement = nil
    totalBytesStatement = nil
    oldestKeysStatement = nil
    memoryCache.removeAll(keepingCapacity: false)
    memoryBytes = 0
    if let database {
      sqlite3_close(database)
    }
    database = nil
  }

  // MARK: - Payload codec

  private struct EncodableCandidate: Codable {
    let rank: Int
    let depth: Int?
    let seldepth: Int?
    let scoreKind: String
    let scoreValue: Int
    let scoreBound: String?
    let nodes: Int?
    let nps: Int?
    let timeMilliseconds: Int?
    let hashfull: Int?
    let pv: [String]
  }

  private struct EncodablePayload: Codable {
    let schemaVersion: Int
    let bestMove: String?
    let ponder: String?
    let candidates: [EncodableCandidate]
    let elapsedMilliseconds: Int
    let sideToMove: UInt8
    let engineCommit: String
    let networkHash: Data
    let budgetKind: String
    let budgetMilliseconds: Int
  }

  private static func encode(
    result: PikafishValidatedFinalResult,
    engineCommit: String,
    networkHash: Data,
    budget: PikafishSearchBudget
  ) -> EncodablePayload {
    EncodablePayload(
      schemaVersion: AnalysisCacheKey.payloadSchemaVersion,
      bestMove: result.bestMove.move,
      ponder: result.bestMove.ponder,
      candidates: result.candidates.map { candidate in
        let info = candidate.info
        let score = info.score
        return EncodableCandidate(
          rank: candidate.rank,
          depth: info.depth,
          seldepth: info.seldepth,
          scoreKind: score.map { $0.kind.rawKind } ?? "none",
          scoreValue: score.map { $0.kind.rawValue } ?? 0,
          scoreBound: score?.bound?.rawValue,
          nodes: info.nodes,
          nps: info.nps,
          timeMilliseconds: info.timeMilliseconds,
          hashfull: info.hashfull,
          pv: info.pv
        )
      },
      elapsedMilliseconds: result.elapsedMilliseconds,
      sideToMove: result.sideToMove.rawValue,
      engineCommit: engineCommit,
      networkHash: networkHash,
      budgetKind: budget.kind.rawKind,
      budgetMilliseconds: budget.resolvedMilliseconds
    )
  }

  private static func encodedData(_ payload: EncodablePayload) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(payload)
  }

  private static func decode(payloadData: Data) -> AnalysisCachePayload? {
    do {
      let decoder = JSONDecoder()
      let encoded = try decoder.decode(EncodablePayload.self, from: payloadData)
      guard encoded.schemaVersion == AnalysisCacheKey.payloadSchemaVersion else {
        return nil
      }
      return AnalysisCachePayload(
        schemaVersion: encoded.schemaVersion,
        bestMove: encoded.bestMove,
        ponder: encoded.ponder,
        candidates: encoded.candidates.map {
          AnalysisCachePayload.Candidate(
            rank: $0.rank,
            depth: $0.depth,
            seldepth: $0.seldepth,
            scoreKind: $0.scoreKind,
            scoreValue: $0.scoreValue,
            scoreBound: $0.scoreBound,
            nodes: $0.nodes,
            nps: $0.nps,
            timeMilliseconds: $0.timeMilliseconds,
            hashfull: $0.hashfull,
            pv: $0.pv
          )
        },
        elapsedMilliseconds: encoded.elapsedMilliseconds,
        sideToMove: encoded.sideToMove
      )
    } catch {
      return nil
    }
  }

  // MARK: - Memory LRU

  private func insertMemory(key: Data, payload: AnalysisCachePayload, payloadBytes: Int, now: Int64)
  {
    memoryCache[key] = MemoryEntry(lastAccessed: now, payloadBytes: payloadBytes, value: payload)
    memoryBytes += payloadBytes
  }

  private func evictMemory() {
    while memoryCache.count > configuration.memoryEntryCap
      || memoryBytes > configuration.memoryByteCap
    {
      guard let oldest = memoryCache.min(by: { $0.value.lastAccessed < $1.value.lastAccessed })
      else {
        return
      }
      memoryBytes -= oldest.value.payloadBytes
      memoryCache.removeValue(forKey: oldest.key)
    }
  }

  // MARK: - Disk

  private func insertOrReplace(
    key: Data, payload: Data, engineCommit: String, networkHash: Data, createdAt: Int64,
    lastAccessed: Int64
  ) {
    guard let statement = insertStatement else {
      return
    }
    sqlite3_reset(statement)
    sqlite3_clear_bindings(statement)
    bindBlob(statement, index: 1, data: key)
    bindText(statement, index: 2, text: engineCommit)
    bindBlob(statement, index: 3, data: networkHash)
    bindInt64(statement, index: 4, value: Int64(AnalysisCacheKey.payloadSchemaVersion))
    bindInt64(statement, index: 5, value: createdAt)
    bindInt64(statement, index: 6, value: lastAccessed)
    bindBlob(statement, index: 7, data: payload)
    bindInt64(statement, index: 8, value: Int64(payload.count))
    _ = sqlite3_step(statement)
  }

  private func touchDisk(key: Data) {
    guard let statement = touchStatement else {
      return
    }
    sqlite3_reset(statement)
    sqlite3_clear_bindings(statement)
    bindInt64(statement, index: 1, value: nowStamp())
    bindBlob(statement, index: 2, data: key)
    step(statement, expecting: .done)
  }

  private func deleteRow(key: Data) {
    guard let statement = deleteStatement else {
      return
    }
    sqlite3_reset(statement)
    sqlite3_clear_bindings(statement)
    bindBlob(statement, index: 1, data: key)
    step(statement, expecting: .done)
  }

  private func totalDiskBytes() -> Int64 {
    guard let statement = totalBytesStatement else {
      return 0
    }
    sqlite3_reset(statement)
    if sqlite3_step(statement) == SQLITE_ROW {
      return sqlite3_column_int64(statement, 0)
    }
    return 0
  }

  private func evictDiskIfNeeded() throws {
    var total = totalDiskBytes()
    while total > configuration.diskCapBytes {
      // Delete exactly one least-recently-used key per iteration so eviction
      // stops the moment the cap is satisfied.
      guard let oldest = oldestKeys(limit: 1), let key = oldest.first else {
        return
      }
      deleteRow(key: key)
      let newTotal = totalDiskBytes()
      if newTotal >= total {
        return
      }
      total = newTotal
    }
  }

  private func oldestKeys(limit: Int) -> [Data]? {
    guard let statement = oldestKeysStatement else {
      return nil
    }
    sqlite3_reset(statement)
    sqlite3_clear_bindings(statement)
    bindInt64(statement, index: 1, value: Int64(limit))
    var keys: [Data] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let data = columnBlob(statement, index: 0) {
        keys.append(data)
      }
    }
    return keys
  }

  private func nowStamp() -> Int64 {
    monotonicStamp += 1
    return monotonicStamp
  }

  // MARK: - Database open, migration, quarantine

  private struct OpenedDatabase {
    let database: OpaquePointer
    let insert: OpaquePointer
    let select: OpaquePointer
    let touch: OpaquePointer
    let delete: OpaquePointer
    let totalBytes: OpaquePointer
    let oldestKeys: OpaquePointer
  }

  private static func openAndPrepare(directory: URL, alreadyRetried: Bool = false) throws
    -> OpenedDatabase
  {
    let url = directory.appendingPathComponent("AnalysisCache.sqlite3")
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
      throw AnalysisCacheError.cannotOpen("\(url.path)")
    }
    sqlite3_busy_timeout(db, 5_000)
    do {
      guard sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK else {
        throw AnalysisCacheError.corrupt("WAL pragma failed")
      }
      try migrateIfNeeded(db: db)
      let insert = try prepareOrThrow(
        db,
        "INSERT OR REPLACE INTO analysis_entry (key, engine_commit, network_hash, schema_version, created_at, last_accessed_at, payload, payload_bytes) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)"
      )
      let select = try prepareOrThrow(
        db,
        "SELECT engine_commit, network_hash, schema_version, payload FROM analysis_entry WHERE key = ?1"
      )
      let touch = try prepareOrThrow(
        db, "UPDATE analysis_entry SET last_accessed_at = ?1 WHERE key = ?2")
      let delete = try prepareOrThrow(db, "DELETE FROM analysis_entry WHERE key = ?1")
      let totalBytes = try prepareOrThrow(
        db, "SELECT COALESCE(SUM(payload_bytes), 0) FROM analysis_entry")
      let oldestKeys = try prepareOrThrow(
        db, "SELECT key FROM analysis_entry ORDER BY last_accessed_at ASC LIMIT ?1")
      return OpenedDatabase(
        database: db,
        insert: insert,
        select: select,
        touch: touch,
        delete: delete,
        totalBytes: totalBytes,
        oldestKeys: oldestKeys
      )
    } catch {
      sqlite3_close(db)
      guard !alreadyRetried else {
        throw error
      }
      // A corrupt database is renamed aside and a fresh one is created; the
      // caller retries exactly once through this same path.
      try Self.quarantineFiles(directory: directory)
      try Self.trimQuarantineFiles(directory: directory)
      return try openAndPrepare(directory: directory, alreadyRetried: true)
    }
  }

  private static func migrateIfNeeded(db: OpaquePointer) throws {
    var version: Int64 = 0
    if let statement = prepare(db, "PRAGMA user_version") {
      defer {
        sqlite3_finalize(statement)
      }
      if sqlite3_step(statement) == SQLITE_ROW {
        version = sqlite3_column_int64(statement, 0)
      }
    }
    if version >= Self.schemaVersion {
      return
    }
    let create =
      "CREATE TABLE IF NOT EXISTS analysis_entry (" + "key BLOB PRIMARY KEY, "
      + "engine_commit TEXT NOT NULL, " + "network_hash BLOB NOT NULL, "
      + "schema_version INTEGER NOT NULL, " + "created_at INTEGER NOT NULL, "
      + "last_accessed_at INTEGER NOT NULL, " + "payload BLOB NOT NULL, "
      + "payload_bytes INTEGER NOT NULL); "
      + "CREATE INDEX IF NOT EXISTS analysis_lru ON analysis_entry(last_accessed_at);"
    guard sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK else {
      throw AnalysisCacheError.corrupt("schema creation failed")
    }
    guard sqlite3_exec(db, "PRAGMA user_version=\(Self.schemaVersion)", nil, nil, nil) == SQLITE_OK
    else {
      throw AnalysisCacheError.corrupt("user_version update failed")
    }
  }

  private static func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      return nil
    }
    return statement
  }

  private static func prepareOrThrow(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
    guard let statement = prepare(db, sql) else {
      throw AnalysisCacheError.statement("prepare failed")
    }
    return statement
  }

  /// Renames the corrupt database to a bounded quarantine file. Quarantine
  /// files are capped at `maximumQuarantineFiles`.
  private static func quarantineFiles(directory: URL) throws {
    let fileManager = FileManager.default
    let main = directory.appendingPathComponent("AnalysisCache.sqlite3")
    let timestamp = Int(Date().timeIntervalSince1970)
    let quarantineURL =
      directory.appendingPathComponent("AnalysisCache.sqlite3.corrupt-\(timestamp).quarantine")
    if fileManager.fileExists(atPath: main.path) {
      do {
        try fileManager.moveItem(at: main, to: quarantineURL)
      } catch {
        throw AnalysisCacheError.ioFailure("\(error.localizedDescription)")
      }
    }
    try? fileManager.removeItem(at: directory.appendingPathComponent("AnalysisCache.sqlite3-wal"))
    try? fileManager.removeItem(at: directory.appendingPathComponent("AnalysisCache.sqlite3-shm"))
  }

  private static func trimQuarantineFiles(directory: URL) throws {
    let fileManager = FileManager.default
    let files = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
    var quarantines = files.filter { $0.hasSuffix(".quarantine") }.sorted()
    while quarantines.count > Self.maximumQuarantineFiles {
      let oldest = quarantines.removeFirst()
      try? fileManager.removeItem(at: directory.appendingPathComponent(oldest))
    }
  }

  private func closeForQuarantine() {
    for statement in [
      insertStatement, selectStatement, touchStatement, deleteStatement, totalBytesStatement,
      oldestKeysStatement,
    ] {
      if let statement {
        sqlite3_finalize(statement)
      }
    }
    insertStatement = nil
    selectStatement = nil
    touchStatement = nil
    deleteStatement = nil
    totalBytesStatement = nil
    oldestKeysStatement = nil
    if let database {
      sqlite3_close(database)
    }
    database = nil
  }

  /// Runtime corruption recovery: close everything, quarantine the files, and
  /// reopen from scratch inside the actor.
  private func recoverFromCorruption() {
    closeForQuarantine()
    try? Self.quarantineFiles(directory: configuration.directory)
    try? Self.trimQuarantineFiles(directory: configuration.directory)
    guard let opened = try? Self.openAndPrepare(directory: configuration.directory) else {
      isClosed = true
      return
    }
    database = opened.database
    insertStatement = opened.insert
    selectStatement = opened.select
    touchStatement = opened.touch
    deleteStatement = opened.delete
    totalBytesStatement = opened.totalBytes
    oldestKeysStatement = opened.oldestKeys
  }

  // MARK: - SQLite helpers

  private enum StepExpectation {
    case done
    case row
  }

  private func step(_ statement: OpaquePointer, expecting: StepExpectation) {
    let code = sqlite3_step(statement)
    if expecting == .done && code == SQLITE_DONE {
      return
    }
    if expecting == .row && code == SQLITE_ROW {
      return
    }
    if code == SQLITE_BUSY || code == SQLITE_LOCKED {
      // Transient lock contention: fail the operation softly. The row is left
      // untouched and the database is never quarantined for a lock.
      return
    }
    if code == SQLITE_CORRUPT || code == SQLITE_NOTADB || code == SQLITE_SCHEMA
      || code == SQLITE_MISUSE
    {
      // A corrupt database is quarantined and rebuilt; callers observe a miss.
      recoverFromCorruption()
    }
  }

  private func bindText(_ statement: OpaquePointer, index: Int32, text: String) {
    _ = text.withCString {
      sqlite3_bind_text(statement, index, $0, -1, sqliteTransientDestructor)
    }
  }

  private func bindBlob(_ statement: OpaquePointer, index: Int32, data: Data) {
    data.withUnsafeBytes { raw in
      _ = sqlite3_bind_blob(
        statement, index, raw.baseAddress, Int32(raw.count), sqliteTransientDestructor)
    }
  }

  private func bindInt64(_ statement: OpaquePointer, index: Int32, value: Int64) {
    _ = sqlite3_bind_int64(statement, index, value)
  }

  private func columnBlob(_ statement: OpaquePointer, index: Int32) -> Data? {
    guard let bytes = sqlite3_column_blob(statement, index) else {
      return nil
    }
    let count = sqlite3_column_bytes(statement, index)
    guard count >= 0 else {
      return nil
    }
    return Data(bytes: bytes, count: Int(count))
  }
}

/// SQLite's transient destructor sentinel is a macro and is not imported into
/// Swift; this is the standard re-derivation used by every SwiftPM SQLite
/// binding and is functionally identical to `SQLITE_TRANSIENT` in sqlite3.h.
private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension PikafishScoreKind {
  fileprivate var rawKind: String {
    switch self {
    case .centipawn:
      return "cp"
    case .mate:
      return "mate"
    }
  }

  fileprivate var rawValue: Int {
    switch self {
    case .centipawn(let value):
      return value
    case .mate(let value):
      return value
    }
  }
}

extension PikafishSearchBudget.Kind {
  fileprivate var rawKind: String {
    switch self {
    case .fixedMilliseconds:
      return "fixed"
    case .timeAware:
      return "timeAware"
    }
  }
}
