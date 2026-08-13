//! Versioned WXF-style repetition responsibility adjudication (T070).
//!
//! Design invariants (AGENTS.md "Xiangqi rules invariants"):
//! - Cycle detection is separate from responsibility classification.
//! - The classifier consumes only canonical Rust evidence (per-ply events,
//!   positions, legal-move counts). Pikafish evaluation is never consulted.
//! - Every classification is an explicit typed outcome; anything outside the
//!   implemented snapshot subset is `Unsupported` or `Ambiguous`, never a
//!   guessed winner.
//! - The profile id/version is part of repetition identity, so an old record is
//!   never silently reinterpreted under a newer snapshot.
//!
//! Snapshot: `wxf-2011-basic-v1`, the public repetition-responsibility subset
//! documented in docs/14-wxf-adjudication.md. This is deliberately NOT full
//! tournament adjudication.

use crate::{
    GameError, Move, PieceId, PieceKind, Side, Square,
    game::{Game, PlyEventV1},
    limits::{
        MAX_ADJUDICATION_PLIES, MAX_EXPLANATION_BYTES, MIN_REPEAT_COUNT_FOR_ADJUDICATION,
        WXF_ADJUDICATION_SCHEMA_VERSION,
    },
    movegen::piece_attacks_square,
    position::Position,
};

/// Stable material scale in tenths of a rook, used only for the exchange-vs-
/// chase decision inside this snapshot. It is not a general evaluation.
const fn piece_value(kind: PieceKind) -> u16 {
    match kind {
        PieceKind::General => 1_000,
        PieceKind::Rook => 90,
        PieceKind::Cannon => 45,
        PieceKind::Horse => 40,
        PieceKind::Advisor | PieceKind::Elephant => 20,
        PieceKind::Pawn => 10,
    }
}

/// One chased target with its protection evidence.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct ChaseTargetV1 {
    pub target_id: PieceId,
    pub target_kind: PieceKind,
    pub protected: bool,
    /// Capture trades favorably: the target is unprotected, or the mover is
    /// worth strictly more than the target.
    pub trade_favorable: bool,
}

/// Per-ply classification inside the snapshot.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum PlyClassV1 {
    /// The moved piece gives check.
    Check,
    /// The moved piece attacks exactly one opponent piece (not the general)
    /// after the move. Protection and trade evidence are attached.
    Chase(ChaseTargetV1),
    /// The moved piece captures/attacks a protected piece of no greater value:
    /// an exchange ("兑"), not a chase.
    Exchange,
    /// No check and no chase: an idle move ("闲").
    Idle,
    /// The snapshot cannot classify this ply (for example multiple attacked
    /// targets). The reason code is stable and documented.
    Unsupported(u8),
}

impl PlyClassV1 {
    #[must_use]
    pub const fn is_check(self) -> bool {
        matches!(self, Self::Check)
    }

    #[must_use]
    pub const fn chase_target_id(self) -> Option<PieceId> {
        match self {
            Self::Chase(target) => Some(target.target_id),
            _ => None,
        }
    }

    #[must_use]
    pub const fn is_unsupported(self) -> bool {
        matches!(self, Self::Unsupported(_))
    }

    /// Stable textual key used by explanations and exports.
    #[must_use]
    pub const fn key(self) -> &'static str {
        match self {
            Self::Check => "将",
            Self::Chase(_) => "捉",
            Self::Exchange => "兑",
            Self::Idle => "闲",
            Self::Unsupported(1) => "不支持(多目标)",
            Self::Unsupported(_) => "不支持",
        }
    }
}

/// One versioned per-ply WXF label stored in the variation node alongside the
/// raw base event. It is derived data: Rust events remain the evidence.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct WxfPlyLabelV1 {
    pub schema_version: u16,
    pub mover: Side,
    pub mv: Move,
    pub class: PlyClassV1,
    /// The mover side was in check before this ply ("应将").
    pub was_evading: bool,
    /// The move resolved a previous check ("应将完成") — informational only.
    pub resolved_check: bool,
}

