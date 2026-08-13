//! T070 WXF-style adjudication corpus.
//!
//! Two kinds of fixtures, both with manually reasoned expected labels:
//!
//! - Full legal-game fixtures under `RuleProfile::WxfV1`: every ply is applied
//!   through the canonical legality engine and the cycle/verdict is asserted
//!   end-to-end (长将, 长捉, 双方长闲).
//! - Classifier unit vectors for patterns whose full legal-game construction
//!   is documented as pending independent review (互将, 一将一闲, 交替目标,
//!   兑, 多目标).
//!
//! Snapshot: wxf-2011-basic-v1 (docs/14-wxf-adjudication.md). Expected labels
//! are authored and require independent human review before any release claim;
//! unsupported patterns always return `Unsupported`, never a guessed winner.

use xiangqi_core::{
    PieceId, PieceKind, RuleProfile, SetupPiece, Side, Square, VerdictV1, game::Game,
};

fn square(file: u8, rank: u8) -> Square {
    Square::from_file_rank(file, rank).expect("valid square")
}

fn setup(pieces: &[(Side, PieceKind, u8, u8)]) -> Result<Game, xiangqi_core::GameError> {
    let setup_pieces: Vec<SetupPiece> = pieces
        .iter()
        .map(|&(side, kind, file, rank)| SetupPiece {
            square: square(file, rank),
            side,
            kind,
        })
        .collect();
    Game::from_setup_with_profile(Side::Red, &setup_pieces, 0, 1, RuleProfile::WxfV1)
}

fn apply(game: &mut Game, moves: &[&str]) -> Result<(), xiangqi_core::GameError> {
    for (index, token) in moves.iter().enumerate() {
        let bytes = token.as_bytes();
        let from = Square::from_file_rank(bytes[0] - b'a', bytes[1] - b'0').unwrap();
        let to = Square::from_file_rank(bytes[2] - b'a', bytes[3] - b'0').unwrap();
        game.apply_move(xiangqi_core::Move::new(from, to).unwrap())
            .map_err(|error| {
                panic!("ply {} move {} failed: {error:?}", index + 1, token);
            })?;
    }
    Ok(())
}

const RED_GENERAL: (Side, PieceKind, u8, u8) = (Side::Red, PieceKind::General, 4, 0);
const BLACK_GENERAL: (Side, PieceKind, u8, u8) = (Side::Black, PieceKind::General, 4, 9);

fn assert_verdict(game: &mut Game, expected: VerdictV1, label: &str) {
    let result = game.adjudicate_current().expect("adjudication succeeds");
    assert_eq!(
        result.verdict, expected,
        "{label}: verdict mismatch. explanation={}",
        result.explanation
    );
    assert!(!result.explanation.is_empty(), "{label}: explanation empty");
    assert!(
        result.explanation.len() <= xiangqi_core::MAX_EXPLANATION_BYTES,
        "{label}: explanation over bound"
    );
}

/// 长将：红车在 b9/c9 之间来回将军，黑将 e9/d9 来回躲避。
/// 循环内红方两着均为“将”，黑方两着均为“闲” → 红方长将，须变着。
#[test]
fn long_check_red_must_change() {
    let mut game = setup(&[
        RED_GENERAL,
        BLACK_GENERAL,
        (Side::Red, PieceKind::Rook, 0, 9),
        (Side::Red, PieceKind::Pawn, 4, 5), // blocks the open e-file
    ])
    .unwrap();
    apply(
        &mut game,
        &[
            "a9b9", "e9e8", "b9b8", "e8e9", "b8b9", "e9e8", "b9b8", "e8e9", "b8b9",
        ],
    )
    .unwrap();
    assert_verdict(
        &mut game,
        VerdictV1::MustChange(Side::Red),
        "long check red",
    );
}

/// 长捉：红炮在 a6/a8 之间来回，借 b6/b8 两个黑象作炮架，捉无根黑马
/// （黑马在 d6/c8 之间来回逃，红炮总在“马已落位”后到达攻击点）。
/// 循环内红方两着均为“捉”同一马，黑方两着均为“闲” → 红方长捉，须变着。
#[test]
fn long_chase_red_must_change() {
    let mut game = setup(&[
        RED_GENERAL,
        BLACK_GENERAL,
        (Side::Red, PieceKind::Cannon, 0, 8),
        (Side::Red, PieceKind::Pawn, 4, 5),
        (Side::Black, PieceKind::Horse, 3, 6),
        (Side::Black, PieceKind::Elephant, 1, 6), // screen for a6 -> d6
        (Side::Black, PieceKind::Elephant, 1, 8), // screen for a8 -> c8
    ])
    .unwrap();
    apply(
        &mut game,
        &[
            "a8a6", "d6c8", "a6a8", "c8d6", "a8a6", "d6c8", "a6a8", "c8d6", "a8a6",
        ],
    )
    .unwrap();
    assert_verdict(
        &mut game,
        VerdictV1::MustChange(Side::Red),
        "long chase red",
    );
}

