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

/// The versioned WXF-style adjudication profile implemented by T070.
///
/// Snapshot identity: the public subset of repetition responsibility rules
/// described in docs/14-wxf-adjudication.md ("wxf-2011-basic-v1"); full
/// tournament adjudication is intentionally out of scope. The profile id and
/// version participate in repetition-hash identity and cache keys, so a rules
/// update is a profile bump, never a silent reinterpretation of old records.
pub const WXF_PROFILE_ID: u32 = 2;
pub const WXF_PROFILE_VERSION: u32 = 1;
pub const WXF_PROFILE_NAME: &str = "wxf-2011-basic-v1";
/// The schema of WXF per-ply labels stored in variation nodes.
pub const WXF_LABEL_SCHEMA_VERSION: u16 = 1;
/// The schema of the structured adjudication result.
pub const WXF_ADJUDICATION_SCHEMA_VERSION: u16 = 1;
/// Maximum number of per-ply labels in one adjudication result (a cycle cannot
/// exceed the position-history bound; this keeps the ABI batch fixed).
pub const MAX_ADJUDICATION_PLIES: usize = 256;
/// Deterministic explanation is bounded; truncation never happens silently
/// because the builder stops before the cap and marks truncation.
pub const MAX_EXPLANATION_BYTES: usize = 4096;
/// A position repeat is adjudicated only after this many occurrences of the
/// same position (including the current one).
pub const MIN_REPEAT_COUNT_FOR_ADJUDICATION: usize = 3;