/// The detected repetition cycle, expressed in ply indexes of the current
/// root-to-cursor path. `start_ply` is the first ply after the second-most-
/// recent occurrence of the repeated position; `end_ply` is the current ply.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct CycleV1 {
    pub start_ply: u32,
    pub end_ply: u32,
    pub ply_count: u32,
    pub repeat_count: u32,
}

/// Typed adjudication outcomes. `Unsupported` and `Ambiguous` never declare a
/// winner; the caller must keep the game open and surface the explanation.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum VerdictV1 {
    /// No repeat reaches the adjudication threshold, or nothing to classify.
    NoAction,
    /// The position repeats and neither side violates the snapshot (for
    /// example "双方不变作和").
    Draw,
    /// The side must change; refusing loses under tournament rules.
    MustChange(Side),
    /// The snapshot has no definition for this pattern.
    Unsupported,
    /// The evidence does not determine a single outcome.
    Ambiguous,
}

impl VerdictV1 {
    #[must_use]
    pub const fn key(self) -> &'static str {
        match self {
            Self::NoAction => "无动作",
            Self::Draw => "和棋",
            Self::MustChange(Side::Red) => "红方须变着",
            Self::MustChange(Side::Black) => "黑方须变着",
            Self::Unsupported => "不支持",
            Self::Ambiguous => "存疑",
        }
    }
}

/// The structured, deterministic adjudication result for the current position.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdjudicationResultV1 {
    pub schema_version: u16,
    pub profile_id: u32,
    pub profile_version: u32,
    pub verdict: VerdictV1,
    pub cycle: Option<CycleV1>,
    /// Per-ply labels inside the cycle, oldest first, bounded.
    pub labels: Vec<WxfPlyLabelV1>,
    /// Deterministic Chinese explanation; truncated only at the documented cap
    /// with an explicit marker.
    pub explanation: String,
    pub explanation_truncated: bool,
}

/// Reason codes for `PlyClassV1::Unsupported`.
pub const UNSUPPORTED_MULTIPLE_TARGETS: u8 = 1;

/// Classifies one already-applied ply from its raw event plus the positions
/// before and after. Pure and deterministic; no engine evaluation.
pub(crate) fn classify_ply(event: &PlyEventV1, position_after: &Position) -> PlyClassV1 {
    if event.gives_check {
        return PlyClassV1::Check;
    }
    if event.moved_piece_targets_after == 0 {
        return PlyClassV1::Idle;
    }
    let mover_square = event.mv.to;
    let mover = match position_after.piece_at(mover_square) {
        Some(piece) => piece,
        None => return PlyClassV1::Unsupported(0),
    };
    // Collect attacked opponent piece ids (excluding the general: attacking
    // the general is check, already handled above).
    let mut target_ids = [0_u8; 16];
    let mut target_count = 0_usize;
    for raw_square in 0..crate::limits::BOARD_SQUARES as u8 {
        let Some(square) = Square::new(raw_square) else {
            continue;
        };
        if square == mover_square {
            continue;
        }
        let Some(piece) = position_after.piece_at(square) else {
            continue;
        };
        if piece.side != mover.side
            && piece.kind != PieceKind::General
            && event.moved_piece_targets_after & piece.id.bit() != 0
            && target_count < target_ids.len()
        {
            target_ids[target_count] = piece.id.raw();
            target_count += 1;
        }
    }
    if target_count == 0 {
        return PlyClassV1::Idle;
    }
    if target_count > 1 {
        // Alternating or joint targets need the full priority tables.
        return PlyClassV1::Unsupported(UNSUPPORTED_MULTIPLE_TARGETS);
    }
    let target_id = PieceId(target_ids[0]);
    let Some((_, target_piece)) = position_after
        .pieces()
        .into_iter()
        .find(|(_, piece)| piece.id == target_id)
    else {
        return PlyClassV1::Unsupported(0);
    };
    let target_square = position_after.square_of(target_id).unwrap_or(mover_square);
    let protected = is_protected(position_after, target_square, target_piece.side);
    let favorable = !protected || piece_value(mover.kind) > piece_value(target_piece.kind);
    if protected && piece_value(mover.kind) <= piece_value(target_piece.kind) {
        return PlyClassV1::Exchange;
    }
    PlyClassV1::Chase(ChaseTargetV1 {
        target_id,
        target_kind: target_piece.kind,
        protected,
        trade_favorable: favorable,
    })
}

