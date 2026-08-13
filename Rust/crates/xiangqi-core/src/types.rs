//! Compact domain types shared by the canonical Xiangqi core.

use std::{error::Error, fmt};

use crate::limits::{BOARD_FILES, BOARD_RANKS, BOARD_SQUARES};

/// Red moves toward increasing ranks; Black moves toward decreasing ranks.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
#[repr(u8)]
pub enum Side {
    Red = 0,
    Black = 1,
}

impl Side {
    pub const ALL: [Self; 2] = [Self::Red, Self::Black];

    #[must_use]
    pub const fn opponent(self) -> Self {
        match self {
            Self::Red => Self::Black,
            Self::Black => Self::Red,
        }
    }

    #[must_use]
    pub const fn index(self) -> usize {
        self as usize
    }

    #[must_use]
    pub const fn forward_rank_delta(self) -> i8 {
        match self {
            Self::Red => 1,
            Self::Black => -1,
        }
    }

    #[must_use]
    pub const fn is_home_side_rank(self, rank: u8) -> bool {
        match self {
            Self::Red => rank <= 4,
            Self::Black => rank >= 5,
        }
    }

    #[must_use]
    pub const fn has_crossed_river(self, rank: u8) -> bool {
        match self {
            Self::Red => rank >= 5,
            Self::Black => rank <= 4,
        }
    }

    #[must_use]
    pub const fn palace_contains(self, file: u8, rank: u8) -> bool {
        if file < 3 || file > 5 {
            return false;
        }
        match self {
            Self::Red => rank <= 2,
            Self::Black => rank >= 7,
        }
    }
}

/// The seven ordinary Xiangqi piece kinds. General capture is never generated as a move.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
#[repr(u8)]
pub enum PieceKind {
    General = 1,
    Advisor = 2,
    Elephant = 3,
    Horse = 4,
    Rook = 5,
    Cannon = 6,
    Pawn = 7,
}

impl PieceKind {
    pub const ALL: [Self; 7] = [
        Self::General,
        Self::Advisor,
        Self::Elephant,
        Self::Horse,
        Self::Rook,
        Self::Cannon,
        Self::Pawn,
    ];

    #[must_use]
    pub const fn index(self) -> usize {
        (self as usize) - 1
    }

    #[must_use]
    pub const fn fen_letter(self) -> u8 {
        match self {
            Self::General => b'k',
            Self::Advisor => b'a',
            Self::Elephant => b'b',
            Self::Horse => b'n',
            Self::Rook => b'r',
            Self::Cannon => b'c',
            Self::Pawn => b'p',
        }
    }

    #[must_use]
    pub const fn material_limit(self) -> u8 {
        match self {
            Self::General => 1,
            Self::Advisor | Self::Elephant | Self::Horse | Self::Rook | Self::Cannon => 2,
            Self::Pawn => 5,
        }
    }
}

/// A deterministic identity assigned to a physical piece. It deliberately is not hashed.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
#[repr(transparent)]
pub struct PieceId(pub u8);

impl PieceId {
    #[must_use]
    pub const fn raw(self) -> u8 {
        self.0
    }

    #[must_use]
    pub const fn bit(self) -> u64 {
        1_u64 << self.0
    }
}

/// A board occupant. Its ID moves with the piece and vanishes only when captured.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct Piece {
    pub side: Side,
    pub kind: PieceKind,
    pub id: PieceId,
}

/// A board setup item accepted only while constructing a new canonical position.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct SetupPiece {
    pub square: Square,
    pub side: Side,
    pub kind: PieceKind,
}

impl Piece {
    #[must_use]
    pub const fn encoded(self) -> u8 {
        let side_offset = match self.side {
            Side::Red => 0,
            Side::Black => 7,
        };
        side_offset + self.kind as u8
    }
}

/// A checked 0-based square. `a0` is Red's lower-left corner and index zero.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Ord, PartialOrd)]
#[repr(transparent)]
pub struct Square(u8);

impl Square {
    #[must_use]
    pub const fn new(index: u8) -> Option<Self> {
        if (index as usize) < BOARD_SQUARES {
            Some(Self(index))
        } else {
            None
        }
    }

    #[must_use]
    pub const fn from_file_rank(file: u8, rank: u8) -> Option<Self> {
        if file < BOARD_FILES && rank < BOARD_RANKS {
            Self::new(rank * BOARD_FILES + file)
        } else {
            None
        }
    }

    #[must_use]
    pub const fn index(self) -> usize {
        self.0 as usize
    }

    #[must_use]
    pub const fn raw(self) -> u8 {
        self.0
    }

    #[must_use]
    pub const fn file(self) -> u8 {
        self.0 % BOARD_FILES
    }

    #[must_use]
    pub const fn rank(self) -> u8 {
        self.0 / BOARD_FILES
    }

    #[must_use]
    pub const fn offset(self, file_delta: i8, rank_delta: i8) -> Option<Self> {
        let file = self.file() as i8 + file_delta;
        let rank = self.rank() as i8 + rank_delta;
        if file < 0 || rank < 0 {
            return None;
        }
        Self::from_file_rank(file as u8, rank as u8)
    }
}

