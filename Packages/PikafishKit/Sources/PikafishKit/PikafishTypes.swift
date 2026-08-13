//! Typed Pikafish results, options, and bounded limits.
//!
//! This module is the only place where raw UCI lines are decoded into values.
//! UI code never sees raw engine output. Numbers are validated and bounded;
//! unknown tokens are ignored with low-frequency diagnostics at the session
//! layer.

import Foundation

/// The canonical red/black perspective used for score conversion. PikafishKit
/// deliberately defines its own side type instead of depending on presentation
/// packages; the UI maps it to its own board-side type explicitly.
public enum PikafishSide: UInt8, Sendable, Equatable {
  case red = 0
  case black = 1
}

/// A bounded, typed evaluation score. The raw unit is preserved exactly as the
/// engine reported it (`cp` centipawn or `mate` plies); perspective conversion
/// is an explicit, tested operation and never mutates the raw value.
public enum PikafishScoreKind: Sendable, Equatable {
  case centipawn(Int)
  /// Positive values mean the side to move mates; negative mean the side to
  /// move is mated. The absolute value is the number of plies to mate.
  case mate(Int)
}

/// Whether the score is exact or a search bound.
public enum PikafishScoreBound: String, Sendable, Equatable {
  case exact
  case lowerbound
  case upperbound
}

public struct PikafishScore: Sendable, Equatable {
  public let kind: PikafishScoreKind
  public let bound: PikafishScoreBound?

  public init(kind: PikafishScoreKind, bound: PikafishScoreBound? = nil) {
    self.kind = kind
    self.bound = bound
  }

  /// Converts the raw score to a red-perspective centipawn value using the
  /// given side to move. A positive result means Red is better.
  public func centipawnsFromRedPerspective(sideToMove: PikafishSide) -> Int? {
    switch kind {
    case .centipawn(let value):
      return sideToMove == .red ? value : -value
    case .mate:
      return nil
    }
  }

  /// Converts the raw score into a display evaluation for the selected
  /// perspective. Raw values are never mutated; the raw side-to-move meaning is
  /// preserved on the result.
  public func displayed(
    in perspective: PikafishEvaluationPerspective,
    sideToMove: PikafishSide
  ) -> PikafishDisplayedEvaluation {
    switch kind {
    case .centipawn(let value):
      let converted = sideToMove == .red ? value : -value
      return PikafishDisplayedEvaluation(
        centipawnsFromRedPerspective: converted,
        matePly: nil,
        redMates: nil,
        bound: bound,
        perspective: perspective,
        sideToMove: sideToMove
      )
    case .mate(let value):
      // Raw convention: positive means the side to move mates in `value`
      // plies; negative means the side to move is mated in `-value` plies.
      let converted = sideToMove == .red ? value : -value
      return PikafishDisplayedEvaluation(
        centipawnsFromRedPerspective: nil,
        matePly: abs(converted),
        redMates: perspective == .red ? converted > 0 : nil,
        bound: bound,
        perspective: perspective,
        sideToMove: sideToMove
      )
    }
  }
}

/// The perspective a user chooses for displaying evaluations.
public enum PikafishEvaluationPerspective: String, Sendable, Equatable, CaseIterable {
  /// Fixed red-perspective: positive cp means Red is better; positive mate
  /// means Red mates.
  case red
  /// Side-to-move perspective: the raw engine convention is kept.
  case sideToMove
}

/// A display-ready evaluation converted to a fixed perspective. The raw
/// side-to-move meaning remains available for tooltips and diagnostics.
public struct PikafishDisplayedEvaluation: Sendable, Equatable {
  /// Centipawns from the red perspective (positive means Red is better), or
  /// nil for mate scores.
  public let centipawnsFromRedPerspective: Int?
  /// Absolute plies to mate, or nil for centipawn scores. Never rendered as
  /// "turns" without converting plies first.
  public let matePly: Int?
  /// For mate scores in the red perspective: true when Red mates. Nil for
  /// centipawn scores or side-to-move perspective.
  public let redMates: Bool?
  public let bound: PikafishScoreBound?
  public let perspective: PikafishEvaluationPerspective
  public let sideToMove: PikafishSide

