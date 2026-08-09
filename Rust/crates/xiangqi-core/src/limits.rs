//! Fixed resource ceilings for the canonical base-rules profile.

/// The board has nine files and ten ranks.
pub const BOARD_FILES: u8 = 9;
pub const BOARD_RANKS: u8 = 10;
pub const BOARD_SQUARES: usize = (BOARD_FILES as usize) * (BOARD_RANKS as usize);

/// A Xiangqi position cannot produce this many legal moves; keep a hard guard anyway.
pub const MAX_GENERATED_MOVES: usize = 256;
/// The append-only variation arena includes its root node in this cap.
pub const MAX_VARIATION_NODES: usize = 4_096;
/// A path cannot be deeper than the bounded arena.
pub const MAX_TREE_DEPTH: usize = 4_096;
/// Includes the initial position plus one entry per applied ply.
pub const MAX_POSITION_HISTORY: usize = MAX_TREE_DEPTH + 1;
/// Future document work may attach annotations, but core enforces a safe quota now.
pub const MAX_ANNOTATION_BYTES_PER_NODE: usize = 64 * 1024;
pub const MAX_TOTAL_ANNOTATION_BYTES: usize = 16 * 1024 * 1024;
/// Perft is diagnostic work, not an unbounded public search facility.
pub const MAX_PERFT_DEPTH: u8 = 5;

/// The immutable base-rule profile intentionally has no WXF responsibility classifier.
pub const BASE_RULE_PROFILE_ID: u32 = 1;
pub const BASE_RULE_PROFILE_VERSION: u32 = 1;
/// The schema of raw per-ply evidence retained for a later adjudication task.
pub const PLY_EVENT_SCHEMA_VERSION: u16 = 1;