/// Whether any piece of `side` (other than a piece on `square`) attacks
/// `square` in the given position.
fn is_protected(position: &Position, square: Square, side: Side) -> bool {
    for raw_square in 0..crate::limits::BOARD_SQUARES as u8 {
        let Some(candidate_square) = Square::new(raw_square) else {
            continue;
        };
        if candidate_square == square {
            continue;
        }
        let Some(piece) = position.piece_at(candidate_square) else {
            continue;
        };
        if piece.side != side {
            continue;
        }
        if piece_attacks_square(position, candidate_square, piece, square) {
            return true;
        }
    }
    false
}

impl Game {
    /// Computes the structured adjudication for the current position.
    ///
    /// Cycle detection walks canonical history hashes only; responsibility
    /// classification consumes the versioned per-ply labels. Positions are
    /// adjudicated only after `MIN_REPEAT_COUNT_FOR_ADJUDICATION` occurrences
    /// (including the current one); anything outside the snapshot is
    /// `Unsupported`, never a guessed outcome.
    pub fn adjudicate_current(&self) -> Result<AdjudicationResultV1, GameError> {
        let profile = self.profile();
        let result = AdjudicationResultV1 {
            schema_version: WXF_ADJUDICATION_SCHEMA_VERSION,
            profile_id: profile.id(),
            profile_version: profile.version(),
            verdict: VerdictV1::NoAction,
            cycle: None,
            labels: Vec::new(),
            explanation: String::new(),
            explanation_truncated: false,
        };
        if !profile.supports_wxf_responsibility() {
            return Ok(self.with_explanation(
                result,
                &format!("当前规则档案 {} 不启用重复判罚责任分类。", profile.name()),
            ));
        }
        // Locate every occurrence of the current position on the active path.
        let current_hash = self.position_hash();
        let mut occurrences: Vec<u32> = Vec::new();
        occurrences
            .try_reserve_exact(MAX_ADJUDICATION_PLIES.min(32))
            .map_err(|_| GameError::HistoryLimit)?;
        for (index, entry) in self.history_entries().iter().enumerate() {
            if entry.position_hash == current_hash {
                occurrences.push(index as u32);
            }
        }
        if occurrences.len() < MIN_REPEAT_COUNT_FOR_ADJUDICATION {
            return Ok(self.with_explanation(
                result,
                &format!(
                    "当前局面重复出现 {} 次，未达到判罚阈值 {} 次。",
                    occurrences.len(),
                    MIN_REPEAT_COUNT_FOR_ADJUDICATION
                ),
            ));
        }
        let second_most_recent = occurrences[occurrences.len() - 2];
        let most_recent = occurrences[occurrences.len() - 1];
        let start_ply = second_most_recent + 1;
        let end_ply = most_recent;
        let cycle = CycleV1 {
            start_ply,
            end_ply,
            ply_count: end_ply - start_ply + 1,
            repeat_count: occurrences.len() as u32,
        };
        if cycle.ply_count == 0 || cycle.ply_count > MAX_ADJUDICATION_PLIES as u32 {
            return Ok(self.with_explanation(
                result,
                &format!("循环长度 {} 超出判罚上限。", cycle.ply_count),
            ));
        }
        let mut labels = Vec::new();
        labels
            .try_reserve_exact(cycle.ply_count as usize)
            .map_err(|_| GameError::HistoryLimit)?;
        for ply in start_ply..=end_ply {
            let entry = self
                .history_entries()
                .get(ply as usize)
                .ok_or(GameError::InternalInvariant)?;
            let label = self
                .wxf_label_for_node(entry.node)?
                .ok_or(GameError::InternalInvariant)?;
            labels.push(label);
        }
        let (verdict, reason) = classify_cycle(&labels, cycle);
        let mut result = AdjudicationResultV1 {
            schema_version: result.schema_version,
            profile_id: result.profile_id,
            profile_version: result.profile_version,
            verdict,
            cycle: Some(cycle),
            labels: labels.clone(),
            explanation: String::new(),
            explanation_truncated: false,
        };
        let mut text = String::new();
        text.push_str(&format!(
            "规则快照 {}。第 {} 手至第 {} 手构成循环（局面重复 {} 次）。",
            profile.name(),
            start_ply,
            end_ply,
            cycle.repeat_count
        ));
        let mut red: Vec<&'static str> = Vec::new();
        let mut black: Vec<&'static str> = Vec::new();
        for label in &labels {
            let bucket = if label.mover == Side::Red {
                &mut red
            } else {
                &mut black
            };
            bucket.push(label.class.key());
        }
        text.push_str(&format!("红方着法：{}。", red.join("")));
        text.push_str(&format!("黑方着法：{}。", black.join("")));
        text.push_str(reason);
        result.explanation = text;
        result.explanation_truncated = false;
        if result.explanation.len() > MAX_EXPLANATION_BYTES {
            result.explanation.truncate(MAX_EXPLANATION_BYTES);
            result.explanation_truncated = true;
        }
        Ok(result)
    }

