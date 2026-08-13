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
  /// The last accepted info line before the terminal, when one was emitted.
  public let finalInfo: PikafishInfo?
  /// Milliseconds spent waiting for the terminal result.
  public let elapsedMilliseconds: Int

  public init(
    generation: UInt64,
    bestMove: PikafishBestMove,
    finalInfo: PikafishInfo?,
    elapsedMilliseconds: Int
  ) {
    self.generation = generation
    self.bestMove = bestMove
    self.finalInfo = finalInfo
    self.elapsedMilliseconds = elapsedMilliseconds
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

  public static let defaultHandshakeTimeout = Duration.seconds(10)
  public static let defaultReadinessTimeout = Duration.seconds(10)
  public static let defaultTerminalWait = Duration.seconds(2)
  public static let defaultExitWait = Duration.seconds(2)
  public static let maximumRestartAttempts = 3
}