  public init(
    centipawnsFromRedPerspective: Int?,
    matePly: Int?,
    redMates: Bool?,
    bound: PikafishScoreBound?,
    perspective: PikafishEvaluationPerspective,
    sideToMove: PikafishSide
  ) {
    self.centipawnsFromRedPerspective = centipawnsFromRedPerspective
    self.matePly = matePly
    self.redMates = redMates
    self.bound = bound
    self.perspective = perspective
    self.sideToMove = sideToMove
  }
}

/// One typed `info` line. All fields are optional because UCI engines emit
/// subsets; every number present here has passed range validation.
public struct PikafishInfo: Sendable, Equatable {
  public let depth: Int?
  public let seldepth: Int?
  public let multipv: Int?
  public let score: PikafishScore?
  public let nodes: Int?
  public let nps: Int?
  public let timeMilliseconds: Int?
  public let hashfull: Int?
  /// Bounded, syntactically validated UCCI coordinate moves (for example
  /// `b2b3`). The full move list is capped at `PikafishLimits.maximumPVMoves`.
  public let pv: [String]

  public init(
    depth: Int? = nil,
    seldepth: Int? = nil,
    multipv: Int? = nil,
    score: PikafishScore? = nil,
    nodes: Int? = nil,
    nps: Int? = nil,
    timeMilliseconds: Int? = nil,
    hashfull: Int? = nil,
    pv: [String] = []
  ) {
    self.depth = depth
    self.seldepth = seldepth
    self.multipv = multipv
    self.score = score
    self.nodes = nodes
    self.nps = nps
    self.timeMilliseconds = timeMilliseconds
    self.hashfull = hashfull
    self.pv = pv
  }
}

/// A parsed `bestmove` line. `move` is nil only for the explicit `(none)`
/// result; a missing or malformed move is a typed failure, never a nil here.
public struct PikafishBestMove: Sendable, Equatable {
  public let move: String?
  public let ponder: String?

  public init(move: String?, ponder: String?) {
    self.move = move
    self.ponder = ponder
  }
}

/// The terminal typed outcome of one search.
public struct PikafishSearchResult: Sendable, Equatable {
  public let generation: UInt64
  public let bestMove: PikafishBestMove
  /// The latest accepted info for rank 1 before the terminal, when one existed.
  public let finalInfo: PikafishInfo?
  /// The latest accepted info per MultiPV rank, sorted by rank, bounded by
  /// `PikafishLimits.maximumCandidates`.
  public let candidates: [PikafishCandidate]
  /// Milliseconds spent waiting for the terminal result.
  public let elapsedMilliseconds: Int

  public init(
    generation: UInt64,
    bestMove: PikafishBestMove,
    finalInfo: PikafishInfo?,
    candidates: [PikafishCandidate] = [],
    elapsedMilliseconds: Int
  ) {
    self.generation = generation
    self.bestMove = bestMove
    self.finalInfo = finalInfo
    self.candidates = candidates
    self.elapsedMilliseconds = elapsedMilliseconds
  }
}

/// One candidate line (one MultiPV rank) with its latest typed info.
public struct PikafishCandidate: Sendable, Equatable {
  public let rank: Int
  public let info: PikafishInfo

  public init(rank: Int, info: PikafishInfo) {
    self.rank = rank
    self.info = info
  }
}

/// A typed partial-update event delivered during a search. The session emits
/// only the newest candidate snapshot per rank; the stream's buffering policy
/// coalesces bursts, so UI consumers never receive one event per raw info line.
public struct PikafishSearchUpdate: Sendable, Equatable {
  public let generation: UInt64
  public let candidates: [PikafishCandidate]
  /// How many info lines were absorbed since the previous update event.
  public let coalescedInfoLines: Int

