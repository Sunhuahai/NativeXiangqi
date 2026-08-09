//! Versioned deterministic Zobrist-style hashing without external inputs.

use crate::{Piece, Side, Square, position::Position};

/// Bump only with a reviewed migration of stored position identities.
pub const HASH_SCHEME_VERSION: u32 = 1;

const HASH_SEED: u64 = 0x4e_61_74_69_76_65_58_71;

const fn splitmix64(mut value: u64) -> u64 {
    value = value.wrapping_add(0x9e37_79b9_7f4a_7c15);
    value = (value ^ (value >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    value = (value ^ (value >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    value ^ (value >> 31)
}

#[must_use]
pub(crate) const fn piece_key(piece: Piece, square: Square) -> u64 {
    let discriminator =
        ((piece.side as u64) << 12) | ((piece.kind as u64) << 8) | square.raw() as u64;
    splitmix64(HASH_SEED ^ discriminator)
}

#[must_use]
pub(crate) const fn side_to_move_key() -> u64 {
    splitmix64(HASH_SEED ^ 0x5349_4445_5f54_4f4d)
}

#[must_use]
pub(crate) fn recompute_position_hash(position: &Position) -> u64 {
    let mut hash = 0_u64;
    for raw_square in 0..crate::limits::BOARD_SQUARES as u8 {
        if let Some(square) = Square::new(raw_square)
            && let Some(piece) = position.piece_at(square)
        {
            hash ^= piece_key(piece, square);
        }
    }
    if position.side_to_move() == Side::Black {
        hash ^= side_to_move_key();
    }
    hash
}

#[must_use]
pub(crate) const fn next_repetition_hash(
    previous: u64,
    position_hash: u64,
    event_fingerprint: u64,
) -> u64 {
    splitmix64(previous ^ position_hash.rotate_left(17) ^ event_fingerprint.rotate_right(9))
}
