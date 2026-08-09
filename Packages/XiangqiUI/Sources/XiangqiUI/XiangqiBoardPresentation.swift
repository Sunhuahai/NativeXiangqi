import Foundation

public enum XiangqiBoardSide: UInt8, Sendable, Equatable {
  case red = 0
  case black = 1

  public var localizedName: String {
    switch self {
    case .red:
      "红方"
    case .black:
      "黑方"
    }
  }
}

public enum XiangqiBoardTerminal: Sendable, Equatable {
  case ongoing
  case checkmate(winner: XiangqiBoardSide)
  case stalemate(winner: XiangqiBoardSide)

  public var accessibilityDescription: String {
    switch self {
    case .ongoing:
      "对局进行中"
    case .checkmate(let winner):
      "将死，\(winner.localizedName)获胜"
    case .stalemate(let winner):
      "困毙，\(winner.localizedName)获胜"
    }
  }
}

/// A displayed move is a disposable presentation hint. Rust still validates every
/// navigation and state transition.
public struct XiangqiBoardDisplayedMove: Sendable, Equatable {
  public let from: UInt8
  public let to: UInt8

  public init?(from: UInt8, to: UInt8) {
    guard from < 90, to < 90, from != to else {
      return nil
    }
    self.from = from
    self.to = to
  }
}

/// A bounded, explicitly non-engine annotation in the right-hand placeholder pane.
public struct XiangqiBoardCandidate: Sendable, Equatable {
  public let title: String
  public let detail: String

  public init(title: String, detail: String) {
    self.title = String(title.prefix(48))
    self.detail = String(detail.prefix(96))
  }
}

/// Immutable, disposable render input. Cell encodings originate in Rust's fixed ABI
/// snapshot; this type performs no move generation or outcome inference.
public struct XiangqiBoardPresentation: Sendable, Equatable {
  public static let maximumCandidates = 3

  public let cells: [UInt8]
  public let sideToMove: XiangqiBoardSide
  public let checkedSide: XiangqiBoardSide?
  public let terminal: XiangqiBoardTerminal
  public let selectedSquare: UInt8?
  public let legalDestinations: Set<UInt8>
  public let lastMove: XiangqiBoardDisplayedMove?
  public let perspective: XiangqiBoardPerspective
  public let fakeCandidates: [XiangqiBoardCandidate]

  public init?(
    cells: [UInt8],
    sideToMove: XiangqiBoardSide,
    checkedSide: XiangqiBoardSide?,
    terminal: XiangqiBoardTerminal,
    selectedSquare: UInt8?,
    legalDestinations: Set<UInt8>,
    lastMove: XiangqiBoardDisplayedMove?,
    perspective: XiangqiBoardPerspective,
    fakeCandidates: [XiangqiBoardCandidate]
  ) {
    guard cells.count == 90,
      cells.allSatisfy({ $0 <= 14 }),
      selectedSquare.map({ $0 < 90 }) ?? true,
      legalDestinations.allSatisfy({ $0 < 90 }),
      fakeCandidates.count <= Self.maximumCandidates
    else {
      return nil
    }
    self.init(
      uncheckedCells: cells,
      sideToMove: sideToMove,
      checkedSide: checkedSide,
      terminal: terminal,
      selectedSquare: selectedSquare,
      legalDestinations: legalDestinations,
      lastMove: lastMove,
      perspective: perspective,
      fakeCandidates: fakeCandidates
    )
  }

  public static let empty = XiangqiBoardPresentation(
    uncheckedCells: Array(repeating: 0, count: 90),
    sideToMove: .red,
    checkedSide: nil,
    terminal: .ongoing,
    selectedSquare: nil,
    legalDestinations: [],
    lastMove: nil,
    perspective: .redAtBottom,
    fakeCandidates: []
  )

  public func withPerspective(_ perspective: XiangqiBoardPerspective) -> XiangqiBoardPresentation {
    XiangqiBoardPresentation(
      uncheckedCells: cells,
      sideToMove: sideToMove,
      checkedSide: checkedSide,
      terminal: terminal,
      selectedSquare: selectedSquare,
      legalDestinations: legalDestinations,
      lastMove: lastMove,
      perspective: perspective,
      fakeCandidates: fakeCandidates
    )
  }

  private init(
    uncheckedCells cells: [UInt8],
    sideToMove: XiangqiBoardSide,
    checkedSide: XiangqiBoardSide?,
    terminal: XiangqiBoardTerminal,
    selectedSquare: UInt8?,
    legalDestinations: Set<UInt8>,
    lastMove: XiangqiBoardDisplayedMove?,
    perspective: XiangqiBoardPerspective,
    fakeCandidates: [XiangqiBoardCandidate]
  ) {
    self.cells = cells
    self.sideToMove = sideToMove
    self.checkedSide = checkedSide
    self.terminal = terminal
    self.selectedSquare = selectedSquare
    self.legalDestinations = legalDestinations
    self.lastMove = lastMove
    self.perspective = perspective
    self.fakeCandidates = fakeCandidates
  }
}