/// 双方长闲：红车 b1/b2、黑车 h9/h8 各自来回，互不攻击。
/// 循环内双方均为“闲” → 双方不变作和。
#[test]
fn both_idle_is_draw() {
    let mut game = setup(&[
        RED_GENERAL,
        BLACK_GENERAL,
        (Side::Red, PieceKind::Rook, 1, 1),
        (Side::Black, PieceKind::Rook, 7, 9),
        (Side::Red, PieceKind::Pawn, 4, 5),
    ])
    .unwrap();
    apply(
        &mut game,
        &[
            "b1b2", "h9h8", "b2b1", "h8h9", "b1b2", "h9h8", "b2b1", "h8h9", "b1b2",
        ],
    )
    .unwrap();
    assert_verdict(&mut game, VerdictV1::Draw, "both idle draw");
}

/// 黑方长将（镜像分类器向量）：循环内黑方两着均为“将”，红方两着均为
/// “闲” → 黑方长将，须变着。合法全局面夹具待人工评审补充（镜像长将的
/// 等待着法需要额外子力，构造繁琐，与互将同级列为向量级证据）。
#[test]
fn long_check_black_must_change() {
    use xiangqi_core::{PlyClassV1, WxfPlyLabelV1, adjudication::classify_cycle};
    let label = |side, class| WxfPlyLabelV1 {
        schema_version: 1,
        mover: side,
        mv: xiangqi_core::Move::new(square(4, 1), square(4, 2)).unwrap(),
        class,
        was_evading: false,
        resolved_check: false,
    };
    let cycle = xiangqi_core::CycleV1 {
        start_ply: 1,
        end_ply: 4,
        ply_count: 4,
        repeat_count: 3,
    };
    let labels = vec![
        label(Side::Red, PlyClassV1::Idle),
        label(Side::Black, PlyClassV1::Check),
        label(Side::Red, PlyClassV1::Idle),
        label(Side::Black, PlyClassV1::Check),
    ];
    let (verdict, reason) = classify_cycle(&labels, cycle);
    assert_eq!(verdict, VerdictV1::MustChange(Side::Black), "{reason}");
    assert_eq!(reason, "黑方长将，须变着。");
}

/// 互将：双方循环内各自两着均为“将” → 双方长将判和。
#[test]
fn mutual_check_is_draw() {
    use xiangqi_core::{PlyClassV1, WxfPlyLabelV1, adjudication::classify_cycle};
    let mv = |file_from, rank_from, file_to, rank_to| {
        xiangqi_core::Move::new(square(file_from, rank_from), square(file_to, rank_to)).unwrap()
    };
    let label = |side, class| WxfPlyLabelV1 {
        schema_version: 1,
        mover: side,
        mv: mv(4, 1, 4, 2),
        class,
        was_evading: false,
        resolved_check: false,
    };
    let cycle = xiangqi_core::CycleV1 {
        start_ply: 1,
        end_ply: 4,
        ply_count: 4,
        repeat_count: 3,
    };
    let labels = vec![
        label(Side::Red, PlyClassV1::Check),
        label(Side::Black, PlyClassV1::Check),
        label(Side::Red, PlyClassV1::Check),
        label(Side::Black, PlyClassV1::Check),
    ];
    let (verdict, reason) = classify_cycle(&labels, cycle);
    assert_eq!(verdict, VerdictV1::Draw, "{reason}");
    assert_eq!(reason, "双方长将，判和。");
}

/// 一将一闲：红方循环内“将、闲”交替 → 混合模式，明确不支持。
#[test]
fn one_check_one_idle_is_unsupported() {
    use xiangqi_core::{PlyClassV1, WxfPlyLabelV1, adjudication::classify_cycle};
    let label = |side, class| WxfPlyLabelV1 {
        schema_version: 1,
        mover: side,
        mv: xiangqi_core::Move::new(square(4, 1), square(4, 2)).unwrap(),
        class,
        was_evading: false,
        resolved_check: false,
    };
    let cycle = xiangqi_core::CycleV1 {
        start_ply: 1,
        end_ply: 4,
        ply_count: 4,
        repeat_count: 3,
    };
    let labels = vec![
        label(Side::Red, PlyClassV1::Check),
        label(Side::Black, PlyClassV1::Idle),
        label(Side::Red, PlyClassV1::Idle),
        label(Side::Black, PlyClassV1::Idle),
    ];
    let (verdict, reason) = classify_cycle(&labels, cycle);
    assert_eq!(verdict, VerdictV1::Unsupported, "{reason}");
    assert!(reason.contains("混合模式"));
}

