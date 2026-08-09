use xiangqi_core::{
    Game, GameError, MAX_ANNOTATION_BYTES_PER_NODE, MAX_POSITION_HISTORY, MAX_VARIATION_NODES,
    NodeId, STANDARD_INITIAL_FEN, Side, Square, TerminalState,
};
use xiangqi_io::{
    FenError, MAX_FEN_BYTES, MAX_UCCI_PLIES, UcciError, apply_ucci_mainline, parse_fen,
    parse_ucci_move, write_fen, write_ucci_mainline,
};

const PERFT_FIXTURES: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../Tests/Fixtures/xiangqi-perft-v1.txt"
));

fn square(text: &str) -> Square {
    let bytes = text.as_bytes();
    Square::from_file_rank(bytes[0] - b'a', bytes[1] - b'0').expect("fixed fixture square")
}

fn ucci_set(game: &Game, from: &str) -> Vec<String> {
    let mut result: Vec<String> = game
        .legal_destinations(square(from))
        .expect("fixture legal move generation")
        .into_iter()
        .map(|to| format!("{from}{to}"))
        .collect();
    result.sort();
    result
}

#[test]
fn fixed_perft_corpus_is_independent_of_runtime_generation() {
    for line in PERFT_FIXTURES
        .lines()
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
    {
        let fields: Vec<&str> = line.split('|').collect();
        assert_eq!(fields.len(), 4, "malformed fixed corpus row: {line}");
        let game = parse_fen(fields[1]).expect("fixed corpus FEN must parse");
        let depth = fields[2].parse::<u8>().expect("fixture depth");
        let expected = fields[3].parse::<u64>().expect("fixture node count");
        assert_eq!(
            game.perft(depth).expect("bounded perft"),
            expected,
            "fixture {}",
            fields[0]
        );
    }
}

#[test]
#[ignore = "benchmark-only: fixed initial-position depth 5"]
fn fixed_initial_perft_depth_five() {
    let game = Game::standard().expect("standard game");
    let started = std::time::Instant::now();
    let nodes = game.perft(5).expect("bounded depth-five perft");
    assert_eq!(nodes, 133_312_995);
    eprintln!(
        "initial-position depth-5 perft: {nodes} nodes in {:?}",
        started.elapsed()
    );
}

#[test]
fn standard_fen_and_ucci_coordinate_convention_round_trip() {
    let game = Game::standard().expect("standard game");
    assert_eq!(
        write_fen(&game).expect("standard FEN write"),
        STANDARD_INITIAL_FEN
    );
    assert_eq!(
        write_fen(&parse_fen(STANDARD_INITIAL_FEN).expect("standard FEN"))
            .expect("parsed FEN write"),
        STANDARD_INITIAL_FEN
    );
    assert_eq!(
        parse_ucci_move("h2e2").expect("canonical UCCI").to_string(),
        "h2e2"
    );
    assert!(parse_ucci_move("H2E2").is_none());
    assert!(parse_ucci_move("a0a0").is_none());
}