  public init(
    generation: UInt64,
    candidates: [PikafishCandidate],
    coalescedInfoLines: Int
  ) {
    self.generation = generation
    self.candidates = candidates
    self.coalescedInfoLines = coalescedInfoLines
  }
}

/// A search outcome that has been revalidated by the Rust core. Only these may
/// enter the persistent analysis cache; partial or unvalidated results never
/// do. Construction is restricted to the validation path inside the kit.
public struct PikafishValidatedFinalResult: Sendable, Equatable {
  public let searchGeneration: UInt64
  public let bestMove: PikafishBestMove
  public let candidates: [PikafishCandidate]
  public let elapsedMilliseconds: Int
  /// The raw side to move during the search. Raw evaluations are preserved;
  /// display perspective is applied only at the UI boundary.
  public let sideToMove: PikafishSide

  public init(
    searchGeneration: UInt64,
    bestMove: PikafishBestMove,
    candidates: [PikafishCandidate],
    elapsedMilliseconds: Int,
    sideToMove: PikafishSide
  ) {
    self.searchGeneration = searchGeneration
    self.bestMove = bestMove
    self.candidates = candidates
    self.elapsedMilliseconds = elapsedMilliseconds
    self.sideToMove = sideToMove
  }
}

/// One UCI option advertised by the engine during the handshake.
public struct PikafishOption: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    case check
    case spin
    case combo
    case button
    case string
    case unknown
  }

  public let name: String
  public let kind: Kind
  public let defaultValue: String?
  public let min: Int?
  public let max: Int?
  public let variables: [String]

  public init(
    name: String,
    kind: Kind,
    defaultValue: String? = nil,
    min: Int? = nil,
    max: Int? = nil,
    variables: [String] = []
  ) {
    self.name = name
    self.kind = kind
    self.defaultValue = defaultValue
    self.min = min
    self.max = max
    self.variables = variables
  }
}

/// A resource-bound search limit. Exactly one of the fields is set.
public struct PikafishSearchLimit: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case timeMilliseconds(Int)
    case nodes(Int)
    case depth(Int)
  }

  public let kind: Kind

  public init(_ kind: Kind) {
    self.kind = kind
  }

  public var uciSuffix: String {
    switch kind {
    case .timeMilliseconds(let value): "movetime \(value)"
    case .nodes(let value): "nodes \(value)"
    case .depth(let value): "depth \(value)"
    }
  }
}