/// 交替目标：红方循环内长捉两个不同子（马与车）→ 明确不支持。
#[test]
fn alternating_targets_is_unsupported() {
    use xiangqi_core::{ChaseTargetV1, PlyClassV1, WxfPlyLabelV1, adjudication::classify_cycle};
    let chase = |id| {
        PlyClassV1::Chase(ChaseTargetV1 {
            target_id: PieceId(id),
            target_kind: PieceKind::Horse,
            protected: false,
            trade_favorable: true,
        })
    };
    let label = |side, class| WxfPlyLabelV1 {
        schema_version: 1,
        mover: side,
        mv: xiangqi_core::Move::new(square(4, 1), square(4, 2)).unwrap(),
        class,
        was_evading: false,
        resolved_check: false,
    };
    let cycle = xiangqi_core::CycleV1 {
        start_ply: 1,
        end_ply: 4,
        ply_count: 4,
        repeat_count: 3,
    };
    let labels = vec![
        label(Side::Red, chase(1)),
        label(Side::Black, PlyClassV1::Idle),
        label(Side::Red, chase(2)),
        label(Side::Black, PlyClassV1::Idle),
    ];
    let (verdict, reason) = classify_cycle(&labels, cycle);
    assert_eq!(verdict, VerdictV1::Unsupported, "{reason}");
}

/// 兑：循环内红方“兑”对黑方“闲” → 混合模式，明确不支持（快照未收录
/// 兑与闲的完整优先级表）。
#[test]
fn exchange_versus_idle_is_unsupported() {
    use xiangqi_core::{PlyClassV1, WxfPlyLabelV1, adjudication::classify_cycle};
    let label = |side, class| WxfPlyLabelV1 {
        schema_version: 1,
        mover: side,
        mv: xiangqi_core::Move::new(square(4, 1), square(4, 2)).unwrap(),
        class,
        was_evading: false,
        resolved_check: false,
    };
    let cycle = xiangqi_core::CycleV1 {
        start_ply: 1,
        end_ply: 4,
        ply_count: 4,
        repeat_count: 3,
    };
    let labels = vec![
        label(Side::Red, PlyClassV1::Exchange),
        label(Side::Black, PlyClassV1::Idle),
        label(Side::Red, PlyClassV1::Exchange),
        label(Side::Black, PlyClassV1::Idle),
    ];
    let (verdict, reason) = classify_cycle(&labels, cycle);
    assert_eq!(verdict, VerdictV1::Unsupported, "{reason}");
}

/// Undo/branch restores per-ply labels: labels live in variation nodes, so
/// undo then redo reproduces the exact adjudication.
#[test]
fn undo_redo_preserves_adjudication_evidence() {
    let mut game = setup(&[
        RED_GENERAL,
        BLACK_GENERAL,
        (Side::Red, PieceKind::Rook, 0, 9),
        (Side::Red, PieceKind::Pawn, 4, 5),
    ])
    .unwrap();
    apply(
        &mut game,
        &[
            "a9b9", "e9e8", "b9b8", "e8e9", "b8b9", "e9e8", "b9b8", "e8e9", "b8b9",
        ],
    )
    .unwrap();
    let before = game.adjudicate_current().unwrap();
    let before_hash = game.repetition_hash();
    game.undo().unwrap();
    game.redo().unwrap();
    assert_eq!(game.repetition_hash(), before_hash);
    assert_eq!(game.adjudicate_current().unwrap(), before);
}

/// Profile switch at the root re-seeds repetition identity; switching after
/// moves is rejected transactionally.
#[test]
fn profile_switch_at_root_only() {
    use xiangqi_core::{GameError, RuleProfile};
    let mut game = Game::standard_with_profile(RuleProfile::BaseV1).unwrap();
    let base_hash = game.repetition_hash();
    game.set_profile(RuleProfile::WxfV1).unwrap();
    assert_eq!(game.profile(), RuleProfile::WxfV1);
    assert_ne!(game.repetition_hash(), base_hash);
    game.apply_move(xiangqi_core::Move::new(square(0, 3), square(0, 4)).unwrap())
        .unwrap();
    assert_eq!(
        game.set_profile(RuleProfile::BaseV1),
        Err(GameError::ProfileChangeNotAllowed)
    );
    assert_eq!(game.profile(), RuleProfile::WxfV1);
}