#[test]
fn piece_boundaries_obstacles_cannon_screens_and_river_rules_hold() {
    let horse = parse_fen("4k4/4a4/9/9/9/4N4/9/9/9/4K4 w - - 0 1").expect("horse FEN");
    assert_eq!(
        ucci_set(&horse, "e4"),
        [
            "e4c3", "e4c5", "e4d2", "e4d6", "e4f2", "e4f6", "e4g3", "e4g5"
        ]
    );
    let horse_leg = parse_fen("4k4/4a4/9/9/4P4/4N4/9/9/9/4K4 w - - 0 1").expect("horse-leg FEN");
    assert!(!ucci_set(&horse_leg, "e4").contains(&"e4d6".to_owned()));
    assert!(!ucci_set(&horse_leg, "e4").contains(&"e4f6".to_owned()));

    let elephant = parse_fen("4k4/4a4/9/9/9/9/9/4B4/9/4K4 w - - 0 1").expect("elephant FEN");
    assert_eq!(ucci_set(&elephant, "e2"), ["e2c0", "e2c4", "e2g0", "e2g4"]);
    let elephant_eye =
        parse_fen("4k4/4a4/9/9/9/9/3P5/4B4/9/4K4 w - - 0 1").expect("elephant-eye FEN");
    assert!(!ucci_set(&elephant_eye, "e2").contains(&"e2c4".to_owned()));
    let elephant_river =
        parse_fen("4k4/4a4/9/9/9/4B4/9/9/9/4K4 w - - 0 1").expect("elephant-river FEN");
    assert_eq!(ucci_set(&elephant_river, "e4"), ["e4c2", "e4g2"]);

    let advisor = parse_fen("4k4/4a4/9/9/9/9/9/9/4A4/4K4 w - - 0 1").expect("advisor FEN");
    assert_eq!(ucci_set(&advisor, "e1"), ["e1d0", "e1d2", "e1f0", "e1f2"]);

    let crossed_pawn =
        parse_fen("4k4/4a4/9/9/4P4/9/9/9/9/4K4 w - - 0 1").expect("crossed pawn FEN");
    assert_eq!(ucci_set(&crossed_pawn, "e5"), ["e5d5", "e5e6", "e5f5"]);
    let one_screen = parse_fen("4k4/r3a4/9/P8/9/C8/9/9/9/4K4 w - - 0 1").expect("one screen FEN");
    assert!(ucci_set(&one_screen, "a4").contains(&"a4a8".to_owned()));
    let two_screens =
        parse_fen("4k4/r3a4/9/p8/P8/C8/9/9/9/4K4 w - - 0 1").expect("two screens FEN");
    assert!(!ucci_set(&two_screens, "a4").contains(&"a4a8".to_owned()));
    assert!(ucci_set(&two_screens, "a4").contains(&"a4a6".to_owned()));
}

#[test]
fn general_palace_rook_rays_and_all_check_responses_are_legal() {
    let bare = parse_fen("4k4/4a4/9/9/9/9/9/9/9/4K4 w - - 0 1").expect("bare FEN");
    assert_eq!(ucci_set(&bare, "e0"), ["e0d0", "e0e1", "e0f0"]);

    let rook_blocked =
        parse_fen("4k4/4a4/9/3P5/9/3R5/9/9/9/4K4 w - - 0 1").expect("rook blocker FEN");
    let blocked_rays = ucci_set(&rook_blocked, "d4");
    assert!(blocked_rays.contains(&"d4d5".to_owned()));
    assert!(!blocked_rays.contains(&"d4d6".to_owned()));
    assert!(!blocked_rays.contains(&"d4d7".to_owned()));

    let rook_capture =
        parse_fen("4k4/4a4/9/3r5/9/3R5/9/9/9/4K4 w - - 0 1").expect("rook capture FEN");
    let capture_rays = ucci_set(&rook_capture, "d4");
    assert!(capture_rays.contains(&"d4d6".to_owned()));
    assert!(!capture_rays.contains(&"d4d7".to_owned()));

    let mut escape = parse_fen("4k4/4a4/9/9/4r4/9/9/9/9/4K4 w - - 0 1").expect("check escape FEN");
    assert!(escape.is_in_check(Side::Red));
    assert!(ucci_set(&escape, "e0").contains(&"e0d0".to_owned()));
    escape
        .apply_move(parse_ucci_move("e0d0").expect("escape move"))
        .expect("general escapes check");
    assert!(!escape.is_in_check(Side::Red));

    let mut capture =
        parse_fen("4k4/4a4/9/9/9/9/9/5nR2/9/4K4 w - - 0 1").expect("check capture FEN");
    assert!(capture.is_in_check(Side::Red));
    assert!(ucci_set(&capture, "g2").contains(&"g2f2".to_owned()));
    capture
        .apply_move(parse_ucci_move("g2f2").expect("capture move"))
        .expect("rook captures checking horse");
    assert!(!capture.is_in_check(Side::Red));

    let mut block = parse_fen("4k4/4a4/9/9/4r4/3R5/9/9/9/4K4 w - - 0 1").expect("check block FEN");
    assert!(block.is_in_check(Side::Red));
    assert!(ucci_set(&block, "d4").contains(&"d4e4".to_owned()));
    block
        .apply_move(parse_ucci_move("d4e4").expect("block move"))
        .expect("rook blocks check");
    assert!(!block.is_in_check(Side::Red));
}