/// Validated, bounded search budgets for analysis and human-versus-AI play.
/// Fixed budgets are used for interactive analysis; time-aware budgets derive
/// a safe `movetime` from caller-provided remaining time and Fischer increment
/// without implementing a clock, a timer, or any timeout adjudication.
public struct PikafishSearchBudget: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    /// A fixed, validated `movetime` in milliseconds.
    case fixedMilliseconds(Int)
    /// Derive a budget from remaining time, Fischer increment, and estimated
    /// moves left. All values are validated and the derived budget never
    /// exceeds the remaining time minus a safety reserve.
    case timeAware(remainingMilliseconds: Int, incrementMilliseconds: Int, estimatedMovesLeft: Int)
  }

  public let kind: Kind

  public init(_ kind: Kind) throws {
    switch kind {
    case .fixedMilliseconds(let value):
      guard (1...PikafishLimits.maximumSearchMilliseconds).contains(value) else {
        throw PikafishBudgetError.fixedOutOfBounds(value)
      }
    case .timeAware(
      let remaining, let increment, let movesLeft):
      guard (1...PikafishLimits.maximumSearchMilliseconds).contains(remaining) else {
        throw PikafishBudgetError.remainingOutOfBounds(remaining)
      }
      guard (0...60_000).contains(increment) else {
        throw PikafishBudgetError.incrementOutOfBounds(increment)
      }
      guard (2...120).contains(movesLeft) else {
        throw PikafishBudgetError.movesLeftOutOfBounds(movesLeft)
      }
    }
    self.kind = kind
  }

  /// The derived `movetime` in milliseconds. For time-aware budgets the result
  /// is bounded between 1 ms and the remaining time minus a safety reserve.
  public var resolvedMilliseconds: Int {
    switch kind {
    case .fixedMilliseconds(let value):
      return value
    case .timeAware(let remaining, let increment, let movesLeft):
      return Self.resolveTimeAware(
        remainingMilliseconds: remaining,
        incrementMilliseconds: increment,
        estimatedMovesLeft: movesLeft
      )
    }
  }

  public var uciSuffix: String {
    "movetime \(resolvedMilliseconds)"
  }

  /// Stable kind name for cache identity and diagnostics.
  public var kindName: String {
    switch kind {
    case .fixedMilliseconds:
      return "fixed"
    case .timeAware:
      return "timeAware"
    }
  }

  /// Pure time-aware derivation, independently tested:
  /// - safety reserve is max(1 s, 5 % of remaining);
  /// - with enough time, budget = remaining/movesLeft + increment/2, capped at
  ///   remaining - reserve;
  /// - under critical time the budget collapses to remaining/4 (never 0).
  public static func resolveTimeAware(
    remainingMilliseconds remaining: Int,
    incrementMilliseconds increment: Int,
    estimatedMovesLeft movesLeft: Int
  ) -> Int {
    guard remaining > 0 else {
      return 0
    }
    let reserve = max(1_000, remaining / 20)
    if remaining <= 2 * reserve {
      return max(1, remaining / 4)
    }
    let base = remaining / max(movesLeft, 2)
    let budget = base + increment / 2
    return min(budget, remaining - reserve)
  }
}

/// Typed rejection for invalid budgets. Construction failures never produce a
/// partial or out-of-bounds `go` suffix.
public enum PikafishBudgetError: Error, Sendable, Equatable, LocalizedError {
  case fixedOutOfBounds(Int)
  case remainingOutOfBounds(Int)
  case incrementOutOfBounds(Int)
  case movesLeftOutOfBounds(Int)

  public var errorDescription: String? {
    switch self {
    case .fixedOutOfBounds(let value):
      "固定搜索预算 \(value) ms 超出允许范围。"
    case .remainingOutOfBounds(let value):
      "剩余时间 \(value) ms 超出允许范围。"
    case .incrementOutOfBounds(let value):
      "Fischer 增益 \(value) ms 超出允许范围。"
    case .movesLeftOutOfBounds(let value):
      "预计剩余手数 \(value) 超出允许范围。"
    }
  }
}

/// Typed session failures. Every failure leaves the session in a defined state
/// and never leaks raw engine output into the message.
public enum PikafishSessionError: Error, Sendable, Equatable, LocalizedError {
  case notStarted
  case alreadyStarted
  case launchFailed
  case handshakeTimeout
  case handshakeTooManyLines
  case readinessTimeout
  case malformedHandshake
  case optionNotAdvertised(String)
  case optionValueOutOfRange(name: String, value: Int, min: Int, max: Int)
  case unknownOptionKind(String)
  case malformedBestMove
  case illegalBestMove(String)
  case searchDeadlineExceeded(generation: UInt64)
  case searchCancelled(generation: UInt64)
  case engineCrashed(terminationStatus: Int32)
  case engineExited(terminationStatus: Int32)
  case restartAttemptsExhausted
  case shutdownTimeout
  case ioFailure
  case invalidState(expected: String, actual: String)
  case inputTooLong(String)
  case malformedOptionValue(String)
  case malformedPosition
  case tooManyPendingCommands