    fn with_explanation(
        &self,
        mut result: AdjudicationResultV1,
        reason: &str,
    ) -> AdjudicationResultV1 {
        result.explanation = reason.to_string();
        result.explanation_truncated = result.explanation.len() > MAX_EXPLANATION_BYTES;
        result
    }
}

/// Responsibility classification over one detected cycle.
///
/// The snapshot covers uniform patterns only; every mixed pattern is
/// `Unsupported` with an explicit reason instead of a guessed winner.
pub fn classify_cycle(labels: &[WxfPlyLabelV1], cycle: CycleV1) -> (VerdictV1, &'static str) {
    if labels.iter().any(|label| label.class.is_unsupported()) {
        return (
            VerdictV1::Unsupported,
            "循环内存在本快照无法分类的着法，判罚不支持。",
        );
    }
    let red_plies: Vec<_> = labels.iter().filter(|l| l.mover == Side::Red).collect();
    let black_plies: Vec<_> = labels.iter().filter(|l| l.mover == Side::Black).collect();
    if red_plies.is_empty() || black_plies.is_empty() || !cycle.ply_count.is_multiple_of(2) {
        return (VerdictV1::Ambiguous, "循环着法分布异常，判罚存疑。");
    }
    let red_all_check = red_plies.iter().all(|l| l.class.is_check());
    let black_all_check = black_plies.iter().all(|l| l.class.is_check());
    if red_all_check && black_all_check {
        return (VerdictV1::Draw, "双方长将，判和。");
    }
    if red_all_check {
        return (VerdictV1::MustChange(Side::Red), "红方长将，须变着。");
    }
    if black_all_check {
        return (VerdictV1::MustChange(Side::Black), "黑方长将，须变着。");
    }
    let red_all_idle = red_plies.iter().all(|l| l.class == PlyClassV1::Idle);
    let black_all_idle = black_plies.iter().all(|l| l.class == PlyClassV1::Idle);
    if red_all_idle && black_all_idle {
        return (VerdictV1::Draw, "双方均为闲着，不变作和。");
    }
    let red_chase_target = uniform_chase_target(&red_plies);
    let black_chase_target = uniform_chase_target(&black_plies);
    if let (Some(red_target), Some(black_target)) = (red_chase_target, black_chase_target) {
        if red_target == black_target {
            return (
                VerdictV1::Ambiguous,
                "双方长捉同一目标，本快照无法区分优先级，判罚存疑。",
            );
        }
        return (
            VerdictV1::Unsupported,
            "双方长捉不同目标，需要完整判罚表，判罚不支持。",
        );
    }
    if red_chase_target.is_some() {
        if black_all_idle {
            return (
                VerdictV1::MustChange(Side::Red),
                "红方长捉，黑方长闲，红方须变着。",
            );
        }
        return (
            VerdictV1::Unsupported,
            "红方长捉但黑方着法混合，需要完整判罚表，判罚不支持。",
        );
    }
    if black_chase_target.is_some() {
        if red_all_idle {
            return (
                VerdictV1::MustChange(Side::Black),
                "黑方长捉，红方长闲，黑方须变着。",
            );
        }
        return (
            VerdictV1::Unsupported,
            "黑方长捉但红方着法混合，需要完整判罚表，判罚不支持。",
        );
    }
    // Mixed non-uniform patterns (for example 一将一闲) are allowed moves in
    // the snapshot only when uniform rules do not apply; the priority tables
    // are outside the subset, so remain explicit.
    (
        VerdictV1::Unsupported,
        "循环着法为混合模式（将/捉/闲 组合），需要完整判罚表，判罚不支持。",
    )
}