#[test]
fn flying_general_self_check_checkmate_and_stalemate_are_distinct() {
    let mut flying =
        parse_fen("4k4/9/9/9/4R4/9/9/9/9/4K4 w - - 0 1").expect("flying-general blocker FEN");
    let before = flying.canonical_position_bytes();
    assert_eq!(
        flying.apply_move(parse_ucci_move("e5d5").expect("move")),
        Err(GameError::IllegalMove)
    );
    assert_eq!(flying.canonical_position_bytes(), before);

    let mate = parse_fen("3RkR3/9/4P4/9/9/9/9/9/9/4K4 b - - 0 1").expect("mate FEN");
    assert!(mate.is_in_check(Side::Black));
    assert_eq!(
        mate.terminal_state(),
        TerminalState::Checkmate { winner: Side::Red }
    );
    let stale = parse_fen("4k4/4a4/3R1R3/9/9/9/9/9/9/4K4 b - - 0 1").expect("stalemate FEN");
    assert!(!stale.is_in_check(Side::Black));
    assert_eq!(
        stale.terminal_state(),
        TerminalState::Stalemate { winner: Side::Red }
    );
}

#[test]
fn apply_undo_redo_branches_and_hashes_restore_the_active_state_exactly() {
    let mut game = Game::standard().expect("standard game");
    let original = game.position_digest();
    let original_bytes = game.canonical_position_bytes();
    let first = game
        .apply_move(parse_ucci_move("b2b3").expect("move"))
        .expect("apply");
    assert_eq!(game.position_hash(), game.recompute_position_hash());
    game.undo().expect("undo");
    assert_eq!(game.position_digest(), original);
    assert_eq!(game.canonical_position_bytes(), original_bytes);
    assert_eq!(game.redo().expect("redo"), first);
    assert_eq!(game.position_hash(), game.recompute_position_hash());
    game.undo().expect("undo again");
    let alternate = game
        .apply_move(parse_ucci_move("h2h3").expect("move"))
        .expect("alternate branch");
    let children = game.children(NodeId::ROOT).expect("children");
    assert_eq!(children, vec![first, alternate]);
    game.navigate(first).expect("navigate first branch");
    assert_eq!(
        write_ucci_mainline(&game).expect("first branch UCCI write"),
        "b2b3"
    );
    game.navigate(alternate).expect("navigate alternate branch");
    assert_eq!(
        write_ucci_mainline(&game).expect("alternate branch UCCI write"),
        "h2h3"
    );
}

#[test]
fn capture_apply_and_undo_restore_counters_history_events_and_hashes() {
    let mut game =
        parse_fen("4k4/4a4/9/9/9/3p5/3R5/9/9/4K4 w - - 7 42").expect("capture fixture FEN");
    let before_digest = game.position_digest();
    let before_bytes = game.canonical_position_bytes();
    let before_history = game.history_summary().expect("initial history summary");
    let node = game
        .apply_move(parse_ucci_move("d3d4").expect("capture move"))
        .expect("capture applies");
    let event = game
        .event_for_node(node)
        .expect("capture node")
        .expect("capture event");
    assert_eq!(event.captured_kind, Some(xiangqi_core::PieceKind::Pawn));
    assert_eq!(game.halfmove_clock(), 0);
    assert_eq!(game.fullmove_number(), 42);
    assert_eq!(
        game.history_summary().expect("capture history").event_count,
        1
    );
    assert_eq!(game.position_hash(), game.recompute_position_hash());

    game.undo().expect("capture undo");
    assert_eq!(game.position_digest(), before_digest);
    assert_eq!(game.canonical_position_bytes(), before_bytes);
    assert_eq!(
        game.history_summary().expect("restored history"),
        before_history
    );
    assert_eq!(
        game.event_for_node(node).expect("retained capture node"),
        Some(event)
    );
    assert_eq!(game.position_hash(), game.recompute_position_hash());
}

#[test]
fn variation_node_limit_rejects_the_next_ply_without_mutating_history() {
    let mut game =
        parse_fen("4k4/4a4/9/9/9/4P4/9/9/4A4/4K4 w - - 0 1").expect("reversible advisor-cycle FEN");
    let cycle = ["e1d0", "e8d7", "d0e1", "d7e8"]
        .map(|text| parse_ucci_move(text).expect("fixed reversible advisor-cycle move"));
    for step in 0..(MAX_VARIATION_NODES - 1) {
        game.apply_move(cycle[step % cycle.len()])
            .expect("bounded reversible cycle move");
    }
    let before = game.position_digest();
    let history = game.history_summary().expect("bounded history summary");
    assert_eq!(history.position_count as usize, MAX_VARIATION_NODES);
    assert!((history.position_count as usize) <= MAX_POSITION_HISTORY);
    assert_eq!(
        game.apply_move(cycle[(MAX_VARIATION_NODES - 1) % cycle.len()]),
        Err(GameError::NodeLimit)
    );
    assert_eq!(game.position_digest(), before);
}

