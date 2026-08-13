//! Package-neutral analysis types shared by the document, the coordinator, and
//! the analysis pane. These are disposable presentation/request values: Rust
//! remains the sole authority for legality and document state, and PikafishKit
//! remains the only decoder of raw engine output.

import Foundation
import PikafishKit
import XiangqiCoreBinary

/// Immutable identity of one analysis request, captured from the Rust snapshot
/// and the document history. Every field participates in the persistent cache
/// key and in stale-result rejection.
public struct NativeXiangqiAnalysisIdentity: Sendable, Equatable {
  public let currentNode: UInt32
  public let sideToMove: XiangqiCoreSide
  public let profileID: UInt32
  public let profileVersion: UInt32
  public let positionHash: UInt64
  public let repetitionHash: UInt64
  public let initialFEN: String
  public let ucciMoves: [String]
  public let resourcePreset: PikafishResourcePreset
  public let budget: PikafishSearchBudget
  public let candidateCount: Int

  public init(
    currentNode: UInt32,
    sideToMove: XiangqiCoreSide,
    profileID: UInt32,
    profileVersion: UInt32,
    positionHash: UInt64,
    repetitionHash: UInt64,
    initialFEN: String,
    ucciMoves: [String],
    resourcePreset: PikafishResourcePreset,
    budget: PikafishSearchBudget,
    candidateCount: Int
  ) {
    self.currentNode = currentNode
    self.sideToMove = sideToMove
    self.profileID = profileID
    self.profileVersion = profileVersion
    self.positionHash = positionHash
    self.repetitionHash = repetitionHash
    self.initialFEN = initialFEN
    self.ucciMoves = ucciMoves
    self.resourcePreset = resourcePreset
    self.budget = budget
    self.candidateCount = candidateCount
  }
}

/// One full analysis request. `requestID` disambiguates interleaved searches
/// from a single long-lived session; `generation` is the document's monotonic
/// analysis generation used to discard stale output.
public struct NativeXiangqiAnalysisRequest: Sendable, Equatable {
  public let requestID: UUID
  public let generation: UInt64
  public let identity: NativeXiangqiAnalysisIdentity

  public init(requestID: UUID, generation: UInt64, identity: NativeXiangqiAnalysisIdentity) {
    self.requestID = requestID
    self.generation = generation
    self.identity = identity
  }
}

/// A display-ready candidate row. Scores are converted to the selected
/// perspective before reaching the UI; raw values stay in the engine payload.
public struct NativeXiangqiCandidateRow: Sendable, Equatable {
  public let rank: Int
  public let move: String
  public let evaluation: PikafishDisplayedEvaluation?
  public let depth: Int?
  public let seldepth: Int?
  public let nodes: Int?
  public let nps: Int?
  public let timeMilliseconds: Int?
  public let pv: [String]

  public init(
    rank: Int,
    move: String,
    evaluation: PikafishDisplayedEvaluation?,
    depth: Int?,
    seldepth: Int?,
    nodes: Int?,
    nps: Int?,
    timeMilliseconds: Int?,
    pv: [String]
  ) {
    self.rank = rank
    self.move = move
    self.evaluation = evaluation
    self.depth = depth
    self.seldepth = seldepth
    self.nodes = nodes
    self.nps = nps
    self.timeMilliseconds = timeMilliseconds
    self.pv = pv
  }
}

/// A throttled partial update for one request. Candidates are raw typed
/// Pikafish values; perspective conversion happens at the document boundary
/// where the user's selected perspective is known.
public struct NativeXiangqiAnalysisUpdate: Sendable, Equatable {
  public let requestID: UUID
  public let candidates: [PikafishCandidate]

  public init(requestID: UUID, candidates: [PikafishCandidate]) {
    self.requestID = requestID
    self.candidates = candidates
  }
}

/// The analysis pane's recoverable state machine.
public enum NativeXiangqiAnalysisState: Sendable, Equatable {
  case idle
  case starting
  case searching
  case cacheHit
  /// A search completed and its validated candidates are on display.
  case finished
  case stopped
  case failed(reason: String)
  case engineUnavailable
}

/// Immutable analysis presentation for the inspector pane and board overlays.
public struct NativeXiangqiAnalysisPresentation: Sendable, Equatable {
  public let state: NativeXiangqiAnalysisState
  public let perspective: PikafishEvaluationPerspective
  public let preset: PikafishResourcePreset
  public let candidateRows: [NativeXiangqiCandidateRow]
  public let aiSide: XiangqiCoreSide?
  public let baseRuleModeTitle: String

  public init(
    state: NativeXiangqiAnalysisState,
    perspective: PikafishEvaluationPerspective,
    preset: PikafishResourcePreset,
    candidateRows: [NativeXiangqiCandidateRow],
    aiSide: XiangqiCoreSide?,
    baseRuleModeTitle: String
  ) {
    self.state = state
    self.perspective = perspective
    self.preset = preset
    self.candidateRows = candidateRows
    self.aiSide = aiSide
    self.baseRuleModeTitle = baseRuleModeTitle
  }

  public static func idle(baseRuleModeTitle: String) -> NativeXiangqiAnalysisPresentation {
    NativeXiangqiAnalysisPresentation(
      state: .idle,
      perspective: .red,
      preset: .standard,
      candidateRows: [],
      aiSide: nil,
      baseRuleModeTitle: baseRuleModeTitle
    )
  }
}

/// Converted UCCI token to canonical squares. The canonical convention is
/// `square = rank * 9 + file` with file `a-i` (0-8) and rank `0-9`, matching
/// the UCCI coordinate vocabulary exactly.
public enum NativeXiangqiUCCIConversion {
  public static func square(file: Int, rank: Int) -> UInt8? {
    guard (0..<9).contains(file), (0..<10).contains(rank) else {
      return nil
    }
    return UInt8(rank * 9 + file)
  }

  public static func square(fromUCCI token: String) -> UInt8? {
    guard token.count == 2 else {
      return nil
    }
    let characters = Array(token.utf8)
    guard let file = Int(exactly: Int(characters[0]) - 97), (0..<9).contains(file),
      let rank = Int(exactly: Int(characters[1]) - 48), (0..<10).contains(rank)
    else {
      return nil
    }
    return square(file: file, rank: rank)
  }

  public static func parseMove(_ token: String) -> (from: UInt8, to: UInt8)? {
    guard token.count == 4,
      let from = square(fromUCCI: String(token.prefix(2))),
      let to = square(fromUCCI: String(token.suffix(2)))
    else {
      return nil
    }
    return (from, to)
  }
}
