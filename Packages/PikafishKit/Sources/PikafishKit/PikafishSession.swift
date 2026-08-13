//! Process-isolated, typed UCI session for the pinned Pikafish helper.
//!
//! The session owns one `Process`, bounded pipes, a strict phase machine, and
//! the full command vocabulary (uci/isready/ucinewgame/position/go/stop/quit).
//! Raw engine output never leaves this module: UI code receives typed info and
//! bestmove values. Every search has a generation, a deadline, a cancellation
//! path, bounded output, and exactly one terminal result or typed failure.

import Foundation

/// Launch configuration for one helper process. The executable URL and any
/// environment values are supplied by the caller (the app resolves the helper
/// from its bundle); nothing user-supplied is ever interpolated.
public struct PikafishConfiguration: Sendable {
  public let executableURL: URL
  public let environment: [String: String]
  public let handshakeTimeout: Duration
  public let readinessTimeout: Duration
  public let terminalWait: Duration
  public let exitWait: Duration
  public let maximumRestartAttempts: Int

  public init(
    executableURL: URL,
    environment: [String: String] = [:],
    handshakeTimeout: Duration = PikafishLimits.defaultHandshakeTimeout,
    readinessTimeout: Duration = PikafishLimits.defaultReadinessTimeout,
    terminalWait: Duration = PikafishLimits.defaultTerminalWait,
    exitWait: Duration = PikafishLimits.defaultExitWait,
    maximumRestartAttempts: Int = PikafishLimits.maximumRestartAttempts
  ) {
    self.executableURL = executableURL
    self.environment = environment
    self.handshakeTimeout = handshakeTimeout
    self.readinessTimeout = readinessTimeout
    self.terminalWait = terminalWait
    self.exitWait = exitWait
    self.maximumRestartAttempts = maximumRestartAttempts
  }
}

/// A whitelist preset mapping engine-option names to bounded values. Presets
/// are the only way the session changes options; arbitrary setoption strings
/// are never accepted.
public struct PikafishPreset: Sendable {
  public let name: String
  let options: [(name: String, value: String)]
}

/// Bounded, tested presets. `deep` is intended only for an explicit user
/// request and still caps Hash/Threads far below the engine maxima.
public enum PikafishPresets {
  public static let light = PikafishPreset(
    name: "light",
    options: [("Hash", "16"), ("Threads", "1"), ("Ponder", "false")]
  )

  public static func standard(
    totalPhysicalMemoryBytes: UInt64,
    activeProcessorCount: Int
  ) -> PikafishPreset {
    let hash = totalPhysicalMemoryBytes >= 16_000_000_000 ? "64" : "32"
    let threads = activeProcessorCount >= 4 ? "2" : "1"
    return PikafishPreset(
      name: "standard",
      options: [("Hash", hash), ("Threads", threads), ("Ponder", "false")]
    )
  }

  public static let deep = PikafishPreset(
    name: "deep",
    options: [("Hash", "128"), ("Threads", "4"), ("Ponder", "false")]
  )
}