#[test]
fn deterministic_random_apply_undo_keeps_incremental_hash_and_history_consistent() {
    let mut game = Game::standard().expect("standard game");
    let mut seed = 0x8f3d_1a4b_5c6d_7e9f_u64;
    let mut before = Vec::new();
    for _ in 0..160 {
        let legal = game.legal_moves().expect("legal moves");
        if legal.is_empty() {
            break;
        }
        before.push(game.position_digest());
        seed ^= seed << 7;
        seed ^= seed >> 9;
        seed ^= seed << 8;
        let choice = (seed as usize) % legal.len();
        game.apply_move(legal[choice]).expect("random legal move");
        assert_eq!(game.position_hash(), game.recompute_position_hash());
    }
    for expected in before.into_iter().rev() {
        game.undo().expect("undo random move");
        assert_eq!(game.position_digest(), expected);
        assert_eq!(game.position_hash(), game.recompute_position_hash());
    }
    assert!(
        !game
            .history_summary()
            .expect("consistent history summary")
            .wxf_responsibility_supported
    );
}

#[test]
fn strict_fen_and_transactional_ucci_reject_bad_input_without_mutation() {
    assert!(matches!(
        parse_fen("4k4/9/9/9/9/9/9/9/9/4K4 w - - 0 1"),
        Err(FenError::Core(_))
    ));
    assert!(matches!(
        parse_fen("rheakaehr/9/9/9/9/9/9/9/9/RHEAKAEHR w - - 0 1"),
        Err(FenError::Placement)
    ));
    assert!(matches!(
        parse_fen("4k4/9/9/9/9/9/9/9/9/4K4 w - - 0 1 trailing"),
        Err(FenError::FieldCount)
    ));
    assert!(matches!(
        parse_fen("4k4/4a4/9/9/9/9/9/9/A8/4K4 w - - 0 1"),
        Err(FenError::Core(_))
    ));
    assert!(matches!(
        parse_fen("4k4/4a4/9/9/4B4/9/9/9/9/4K4 w - - 0 1"),
        Err(FenError::Core(_))
    ));
    assert!(matches!(
        parse_fen("4k4/4a4/9/9/9/9/9/4P4/9/4K4 w - - 0 1"),
        Err(FenError::Core(_))
    ));
    assert!(matches!(
        parse_fen(&"x".repeat(MAX_FEN_BYTES + 1)),
        Err(FenError::TooLong)
    ));
    let mut game = Game::standard().expect("standard game");
    let digest = game.position_digest();
    let bytes = game.canonical_position_bytes();
    assert!(matches!(
        apply_ucci_mainline(&mut game, "b2b3 b7b6 a0a9"),
        Err(UcciError::IllegalMove { ply: 3, .. })
    ));
    assert_eq!(game.position_digest(), digest);
    assert_eq!(game.canonical_position_bytes(), bytes);
    let too_many_tokens = "a0a1 ".repeat(MAX_UCCI_PLIES + 1);
    assert_eq!(
        apply_ucci_mainline(&mut game, &too_many_tokens),
        Err(UcciError::TooManyPlies)
    );
    assert_eq!(game.position_digest(), digest);
    assert_eq!(game.canonical_position_bytes(), bytes);
    assert_eq!(
        apply_ucci_mainline(&mut game, "b2b3 b7b6").expect("valid transactional mainline"),
        2
    );
    assert_eq!(
        write_ucci_mainline(&game).expect("valid mainline write"),
        "b2b3 b7b6"
    );
}

#[test]
fn annotation_limit_is_typed_and_nonmutating_for_position_state() {
    let mut game = Game::standard().expect("standard game");
    let before = game.position_digest();
    let too_long = "x".repeat(MAX_ANNOTATION_BYTES_PER_NODE + 1);
    assert_eq!(
        game.set_annotation(NodeId::ROOT, &too_long),
        Err(GameError::AnnotationTooLong)
    );
    assert_eq!(game.position_digest(), before);
}