fn uniform_chase_target(plies: &[&WxfPlyLabelV1]) -> Option<PieceId> {
    let first = plies.first()?.class.chase_target_id()?;
    if plies
        .iter()
        .all(|label| label.class.chase_target_id() == Some(first))
    {
        Some(first)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{RuleProfile, SetupPiece, game::Game};

    fn setup(pieces: &[(Side, PieceKind, u8, u8)]) -> Game {
        let setup_pieces: Vec<SetupPiece> = pieces
            .iter()
            .map(|&(side, kind, file, rank)| SetupPiece {
                square: Square::from_file_rank(file, rank).unwrap(),
                side,
                kind,
            })
            .collect();
        Game::from_setup_with_profile(Side::Red, &setup_pieces, 0, 1, RuleProfile::WxfV1).unwrap()
    }

    #[test]
    fn multi_target_ply_is_unsupported() {
        let mut game = setup(&[
            (Side::Red, PieceKind::General, 4, 0),
            (Side::Black, PieceKind::General, 4, 9),
            (Side::Red, PieceKind::Rook, 0, 1),
            (Side::Black, PieceKind::Rook, 7, 2),
            (Side::Black, PieceKind::Horse, 0, 9),
            (Side::Red, PieceKind::Pawn, 4, 5),
        ]);
        // Rook a1 -> a2 now attacks both the black rook on h2 (rank 2) and the
        // black horse on a9 (file a): two simultaneous chase targets.
        game.apply_move(
            Move::new(
                Square::from_file_rank(0, 1).unwrap(),
                Square::from_file_rank(0, 2).unwrap(),
            )
            .unwrap(),
        )
        .unwrap();
        let node = game.current_node();
        let event = game.event_for_node(node).unwrap().unwrap();
        let class = classify_ply(&event, game.position());
        assert_eq!(class, PlyClassV1::Unsupported(UNSUPPORTED_MULTIPLE_TARGETS));
    }

    #[test]
    fn protected_adjacent_capture_is_exchange_not_chase() {
        // Red cannon h8 -> g8 attacks black cannon c8 through the single
        // elephant screen on d8. The target is protected by black rook c2 and
        // equal in value (45 vs 45): this is an exchange ("兑"), not a chase.
        let mut game = setup(&[
            (Side::Red, PieceKind::General, 4, 0),
            (Side::Black, PieceKind::General, 4, 9),
            (Side::Red, PieceKind::Cannon, 7, 8),
            (Side::Black, PieceKind::Elephant, 3, 8),
            (Side::Black, PieceKind::Cannon, 2, 8),
            (Side::Black, PieceKind::Rook, 2, 2),
            (Side::Red, PieceKind::Pawn, 4, 5),
        ]);
        game.apply_move(
            Move::new(
                Square::from_file_rank(7, 8).unwrap(),
                Square::from_file_rank(6, 8).unwrap(),
            )
            .unwrap(),
        )
        .unwrap();
        let node = game.current_node();
        let event = game.event_for_node(node).unwrap().unwrap();
        let class = classify_ply(&event, game.position());
        assert!(
            matches!(class, PlyClassV1::Exchange),
            "expected Exchange, got {class:?}"
        );
    }
}