  public var errorDescription: String? {
    switch self {
    case .notStarted: "引擎会话尚未启动。"
    case .alreadyStarted: "引擎会话已经启动。"
    case .launchFailed: "无法启动引擎进程。"
    case .handshakeTimeout: "引擎握手超时。"
    case .handshakeTooManyLines: "引擎握手输出行数超过上限。"
    case .readinessTimeout: "引擎就绪确认超时。"
    case .malformedHandshake: "引擎握手输出无法识别。"
    case .optionNotAdvertised(let name): "引擎未提供选项 \(name)。"
    case .optionValueOutOfRange(let name, let value, let min, let max):
      "选项 \(name) 的值 \(value) 超出引擎声明的范围 [\(min), \(max)]。"
    case .unknownOptionKind(let name): "引擎选项 \(name) 的类型不受支持。"
    case .malformedBestMove: "引擎返回了无法解析的 bestmove。"
    case .illegalBestMove(let move): "引擎返回的着法 \(move) 格式非法。"
    case .searchDeadlineExceeded(let generation): "搜索第 \(generation) 代未在期限内返回。"
    case .searchCancelled(let generation): "搜索第 \(generation) 代已取消。"
    case .engineCrashed(let status): "引擎进程异常退出（状态 \(status)）。"
    case .engineExited(let status): "引擎进程提前退出（状态 \(status)）。"
    case .restartAttemptsExhausted: "引擎重启次数已达上限。"
    case .shutdownTimeout: "引擎进程未在期限内退出。"
    case .ioFailure: "引擎管道 I/O 失败。"
    case .invalidState(let expected, let actual): "引擎会话状态无效：需要 \(expected)，实际 \(actual)。"
    case .inputTooLong(let field): "发送给引擎的 \(field) 超过长度上限。"
    case .malformedOptionValue(let name): "引擎选项 \(name) 包含不允许的控制字符。"
    case .malformedPosition: "局面命令格式非法。"
    case .tooManyPendingCommands: "待发送命令队列超过上限。"
    }
  }
}

/// The only resource presets the application may request. Each maps to fixed
/// Hash/Threads/Ponder values; `deep` requires an explicit user request.
public enum PikafishResourcePreset: String, Sendable, Equatable, CaseIterable {
  case light
  case standard
  case deep

  public var name: String {
    rawValue
  }

  public func resolvedHashMiB(totalPhysicalMemoryBytes: UInt64) -> Int {
    switch self {
    case .light:
      return 16
    case .standard:
      return totalPhysicalMemoryBytes >= 16_000_000_000 ? 64 : 32
    case .deep:
      return 128
    }
  }

  public func resolvedThreads(activeProcessorCount: Int) -> Int {
    switch self {
    case .light:
      return 1
    case .standard:
      return activeProcessorCount >= 4 ? 2 : 1
    case .deep:
      return 4
    }
  }
}

/// Bounded resource limits for one session. All values are enforced by the
/// session and its readers.
public enum PikafishLimits {
  public static let maximumLineBytes = 4_096
  public static let maximumPendingBufferBytes = 65_536
  public static let maximumStderrBytes = 65_536
  public static let maximumPendingCommands = 32
  public static let maximumPVMoves = 512
  public static let maximumFENBytes = 4_096
  public static let maximumUCCIMoves = 4_096
  public static let maximumMoveTokenBytes = 64
  public static let maximumSearchInfoLines = 4_096
  public static let maximumHandshakeLines = 4_096
  public static let maximumDiagnostics = 128
  /// Hard upper bound for any single search budget (30 minutes).
  public static let maximumSearchMilliseconds = 1_800_000
  /// UI candidate rows are capped; the engine may support more MultiPV lines.
  public static let maximumCandidates = 3

  public static let defaultHandshakeTimeout = Duration.seconds(10)
  public static let defaultReadinessTimeout = Duration.seconds(10)
  public static let defaultTerminalWait = Duration.seconds(2)
  public static let defaultExitWait = Duration.seconds(2)
  public static let maximumRestartAttempts = 3
}
