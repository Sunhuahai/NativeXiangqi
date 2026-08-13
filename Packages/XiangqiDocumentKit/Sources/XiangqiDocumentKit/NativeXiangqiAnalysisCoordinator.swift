//! App-owned analysis coordinator: exactly one heavy Pikafish session, one
//! cache, request arbitration, throttled typed updates, and the idle / low
//! power / memory pressure policy. The coordinator owns no canonical document
//! state; documents submit immutable requests and validate results themselves.

import Foundation
import PikafishKit

/// Typed coordinator failures. The document stays fully usable after any of
/// these; analysis is a derived, disposable feature.
public enum NativeXiangqiAnalysisError: Error, Sendable, Equatable, LocalizedError {
  case engineUnavailable
  case assetsUnverified
  case sessionFailure(String)
  case invalidRequest(String)

  public var errorDescription: String? {
    switch self {
    case .engineUnavailable:
      "引擎资源缺失或校验失败，分析不可用。"
    case .assetsUnverified:
      "引擎资源尚未通过校验，无法启动分析。"
    case .sessionFailure(let detail):
      "引擎会话失败：\(detail)"
    case .invalidRequest(let detail):
      "分析请求无效：\(detail)"
    }
  }
}

/// One heavy session plus policy. Created by the app after asset verification;
/// injected into every document.
public actor NativeXiangqiAnalysisCoordinator {
  public struct Configuration: Sendable {
    public let candidateCount: Int
    public let updateIntervalMilliseconds: Int
    public let idleTimeout: Duration
    public let totalPhysicalMemoryBytes: UInt64
    public let activeProcessorCount: Int
    public let sessionTimeouts: PikafishSessionTimeouts
    /// Environment passed to the helper process (tests inject fake scenarios;
    /// production keeps this empty).
    public let sessionEnvironment: [String: String]

    public init(
      candidateCount: Int = PikafishLimits.maximumCandidates,
      updateIntervalMilliseconds: Int = PikafishResourcePolicy.defaultUIUpdateIntervalMilliseconds,
      idleTimeout: Duration = PikafishResourcePolicy.defaultIdleTimeout,
      totalPhysicalMemoryBytes: UInt64,
      activeProcessorCount: Int,
      sessionTimeouts: PikafishSessionTimeouts = PikafishSessionTimeouts(),
      sessionEnvironment: [String: String] = [:]
    ) {
      self.candidateCount = candidateCount
      self.updateIntervalMilliseconds = min(
        max(updateIntervalMilliseconds, 100), 1_000 / PikafishResourcePolicy.defaultUIUpdateHz)
      self.idleTimeout = idleTimeout
      self.totalPhysicalMemoryBytes = totalPhysicalMemoryBytes
      self.activeProcessorCount = activeProcessorCount
      self.sessionTimeouts = sessionTimeouts
      self.sessionEnvironment = sessionEnvironment
    }
  }

  /// Bounded session timeouts with defaults matching the kit.
  public struct PikafishSessionTimeouts: Sendable {
    public let handshake: Duration
    public let readiness: Duration
    public let terminalWait: Duration
    public let exitWait: Duration

    public init(
      handshake: Duration = PikafishLimits.defaultHandshakeTimeout,
      readiness: Duration = PikafishLimits.defaultReadinessTimeout,
      terminalWait: Duration = PikafishLimits.defaultTerminalWait,
      exitWait: Duration = PikafishLimits.defaultExitWait
    ) {
      self.handshake = handshake
      self.readiness = readiness
      self.terminalWait = terminalWait
      self.exitWait = exitWait
    }
  }

  /// Throttled, typed partial updates for the active request. The stream
  /// buffers only the newest event; each event carries the requestID so
  /// consumers discard stale requests.
  public let updates: AsyncStream<NativeXiangqiAnalysisUpdate>

  private let configuration: Configuration
  private let assets: NativeXiangqiVerifiedEngineDescriptor?
  private let cache: AnalysisCache?
  private var session: PikafishSession?
  private var updatesContinuation: AsyncStream<NativeXiangqiAnalysisUpdate>.Continuation?
  private var updatesFinished = false
  private var sessionUpdatesTask: Task<Void, Never>?
  private var activeRequestID: UUID?
  private var activeSessionGeneration: UInt64?
  private var activeSearchTask: Task<PikafishSearchResult, Error>?
  private var pendingCandidates: [PikafishCandidate]?
  private var flushTask: Task<Void, Never>?
  private var idleTask: Task<Void, Never>?
  private var restartTimestamps: [ContinuousClock.Instant] = []
  private var isWindowVisible = true
  private var lowPower = false
  private var memoryPressure = false
  private var downgradedPreset: PikafishResourcePreset?

  public init(
    configuration: Configuration,
    assets: NativeXiangqiVerifiedEngineDescriptor?,
    cache: AnalysisCache?
  ) {
    self.configuration = configuration
    self.assets = assets
    self.cache = cache
    var captured: AsyncStream<NativeXiangqiAnalysisUpdate>.Continuation?
    let stream = AsyncStream<NativeXiangqiAnalysisUpdate>(
      bufferingPolicy: .bufferingNewest(1)
    ) { continuation in
      captured = continuation
    }
    updatesContinuation = captured
    updates = stream
  }

  // MARK: - Public operations

  /// Whether verified engine assets are available. Documents stay fully
  /// editable when this is false.
  public nonisolated var isEngineAvailable: Bool {
    assets != nil
  }

  /// Runs one search for one request. Concurrent requests cancel the previous
  /// one (the previous caller observes a normal terminal and discards it via
  /// its own generation). Bounded by the request budget plus terminal wait.
  public func search(_ request: NativeXiangqiAnalysisRequest) async throws
    -> PikafishSearchResult
  {
    guard let assets else {
      throw NativeXiangqiAnalysisError.engineUnavailable
    }
    let session = try await ensureSession(assets: assets)
    // Arbitrate: cancel the previous request and wait for its terminal before
    // starting the new one, so the two never interleave inside one session.
    if let previous = activeSearchTask {
      await session.stopSearch()
      _ = await previous.result
    }
    activeRequestID = request.requestID
    // The session increments its generation at search start; updates from this
    // search therefore carry `current + 1`.
    activeSessionGeneration = (await session.searchGeneration) + 1
    try await session.newGame()
    try await session.position(fen: request.identity.initialFEN, moves: request.identity.ucciMoves)
    let task = Task {
      try await session.search(
        limit: PikafishSearchLimit(
          .timeMilliseconds(request.identity.budget.resolvedMilliseconds)))
    }
    activeSearchTask = task
    do {
      let result = try await task.value
      flushPending()
      activeRequestID = nil
      activeSessionGeneration = nil
      activeSearchTask = nil
      scheduleIdleShutdown()
      return result
    } catch {
      activeRequestID = nil
      activeSessionGeneration = nil
      activeSearchTask = nil
      scheduleIdleShutdown()
      throw error
    }
  }

  /// Cancels the active request. The pending `search` call resolves normally
  /// with whatever the engine returns after `stop`; callers discard by
  /// requestID/generation.
  public func cancel(requestID: UUID) async {
    guard activeRequestID == requestID else {
      return
    }
    await session?.stopSearch()
  }

  /// Bounded explicit restart with a rolling hourly limit. UI must call this
  /// and surface the boolean instead of auto-looping.
  public func restartSessionIfAllowed() async -> Bool {
    let now = ContinuousClock.now
    restartTimestamps.removeAll { now - $0 > .seconds(3_600) }
    guard restartTimestamps.count < PikafishResourcePolicy.maximumRestartsPerHour else {
      return false
    }
    guard let session else {
      return false
    }
    do {
      try await session.restart()
      restartTimestamps.append(now)
      try await session.applyPreset(
        effectivePreset(), totalPhysicalMemoryBytes: configuration.totalPhysicalMemoryBytes,
        activeProcessorCount: configuration.activeProcessorCount)
      _ = try await session.configureCandidates(desired: configuration.candidateCount)
      return true
    } catch {
      return false
    }
  }

  // MARK: - Cache

  /// Deterministic persistent cache key for one request identity, bound to the
  /// verified engine commit and network hash.
  public func cacheKey(for identity: NativeXiangqiAnalysisIdentity) async -> Data? {
    guard let assets else {
      return nil
    }
    return AnalysisCacheKey.make(
      from: AnalysisCacheKey.Material(
        initialFEN: identity.initialFEN,
        ucciMoves: identity.ucciMoves,
        profileID: identity.profileID,
        profileVersion: identity.profileVersion,
        positionHash: identity.positionHash,
        repetitionHash: identity.repetitionHash,
        engineCommit: assets.engineCommit,
        networkHash: Data(assets.networkSHA256.utf8),
        presetName: identity.resourcePreset.name,
        budgetKind: identity.budget.kindName,
        budgetMilliseconds: identity.budget.resolvedMilliseconds,
        candidateCount: identity.candidateCount
      )
    )
  }

  public func cacheLookup(key: Data) async -> AnalysisCachePayload? {
    await cache?.lookup(key: key)
  }

  public func cacheStore(
    key: Data,
    result: PikafishValidatedFinalResult,
    budget: PikafishSearchBudget
  ) async throws {
    guard let assets, let cache else {
      return
    }
    try await cache.store(
      key: key,
      validated: result,
      engineCommit: assets.engineCommit,
      networkHash: Data(assets.networkSHA256.utf8),
      budget: budget
    )
  }

  public func cacheSummary() async -> (memoryEntries: Int, diskBytes: Int64)? {
    await cache?.summary()
  }

  // MARK: - Lifecycle policy

  public func noteWindowVisibility(_ visible: Bool) async {
    isWindowVisible = visible
    if !visible {
      await session?.stopSearch()
    }
  }

  public func noteLowPower(_ enabled: Bool) async {
    lowPower = enabled
    if enabled {
      downgradedPreset = .light
    } else if !memoryPressure {
      downgradedPreset = nil
    }
  }

  /// Memory pressure: stop the search, drop long-lived presentation data,
  /// clear the memory LRU, downgrade future presets, and terminate the helper.
  /// The document is never touched.
  public func noteMemoryPressure() async {
    memoryPressure = true
    downgradedPreset = .light
    await session?.stopSearch()
    await cache?.purgeMemory()
    pendingCandidates = nil
    flushTask?.cancel()
    flushTask = nil
    await shutdownSession()
  }

  /// Graceful app-level shutdown. Idempotent.
  public func shutdown() async {
    idleTask?.cancel()
    idleTask = nil
    flushTask?.cancel()
    flushTask = nil
    activeRequestID = nil
    activeSessionGeneration = nil
    await shutdownSession()
    sessionUpdatesTask?.cancel()
    sessionUpdatesTask = nil
    if !updatesFinished {
      updatesFinished = true
      updatesContinuation?.finish()
      updatesContinuation = nil
    }
  }

  // MARK: - Internal

  private func effectivePreset() -> PikafishResourcePreset {
    downgradedPreset ?? .standard
  }

  private func ensureSession(assets: NativeXiangqiVerifiedEngineDescriptor) async throws
    -> PikafishSession
  {
    if let session {
      switch await session.phase {
      case .ready:
        return session
      case .failed:
        do {
          try await session.restart()
        } catch {
          throw NativeXiangqiAnalysisError.sessionFailure("restart failed")
        }
        return session
      default:
        await session.shutdown()
      }
    }
    let session = PikafishSession(
      configuration: PikafishConfiguration(
        executableURL: assets.helperURL,
        environment: configuration.sessionEnvironment,
        handshakeTimeout: configuration.sessionTimeouts.handshake,
        readinessTimeout: configuration.sessionTimeouts.readiness,
        terminalWait: configuration.sessionTimeouts.terminalWait,
        exitWait: configuration.sessionTimeouts.exitWait
      )
    )
    do {
      try await session.start()
    } catch {
      throw NativeXiangqiAnalysisError.sessionFailure("\(error.localizedDescription)")
    }
    try await session.applyPreset(
      effectivePreset(), totalPhysicalMemoryBytes: configuration.totalPhysicalMemoryBytes,
      activeProcessorCount: configuration.activeProcessorCount)
    _ = try await session.configureCandidates(desired: configuration.candidateCount)
    self.session = session
    subscribe(to: session)
    return session
  }

  private func subscribe(to session: PikafishSession) {
    sessionUpdatesTask?.cancel()
    sessionUpdatesTask = Task { [weak self] in
      for await update in await session.searchUpdates {
        guard let self else {
          return
        }
        await self.receive(update)
      }
    }
  }

  private func receive(_ update: PikafishSearchUpdate) {
    guard activeRequestID != nil, update.generation == activeSessionGeneration else {
      return
    }
    pendingCandidates = update.candidates
    if flushTask == nil {
      flushTask = Task { [weak self] in
        try? await Task.sleep(
          for: .milliseconds((self?.configuration.updateIntervalMilliseconds) ?? 200))
        guard !Task.isCancelled else {
          return
        }
        await self?.flushPending()
      }
    }
  }

  private func flushPending() {
    guard activeRequestID != nil, !updatesFinished else {
      return
    }
    guard let pending = pendingCandidates, let requestID = activeRequestID else {
      return
    }
    pendingCandidates = nil
    flushTask?.cancel()
    flushTask = nil
    updatesContinuation?.yield(
      NativeXiangqiAnalysisUpdate(requestID: requestID, candidates: pending))
  }

  private func scheduleIdleShutdown() {
    idleTask?.cancel()
    idleTask = Task { [weak self] in
      try? await Task.sleep(for: (self?.configuration.idleTimeout) ?? .seconds(180))
      guard !Task.isCancelled else {
        return
      }
      await self?.shutdownSessionIfIdle()
    }
  }

  private func shutdownSessionIfIdle() {
    guard activeRequestID == nil else {
      return
    }
    Task {
      await shutdownSession()
    }
  }

  private func shutdownSession() async {
    guard let session else {
      return
    }
    await session.shutdown()
    self.session = nil
    sessionUpdatesTask?.cancel()
    sessionUpdatesTask = nil
  }
}