impl fmt::Display for Square {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let file = char::from(b'a' + self.file());
        let rank = char::from(b'0' + self.rank());
        write!(formatter, "{file}{rank}")
    }
}

/// A coordinate move. Construction excludes invalid and null moves.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct Move {
    pub from: Square,
    pub to: Square,
}

impl Move {
    #[must_use]
    pub const fn new(from: Square, to: Square) -> Option<Self> {
        if from.raw() == to.raw() {
            None
        } else {
            Some(Self { from, to })
        }
    }
}

impl fmt::Display for Move {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}{}", self.from, self.to)
    }
}

/// Stable append-only arena node identifier. Root is always `NodeId(0)`.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Ord, PartialOrd)]
#[repr(transparent)]
pub struct NodeId(pub u32);

impl NodeId {
    pub const ROOT: Self = Self(0);

    #[must_use]
    pub const fn index(self) -> usize {
        self.0 as usize
    }
}

/// The only profile available before the T070 adjudication task.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum RuleProfile {
    /// Base legality and terminal semantics only; no repetition responsibility.
    BaseV1,
    /// The versioned WXF-style repetition responsibility subset implemented by
    /// T070 (docs/14-wxf-adjudication.md). Bumping the version never silently
    /// reinterprets an old record: the version is part of repetition identity.
    WxfV1,
}

impl RuleProfile {
    #[must_use]
    pub const fn id(self) -> u32 {
        match self {
            Self::BaseV1 => crate::limits::BASE_RULE_PROFILE_ID,
            Self::WxfV1 => crate::limits::WXF_PROFILE_ID,
        }
    }

    #[must_use]
    pub const fn version(self) -> u32 {
        match self {
            Self::BaseV1 => crate::limits::BASE_RULE_PROFILE_VERSION,
            Self::WxfV1 => crate::limits::WXF_PROFILE_VERSION,
        }
    }

    /// Only the verified WXF-style profile claims repetition responsibility.
    #[must_use]
    pub const fn supports_wxf_responsibility(self) -> bool {
        matches!(self, Self::WxfV1)
    }

    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::BaseV1 => "base-v1",
            Self::WxfV1 => crate::limits::WXF_PROFILE_NAME,
        }
    }
}

/// Base terminal semantics. Repetition and WXF responsibility are intentionally absent.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum TerminalState {
    Ongoing,
    Checkmate { winner: Side },
    Stalemate { winner: Side },
}

impl TerminalState {
    #[must_use]
    pub const fn is_terminal(self) -> bool {
        !matches!(self, Self::Ongoing)
    }
}

/// Typed core failures. All public mutation methods retain the prior state on failure.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum GameError {
    InvalidSetup(&'static str),
    IllegalMove,
    GameOver,
    NoUndo,
    NoRedo,
    InvalidNode,
    NodeLimit,
    HistoryLimit,
    AnnotationTooLong,
    AnnotationQuota,
    MoveGenerationLimit,
    PerftDepthLimit,
    CounterLimit,
    /// A flat document restore stream is malformed or out of order (for example
    /// a node id that does not match the replayed move). This is corrupt input
    /// data, not a violation of an internal invariant, and maps to a parse
    /// status so callers can distinguish it from a Rust bug.
    CorruptDocument,
    /// A rule-profile switch was requested at a cursor where it cannot be
    /// applied safely (only the root with an empty history may switch).
    ProfileChangeNotAllowed,
    InternalInvariant,
}

impl fmt::Display for GameError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidSetup(reason) => write!(formatter, "invalid Xiangqi setup: {reason}"),
            Self::IllegalMove => formatter.write_str("illegal Xiangqi move"),
            Self::GameOver => formatter.write_str("cannot move after a terminal Xiangqi result"),
            Self::NoUndo => formatter.write_str("no move is available to undo"),
            Self::NoRedo => formatter.write_str("no selected variation is available to redo"),
            Self::InvalidNode => {
                formatter.write_str("variation node does not exist or is not reachable")
            }
            Self::NodeLimit => formatter.write_str("variation-node limit reached"),
            Self::HistoryLimit => formatter.write_str("position-history limit reached"),
            Self::AnnotationTooLong => formatter.write_str("annotation exceeds the per-node limit"),
            Self::AnnotationQuota => formatter.write_str("annotation quota reached"),
            Self::MoveGenerationLimit => {
                formatter.write_str("legal-move generation exceeded its bound")
            }
            Self::PerftDepthLimit => {
                formatter.write_str("perft depth exceeds the bounded diagnostic limit")
            }
            Self::CounterLimit => formatter.write_str("move counter cannot be represented"),
            Self::CorruptDocument => {
                formatter.write_str("malformed or out-of-order document record")
            }
            Self::ProfileChangeNotAllowed => {
                formatter.write_str("rule-profile switch is only allowed at the root")
            }
            Self::InternalInvariant => {
                formatter.write_str("internal Xiangqi state invariant failed")
            }
        }
    }
}

impl Error for GameError {}