public actor PikafishSession {
  public enum Phase: Sendable, Equatable {
    case idle
    case launching
    case handshaking
    case ready
    case searching
    case stopping
    case shuttingDown
    case failed
    case closed
  }

  public private(set) var phase: Phase = .idle
  public private(set) var discoveredOptions: [PikafishOption] = []
  public private(set) var idName: String?
  public private(set) var idAuthor: String?
  public private(set) var diagnosticCount = 0
  public private(set) var launchCount = 0

  private let configuration: PikafishConfiguration
  private var process: Process?
  private var stdinPipe: Pipe?
  private var stdoutPipe: Pipe?
  private var stderrPipe: Pipe?
  private var stdinHandle: FileHandle?
  private var stdoutHandle: FileHandle?
  private var stderrHandle: FileHandle?
  private var outcomeTask: Task<Void, Never>?
  private var handshakeTimeoutTask: Task<Void, Never>?
  private var readinessTimeoutTask: Task<Void, Never>?
  private var searchDeadlineTask: Task<Void, Never>?
  private var terminalWaitTask: Task<Void, Never>?
  private var stdoutTruncatedLines = 0
  private var stdoutOverflows = 0
  private var stdoutTotalLineBytes = 0
  private var stderrTotalLineBytes = 0
  private var searchGeneration: UInt64 = 0
  private var pendingCommandCount = 0
  private var terminationStatus: Int32?
  private var searchContinuation: CheckedContinuation<PikafishSearchResult, Error>?
  private var handshakeContinuation: CheckedContinuation<Void, Error>?
  private var readinessContinuation: CheckedContinuation<Void, Error>?
  private var readinessPending = false
  private var exitContinuation: CheckedContinuation<Int32?, Never>?
  private var exitWaitToken: UUID?
  private var exitTimeoutTask: Task<Void, Never>?
  private var lastInfo: PikafishInfo?
  private var searchStart = ContinuousClock.now
  private var searchInfoLineCount = 0
  private var handshakeLineCount = 0
  private var timeoutCount = 0

  public init(configuration: PikafishConfiguration) {
    self.configuration = configuration
  }

  // MARK: - Lifecycle

  /// Launches the helper and performs the full UCI handshake plus readiness
  /// probe. Bounded by line count and timeouts; any failure terminates the
  /// process and leaves the session in `.failed`.
  public func start() async throws {
    try transition(to: .launching)
    do {
      try await launchProcess()
      try await performHandshake()
      // The handshake is complete; route subsequent lines (readyok, info,
      // bestmove) through the ready-phase parser before probing readiness.
      try transition(to: .ready)
      try await confirmReadiness()
    } catch {
      await forceTerminateIfRunning()
      phase = .failed
      throw error
    }
  }

  /// Restarts a failed session with a bounded number of attempts.
  public func restart() async throws {
    guard phase == .failed else {
      throw PikafishSessionError.invalidState(expected: "failed", actual: phaseName(phase))
    }
    var attempt = 0
    while attempt < configuration.maximumRestartAttempts {
      attempt += 1
      await teardownProcess()
      phase = .idle
      discoveredOptions = []
      idName = nil
      idAuthor = nil
      do {
        try await start()
        return
      } catch {
        phase = .failed
      }
    }
    throw PikafishSessionError.restartAttemptsExhausted
  }

  /// Graceful shutdown: stop any search, send quit, wait for a bounded exit,
  /// then terminate and close pipes as a fallback.
  public func shutdown() async {
    guard phase != .closed, phase != .idle else {
      phase = .closed
      return
    }
    let pendingGeneration = searchContinuation == nil ? nil : searchGeneration
    phase = .shuttingDown
    if let pendingGeneration, let continuation = searchContinuation {
      searchContinuation = nil
      cancelSearchTimers()
      continuation.resume(
        throwing: PikafishSessionError.searchCancelled(generation: pendingGeneration))
    }
    if process?.isRunning == true {
      sendCommand("stop")
      sendCommand("quit")
      if let status = await waitForExit(timeout: configuration.exitWait) {
        terminationStatus = status
      } else {
        timeoutCount += 1
        process?.terminate()
        _ = await waitForExit(timeout: configuration.exitWait)
      }
    }
    await teardownProcess()
    phase = .closed
  }

  // MARK: - Session commands

  /// Applies a whitelist preset. Every option must be advertised by the engine
  /// and every value must lie inside the advertised range; a single violation
  /// fails the whole preset without sending a partial setoption sequence.
  public func applyPreset(_ preset: PikafishPreset) throws {
    guard phase == .ready else {
      throw PikafishSessionError.invalidState(expected: "ready", actual: phaseName(phase))
    }
    for (name, value) in preset.options {
      guard let option = discoveredOptions.first(where: { $0.name == name }) else {
        throw PikafishSessionError.optionNotAdvertised(name)
      }
      try validateOptionValue(option, value: value)
    }
    for (name, value) in preset.options {
      sendCommand("setoption name \(name) value \(value)")
    }
  }

  /// Starts a new game: `ucinewgame` followed by a bounded readiness probe.
  public func newGame() async throws {
    guard phase == .ready else {
      throw PikafishSessionError.invalidState(expected: "ready", actual: phaseName(phase))
    }
    sendCommand("ucinewgame")
    try await confirmReadiness()
  }

  /// Sets the position from a bounded FEN plus syntactically validated UCCI
  /// moves. Full legality remains the Rust core's authority; this is syntax
  /// only. When `moves` is empty the plain `position fen <fen>` form is sent.
  public func position(fen: String, moves: [String] = []) throws {
    guard phase == .ready else {
      throw PikafishSessionError.invalidState(expected: "ready", actual: phaseName(phase))
    }
    guard fen.utf8.count <= PikafishLimits.maximumFENBytes else {
      throw PikafishSessionError.inputTooLong("fen")
    }
    guard moves.count <= PikafishLimits.maximumUCCIMoves else {
      throw PikafishSessionError.inputTooLong("moves")
    }
    for move in moves {
      guard move.utf8.count <= PikafishLimits.maximumMoveTokenBytes,
        PikafishUCI.isValidMoveToken(move)
      else {
        throw PikafishSessionError.malformedPosition
      }
    }
    if moves.isEmpty {
      sendCommand("position fen \(fen)")
    } else {
      sendCommand("position fen \(fen) moves \(moves.joined(separator: " "))")
    }
  }

  /// Runs one bounded search and waits for its single terminal result. The
  /// result is generation-checked: late or stale bestmove lines can never be
  /// attributed to a newer search.
  public func search(limit: PikafishSearchLimit) async throws -> PikafishSearchResult {
    guard phase == .ready else {
      throw PikafishSessionError.invalidState(expected: "ready", actual: phaseName(phase))
    }
    searchGeneration &+= 1
    let generation = searchGeneration
    lastInfo = nil
    searchInfoLineCount = 0
    searchStart = ContinuousClock.now
    phase = .searching

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<PikafishSearchResult, Error>) in
        searchContinuation = continuation
        sendCommand("go \(limit.uciSuffix)")
        searchDeadlineTask = Task { [weak self] in
          guard let self else {
            return
          }
          try? await Task.sleep(for: self.searchDeadline(for: limit))
          guard !Task.isCancelled else {
            return
          }
          await self.handleSearchDeadline(generation: generation)
        }
      }
    } onCancel: { [weak self] in
      Task {
        await self?.cancelSearch(generation: generation)
      }
    }
  }

  /// Requests an early stop of the current search. The pending `search()` call
  /// resolves with its bestmove (when the engine honors stop quickly) or a
  /// typed cancellation error after the bounded terminal wait.
  public func stopSearch() async {
    guard phase == .searching else {
      return
    }
    let generation = searchGeneration
    phase = .stopping
    sendCommand("stop")
    terminalWaitTask?.cancel()
    terminalWaitTask = Task { [weak self] in
      try? await Task.sleep(
        for: self?.configuration.terminalWait ?? PikafishLimits.defaultTerminalWait)
      guard !Task.isCancelled else {
        return
      }
      await self?.handleTerminalWait(generation: generation, cancelled: true)
    }
  }

  private func cancelSearch(generation: UInt64) {
    guard phase == .searching, generation == searchGeneration else {
      return
    }
    phase = .stopping
    sendCommand("stop")
    terminalWaitTask?.cancel()
    terminalWaitTask = Task { [weak self] in
      try? await Task.sleep(
        for: self?.configuration.terminalWait ?? PikafishLimits.defaultTerminalWait)
      guard !Task.isCancelled else {
        return
      }
      await self?.handleTerminalWait(generation: generation, cancelled: true)
    }
  }

  // MARK: - Diagnostics

  /// Bounded, non-sensitive session summary for status UI. Never includes
  /// engine output, FENs, PVs, or user paths.
  public func summary() -> PikafishSessionSummary {
    PikafishSessionSummary(
      phase: phase,
      idName: idName,
      launchCount: launchCount,
      optionCount: discoveredOptions.count,
      diagnosticCount: diagnosticCount,
      timeouts: timeoutCount
    )
  }

  public func outputReaderDiagnostics() async
    -> (stdout: PikafishOutputReaderDiagnostics, stderr: PikafishOutputReaderDiagnostics)
  {
    (
      PikafishOutputReaderDiagnostics(
        truncatedLines: stdoutTruncatedLines,
        overflows: stdoutOverflows,
        totalLineBytes: stdoutTotalLineBytes
      ),
      PikafishOutputReaderDiagnostics(
        truncatedLines: 0,
        overflows: 0,
        totalLineBytes: stderrTotalLineBytes
      )
    )
  }

  // MARK: - Internal: launch and handshake

  private func searchDeadline(for limit: PikafishSearchLimit) -> Duration {
    switch limit.kind {
    case .timeMilliseconds(let milliseconds):
      return .milliseconds(Int64(milliseconds)) + configuration.terminalWait
    case .nodes, .depth:
      let waitMilliseconds =
        configuration.terminalWait.components.seconds * 1_000
        + configuration.terminalWait.components.attoseconds / 1_000_000_000_000_000
      return .milliseconds(waitMilliseconds * 8)
    }
  }

  private func launchProcess() async throws {
    let process = Process()
    process.executableURL = configuration.executableURL
    process.arguments = []
    if !configuration.environment.isEmpty {
      process.environment = configuration.environment
    }
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    // Retain the Pipe objects for the process lifetime: Process takes their
    // file handles, and releasing the pipes would close the descriptors the
    // readers and writer below depend on.
    stdinPipe = stdin
    stdoutPipe = stdout
    stderrPipe = stderr
    process.terminationHandler = { [weak self] completed in
      let status = completed.terminationStatus
      Task {
        await self?.handleProcessExit(status: status)
      }
    }
    do {
      try process.run()
    } catch {
      throw PikafishSessionError.launchFailed
    }
    self.process = process
    launchCount += 1
    stdinHandle = stdin.fileHandleForWriting
    stdoutHandle = stdout.fileHandleForReading
    stderrHandle = stderr.fileHandleForReading
    // The drain tasks run unisolated so a blocking pipe read can never freeze
    // the session actor or the main actor.
    outcomeTask = Self.spawnDrains(
      stdout: stdout.fileHandleForReading,
      stderr: stderr.fileHandleForReading,
      session: self
    )
  }

  private nonisolated static func spawnDrains(
    stdout: FileHandle,
    stderr: FileHandle,
    session: PikafishSession
  ) -> Task<Void, Never> {
    Task {
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          await drain(handle: stdout, isStderr: false, session: session)
        }
        group.addTask {
          await drain(handle: stderr, isStderr: true, session: session)
        }
        await group.waitForAll()
      }
    }
  }

  /// Raw, bounded line reader for one engine pipe. Runs on a cooperative
  /// thread; each complete line hops to the session actor for routing.
  private nonisolated static func drain(
    handle: FileHandle,
    isStderr: Bool,
    session: PikafishSession
  ) async {
    var pending = Data()
    let maximumLineBytes = PikafishLimits.maximumLineBytes
    let maximumPendingBytes =
      isStderr ? PikafishLimits.maximumStderrBytes : PikafishLimits.maximumPendingBufferBytes
    while !Task.isCancelled {
      var buffer = [UInt8](repeating: 0, count: 4_096)
      let count = buffer.withUnsafeMutableBytes { raw -> Int in
        Darwin.read(handle.fileDescriptor, raw.baseAddress, raw.count)
      }
      if count < 0 {
        if errno == EINTR || errno == EAGAIN {
          continue
        }
        await session.handleReadFailure()
        return
      }
      if count == 0 {
        return
      }
      pending.append(Data(bytes: buffer, count: count))
      if pending.count > maximumPendingBytes {
        await session.recordOverflow(isStderr: isStderr)
        if let newline = pending.firstIndex(of: 0x0A) {
          pending.removeSubrange(0...newline)
        } else {
          pending.removeAll(keepingCapacity: true)
        }
      }
      while let newline = pending.firstIndex(of: 0x0A) {
        var lineData = pending[0..<newline]
        pending.removeSubrange(0...newline)
        if lineData.last == 0x0D {
          lineData = lineData.dropLast()
        }
        let byteCount = lineData.count
        await session.recordLineBytes(byteCount, isStderr: isStderr)
        if byteCount > maximumLineBytes {
          await session.recordTruncatedLine(isStderr: isStderr)
          guard let text = String(data: Data(lineData.prefix(maximumLineBytes)), encoding: .utf8)
          else {
            continue
          }
          await session.handleLineText(text, isStderr: isStderr)
        } else {
          guard let text = String(data: Data(lineData), encoding: .utf8) else {
            continue
          }
          await session.handleLineText(text, isStderr: isStderr)
        }
      }
    }
  }

  private func performHandshake() async throws {
    phase = .handshaking
    handshakeLineCount = 0
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      handshakeContinuation = continuation
      sendCommand("uci")
      handshakeTimeoutTask = Task { [weak self] in
        try? await Task.sleep(
          for: self?.configuration.handshakeTimeout ?? PikafishLimits.defaultHandshakeTimeout)
        guard !Task.isCancelled else {
          return
        }
        await self?.handleHandshakeTimeout()
      }
    }
  }

  private func handleHandshakeTimeout() {
    guard phase == .handshaking else {
      return
    }
    timeoutCount += 1
    finishHandshake(throwing: PikafishSessionError.handshakeTimeout)
  }

  private func finishHandshake(throwing error: Error? = nil) {
    guard let continuation = handshakeContinuation else {
      return
    }
    handshakeContinuation = nil
    handshakeTimeoutTask?.cancel()
    handshakeTimeoutTask = nil
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
    }
  }

  private func confirmReadiness() async throws {
    guard phase == .ready || phase == .handshaking, !readinessPending else {
      throw PikafishSessionError.invalidState(
        expected: "ready or handshaking", actual: phaseName(phase))
    }
    readinessPending = true
    readinessTimeoutTask?.cancel()
    readinessTimeoutTask = Task { [weak self] in
      try? await Task.sleep(
        for: self?.configuration.readinessTimeout ?? PikafishLimits.defaultReadinessTimeout)
      guard !Task.isCancelled else {
        return
      }
      await self?.handleReadinessTimeout()
    }
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      readinessContinuation = continuation
      sendCommand("isready")
    }
  }

  private func handleReadinessTimeout() {
    guard readinessPending, phase == .handshaking || phase == .ready else {
      return
    }
    timeoutCount += 1
    finishReadiness(throwing: PikafishSessionError.readinessTimeout)
  }

  private func finishReadiness(throwing error: Error? = nil) {
    guard let continuation = readinessContinuation else {
      return
    }
    readinessContinuation = nil
    readinessPending = false
    readinessTimeoutTask?.cancel()
    readinessTimeoutTask = nil
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
    }
  }

  // MARK: - Internal: output routing

  private func recordOverflow(isStderr: Bool) {
    if isStderr {
      stderrTotalLineBytes = min(
        stderrTotalLineBytes + PikafishLimits.maximumStderrBytes,
        Int.max - PikafishLimits.maximumStderrBytes
      )
    } else {
      stdoutOverflows += 1
    }
    recordDiagnostic()
  }

  private func recordTruncatedLine(isStderr: Bool) {
    if !isStderr {
      stdoutTruncatedLines += 1
    }
    recordDiagnostic()
  }

  private func recordLineBytes(_ byteCount: Int, isStderr: Bool) {
    if isStderr {
      stderrTotalLineBytes += min(byteCount, PikafishLimits.maximumLineBytes)
    } else {
      stdoutTotalLineBytes += min(byteCount, PikafishLimits.maximumLineBytes)
    }
  }

  private func handleLineText(_ text: String, isStderr: Bool) {
    if isStderr {
      recordDiagnostic()
      return
    }
    if !text.isEmpty {
      handleLine(text)
    }
  }

  private func handleReadFailure() {
    recordDiagnostic()
    guard phase != .idle, phase != .closed, phase != .shuttingDown, phase != .failed else {
      return
    }
    phase = .failed
    finishHandshake(throwing: PikafishSessionError.ioFailure)
    finishReadiness(throwing: PikafishSessionError.ioFailure)
    finishSearch(failing: PikafishSessionError.ioFailure)
  }

  private func recordDiagnostic() {
    if diagnosticCount < PikafishLimits.maximumDiagnostics {
      diagnosticCount += 1
    }
  }

  private func handleLine(_ line: String) {
    let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
    guard let first = tokens.first else {
      return
    }
    switch phase {
    case .handshaking:
      handshakeLineCount += 1
      guard handshakeLineCount <= PikafishLimits.maximumHandshakeLines else {
        finishHandshake(throwing: PikafishSessionError.handshakeTooManyLines)
        return
      }
      switch first {
      case "id":
        if tokens.count >= 3, tokens[1] == "name" {
          idName = tokens.dropFirst(2).joined(separator: " ")
        } else if tokens.count >= 3, tokens[1] == "author" {
          idAuthor = tokens.dropFirst(2).joined(separator: " ")
        }
      case "option":
        if let option = PikafishUCI.parseOption(tokens) {
          discoveredOptions.removeAll { $0.name == option.name }
          discoveredOptions.append(option)
        } else {
          recordDiagnostic()
        }
      case "uciok":
        finishHandshake()
      case "info", "string":
        break
      default:
        recordDiagnostic()
      }
    case .ready, .searching, .stopping:
      switch first {
      case "info":
        if phase == .searching || phase == .stopping {
          if searchInfoLineCount < PikafishLimits.maximumSearchInfoLines {
            searchInfoLineCount += 1
          } else {
            recordDiagnostic()
          }
          if let info = PikafishUCI.parseInfo(tokens) {
            lastInfo = info
          }
        }
      case "bestmove":
        if phase == .searching || phase == .stopping {
          do {
            guard let bestMove = try PikafishUCI.parseBestMove(tokens) else {
              recordDiagnostic()
              return
            }
            finishSearch(bestMove: bestMove)
          } catch {
            finishSearch(failing: error)
          }
        }
      case "readyok":
        finishReadiness()
      default:
        recordDiagnostic()
      }
    case .launching, .idle, .failed, .closed, .shuttingDown:
      if first == "readyok" {
        finishReadiness()
      } else {
        recordDiagnostic()
      }
    }
  }

  // MARK: - Internal: search terminal

  private func finishSearch(bestMove: PikafishBestMove, failing: Error? = nil) {
    guard let continuation = searchContinuation else {
      return
    }
    searchContinuation = nil
    cancelSearchTimers()
    if let failing {
      phase = .failed
      continuation.resume(throwing: failing)
      return
    }
    let elapsed = elapsedMillisecondsSinceSearchStart()
    let result = PikafishSearchResult(
      generation: searchGeneration,
      bestMove: bestMove,
      finalInfo: lastInfo,
      elapsedMilliseconds: elapsed
    )
    phase = .ready
    continuation.resume(returning: result)
  }

  private func finishSearch(failing error: Error) {
    finishSearch(bestMove: PikafishBestMove(move: nil, ponder: nil), failing: error)
  }

  private func elapsedMillisecondsSinceSearchStart() -> Int {
    let elapsed = ContinuousClock.now - searchStart
    return Int(elapsed.components.seconds) * 1_000
      + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
  }

  private func handleSearchDeadline(generation: UInt64) {
    guard phase == .searching, generation == searchGeneration else {
      return
    }
    timeoutCount += 1
    phase = .stopping
    sendCommand("stop")
    searchDeadlineTask = nil
    terminalWaitTask?.cancel()
    terminalWaitTask = Task { [weak self] in
      try? await Task.sleep(
        for: self?.configuration.terminalWait ?? PikafishLimits.defaultTerminalWait)
      guard !Task.isCancelled else {
        return
      }
      await self?.handleTerminalWait(generation: generation, cancelled: false)
    }
  }

  private func handleTerminalWait(generation: UInt64, cancelled: Bool) {
    guard phase == .stopping, generation == searchGeneration else {
      return
    }
    let error: PikafishSessionError =
      cancelled
      ? .searchCancelled(generation: generation)
      : .searchDeadlineExceeded(generation: generation)
    cancelSearchTimers()
    if let continuation = searchContinuation {
      searchContinuation = nil
      phase = .failed
      continuation.resume(throwing: error)
    } else {
      phase = .failed
    }
    process?.terminate()
  }

  private func handleProcessExit(status: Int32) {
    terminationStatus = status
    if let exitContinuation {
      self.exitContinuation = nil
      exitContinuation.resume(returning: status)
      return
    }
    guard phase != .idle, phase != .closed, phase != .shuttingDown, phase != .failed else {
      return
    }
    let error: PikafishSessionError =
      status == 0
      ? .engineExited(terminationStatus: status) : .engineCrashed(terminationStatus: status)
    if phase == .handshaking {
      phase = .failed
      finishHandshake(throwing: error)
    } else if readinessPending {
      phase = .failed
      finishReadiness(throwing: error)
    } else if let continuation = searchContinuation {
      searchContinuation = nil
      cancelSearchTimers()
      phase = .failed
      continuation.resume(throwing: error)
    } else {
      phase = .failed
    }
  }

  private func waitForExit(timeout: Duration) async -> Int32? {
    if let terminationStatus {
      return terminationStatus
    }
    let token = UUID()
    return await withCheckedContinuation {
      (continuation: CheckedContinuation<Int32?, Never>) in
      exitWaitToken = token
      exitContinuation = continuation
      let timeoutTask = Task { [weak self] in
        try? await Task.sleep(for: timeout)
        await self?.handleExitTimeout(token: token)
      }
      exitTimeoutTask = timeoutTask
    }
  }

  private func handleExitTimeout(token: UUID) {
    guard exitWaitToken == token, let continuation = exitContinuation else {
      return
    }
    exitContinuation = nil
    continuation.resume(returning: nil)
  }

  private func forceTerminateIfRunning() async {
    guard let process, process.isRunning else {
      return
    }
    process.terminate()
    _ = await waitForExit(timeout: configuration.exitWait)
  }

  private func teardownProcess() async {
    handshakeTimeoutTask?.cancel()
    handshakeTimeoutTask = nil
    readinessTimeoutTask?.cancel()
    readinessTimeoutTask = nil
    cancelSearchTimers()
    exitTimeoutTask?.cancel()
    exitTimeoutTask = nil
    outcomeTask?.cancel()
    outcomeTask = nil
    try? stdinHandle?.close()
    try? stdoutHandle?.close()
    try? stderrHandle?.close()
    stdinHandle = nil
    stdoutHandle = nil
    stderrHandle = nil
    stdinPipe = nil
    stdoutPipe = nil
    stderrPipe = nil
    process = nil
    terminationStatus = nil
    searchContinuation = nil
    handshakeContinuation = nil
    readinessContinuation = nil
    readinessPending = false
    pendingCommandCount = 0
  }

  // MARK: - Internal: command writing and validation

  private func sendCommand(_ command: String) {
    guard let stdinHandle else {
      return
    }
    guard command.utf8.count <= PikafishLimits.maximumLineBytes * 16 else {
      recordDiagnostic()
      return
    }
    guard pendingCommandCount < PikafishLimits.maximumPendingCommands else {
      recordDiagnostic()
      return
    }
    pendingCommandCount += 1
    do {
      try stdinHandle.write(contentsOf: Data((command + "\n").utf8))
    } catch {
      recordDiagnostic()
    }
    pendingCommandCount -= 1
  }

  private func validateOptionValue(_ option: PikafishOption, value: String) throws {
    guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
      throw PikafishSessionError.malformedOptionValue(option.name)
    }
    switch option.kind {
    case .check:
      guard value == "true" || value == "false" else {
        throw PikafishSessionError.invalidState(expected: "boolean option value", actual: value)
      }
    case .spin:
      guard let number = Int(value) else {
        throw PikafishSessionError.invalidState(expected: "numeric option value", actual: value)
      }
      if let min = option.min, let max = option.max {
        guard number >= min, number <= max else {
          throw PikafishSessionError.optionValueOutOfRange(
            name: option.name, value: number, min: min, max: max)
        }
      }
    case .combo:
      guard option.variables.contains(value) else {
        throw PikafishSessionError.optionValueOutOfRange(
          name: option.name, value: 0, min: 0, max: 0)
      }
    case .string:
      guard value.utf8.count <= 512 else {
        throw PikafishSessionError.inputTooLong(option.name)
      }
    case .button, .unknown:
      throw PikafishSessionError.unknownOptionKind(option.name)
    }
  }

  private func cancelSearchTimers() {
    searchDeadlineTask?.cancel()
    searchDeadlineTask = nil
    terminalWaitTask?.cancel()
    terminalWaitTask = nil
  }

  private func transition(to target: Phase) throws {
    let allowed: Bool
    switch (phase, target) {
    case (.idle, .launching), (.launching, .handshaking), (.handshaking, .ready),
      (.ready, .searching), (.searching, .stopping), (.stopping, .ready),
      (.stopping, .failed), (.searching, .failed), (.handshaking, .failed),
      (.ready, .shuttingDown), (.searching, .shuttingDown), (.stopping, .shuttingDown),
      (.shuttingDown, .closed), (.failed, .idle), (.idle, .closed),
      (.failed, .closed):
      allowed = true
    default:
      allowed = false
    }
    guard allowed else {
      throw PikafishSessionError.invalidState(expected: phaseName(phase), actual: phaseName(target))
    }
    phase = target
  }

  private func phaseName(_ phase: Phase) -> String {
    switch phase {
    case .idle: "idle"
    case .launching: "launching"
    case .handshaking: "handshaking"
    case .ready: "ready"
    case .searching: "searching"
    case .stopping: "stopping"
    case .shuttingDown: "shuttingDown"
    case .failed: "failed"
    case .closed: "closed"
    }
  }
}

/// A non-sensitive summary of session state for status UI and diagnostics.
public struct PikafishSessionSummary: Sendable, Equatable {
  public let phase: PikafishSession.Phase
  public let idName: String?
  public let launchCount: Int
  public let optionCount: Int
  public let diagnosticCount: Int
  public let timeouts: Int

  public init(
    phase: PikafishSession.Phase,
    idName: String?,
    launchCount: Int,
    optionCount: Int,
    diagnosticCount: Int,
    timeouts: Int
  ) {
    self.phase = phase
    self.idName = idName
    self.launchCount = launchCount
    self.optionCount = optionCount
    self.diagnosticCount = diagnosticCount
    self.timeouts = timeouts
  }
}

/// Bounded reader diagnostics for one pipe.
public struct PikafishOutputReaderDiagnostics: Sendable, Equatable {
  public let truncatedLines: Int
  public let overflows: Int
  public let totalLineBytes: Int

  public init(truncatedLines: Int = 0, overflows: Int = 0, totalLineBytes: Int = 0) {
    self.truncatedLines = truncatedLines
    self.overflows = overflows
    self.totalLineBytes = totalLineBytes
  }
}
