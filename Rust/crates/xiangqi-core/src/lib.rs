//! Canonical, engine-independent Xiangqi base rules.
//!
//! This crate owns board state, legal movement, terminal semantics, variation history,
//! hashes, and raw repetition evidence. It intentionally does not classify long check or
//! long chase responsibility; that later work must consume the versioned evidence here.

#![forbid(unsafe_code)]

mod game;
mod hash;
mod limits;
mod movegen;
mod position;
mod types;

pub use game::{BoardSnapshotV1, Game, HistorySummaryV1, PlyEventV1, PositionDigestV1};
pub use hash::HASH_SCHEME_VERSION;
pub use limits::{
    BASE_RULE_PROFILE_ID, BASE_RULE_PROFILE_VERSION, BOARD_FILES, BOARD_RANKS, BOARD_SQUARES,
    MAX_ANNOTATION_BYTES_PER_NODE, MAX_GENERATED_MOVES, MAX_POSITION_HISTORY,
    MAX_TOTAL_ANNOTATION_BYTES, MAX_TREE_DEPTH, MAX_VARIATION_NODES, PLY_EVENT_SCHEMA_VERSION,
};
pub use types::{
    GameError, Move, NodeId, Piece, PieceId, PieceKind, RuleProfile, SetupPiece, Side, Square,
    TerminalState,
};

/// Canonical UCCI-compatible standard initial FEN. `w` means Red to move.
pub const STANDARD_INITIAL_FEN: &str =
    "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1";
