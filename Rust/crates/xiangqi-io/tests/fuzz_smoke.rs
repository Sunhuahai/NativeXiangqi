//! Deterministic, bounded smoke fuzzing for the strict interchange codecs.
//!
//! This is intentionally not an unbounded fuzz target. The `make fuzz-smoke`
//! contract supplies a wall-clock deadline; this test independently fixes input
//! count and byte length so it remains safe for ordinary offline CI.

use xiangqi_core::{Game, STANDARD_INITIAL_FEN};
use xiangqi_io::{
    FenError, MAX_FEN_BYTES, UcciError, apply_ucci_mainline, parse_fen, write_fen,
    write_ucci_mainline,
};

const FUZZ_CASES: usize = 512;
const MAX_GENERATED_INPUT_BYTES: usize = 1_024;
const DETERMINISTIC_SEED: u64 = 0x84a3_5ef1_019c_7d2b;

struct XorShift64 {
    state: u64,
}

impl XorShift64 {
    const fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    fn next_u64(&mut self) -> u64 {
        self.state ^= self.state << 7;
        self.state ^= self.state >> 9;
        self.state ^= self.state << 8;
        self.state
    }

    fn next_index(&mut self, upper_bound: usize) -> usize {
        debug_assert!(upper_bound > 0);
        (self.next_u64() as usize) % upper_bound
    }
}

fn generated_ascii(generator: &mut XorShift64) -> String {
    let length = generator.next_index(MAX_GENERATED_INPUT_BYTES + 1);
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(length)
        .expect("fixed 1 KiB fuzz input reserve");
    for _ in 0..length {
        // Deliberately includes whitespace and punctuation, while remaining valid UTF-8.
        bytes.push(0x20 + (generator.next_u64() % 0x5f) as u8);
    }
    String::from_utf8(bytes).expect("ASCII generator must produce UTF-8")
}

#[test]
fn deterministic_fen_and_ucci_mutations_are_bounded_and_transactional() {
    let mut generator = XorShift64::new(DETERMINISTIC_SEED);
    let seeded_inputs = [
        STANDARD_INITIAL_FEN.to_owned(),
        "4k4/4a4/9/9/9/9/9/9/4A4/4K4 w - - 0 1".to_owned(),
        "not a fen".to_owned(),
        "b2b3 b7b6".to_owned(),
        "b2b3 a0a9".to_owned(),
        "将".to_owned(),
    ];

    for case_index in 0..FUZZ_CASES {
        let input = seeded_inputs
            .get(case_index)
            .cloned()
            .unwrap_or_else(|| generated_ascii(&mut generator));
        assert!(
            input.len() <= MAX_GENERATED_INPUT_BYTES,
            "generated input {case_index} exceeded its explicit byte bound"
        );

        if let Ok(parsed) = parse_fen(&input) {
            let canonical = write_fen(&parsed).expect("accepted FEN must serialize");
            let reparsed = parse_fen(&canonical).expect("serialized FEN must parse");
            assert_eq!(
                parsed.canonical_position_bytes(),
                reparsed.canonical_position_bytes(),
                "FEN case {case_index} changed canonical state during a round trip"
            );
        }

        let mut game = Game::standard().expect("standard game");
        let before = game.position_digest();
        match apply_ucci_mainline(&mut game, &input) {
            Ok(plies) => {
                assert!(
                    plies > 0,
                    "successful UCCI case {case_index} must have plies"
                );
                let encoded = write_ucci_mainline(&game).expect("accepted UCCI must serialize");
                let mut replay = Game::standard().expect("standard replay game");
                assert_eq!(
                    apply_ucci_mainline(&mut replay, &encoded)
                        .expect("serialized UCCI must replay"),
                    plies,
                    "UCCI case {case_index} changed its accepted ply count"
                );
                assert_eq!(
                    game.position_digest(),
                    replay.position_digest(),
                    "UCCI case {case_index} changed canonical state during a round trip"
                );
            }
            Err(_) => assert_eq!(
                game.position_digest(),
                before,
                "rejected UCCI case {case_index} partially changed the game"
            ),
        }
    }
}

#[test]
fn fixed_limit_and_non_ascii_cases_keep_typed_failures_and_unchanged_state() {
    assert!(matches!(
        parse_fen(&"x".repeat(MAX_FEN_BYTES + 1)),
        Err(FenError::TooLong)
    ));
    assert!(matches!(parse_fen("将"), Err(FenError::NonAscii)));

    let mut game = Game::standard().expect("standard game");
    let before = game.position_digest();
    assert!(matches!(
        apply_ucci_mainline(&mut game, "b2b3 a0a9"),
        Err(UcciError::IllegalMove { ply: 2, .. })
    ));
    assert_eq!(game.position_digest(), before);
}
