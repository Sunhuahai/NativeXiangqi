//! Strict Xiangqi FEN codec using the canonical UCCI coordinate convention.

use std::{error::Error, fmt};

use xiangqi_core::{Game, GameError, PieceKind, SetupPiece, Side, Square};

/// FEN is intentionally small; positions are not a user-controlled unbounded payload.
pub const MAX_FEN_BYTES: usize = 4 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FenError {
    TooLong,
    NonAscii,
    FieldCount,
    Placement,
    SideToMove,
    Placeholder,
    Halfmove,
    Fullmove,
    Core(GameError),
}

impl fmt::Display for FenError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TooLong => formatter.write_str("FEN exceeds its byte limit"),
            Self::NonAscii => formatter.write_str("FEN must be ASCII"),
            Self::FieldCount => {
                formatter.write_str("FEN must contain exactly six single-space fields")
            }
            Self::Placement => formatter.write_str("FEN board placement is invalid"),
            Self::SideToMove => formatter.write_str("FEN side-to-move must be w or b"),
            Self::Placeholder => formatter.write_str("FEN third and fourth fields must be -"),
            Self::Halfmove => formatter.write_str("FEN halfmove counter is invalid"),
            Self::Fullmove => formatter.write_str("FEN fullmove counter is invalid"),
            Self::Core(error) => write!(
                formatter,
                "FEN violates Xiangqi position invariants: {error}"
            ),
        }
    }
}

impl Error for FenError {}

fn parse_decimal(value: &str) -> Option<u32> {
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    value.parse::<u32>().ok()
}

fn parse_piece(byte: u8) -> Option<(Side, PieceKind)> {
    let side = if byte.is_ascii_uppercase() {
        Side::Red
    } else if byte.is_ascii_lowercase() {
        Side::Black
    } else {
        return None;
    };
    let kind = match byte.to_ascii_lowercase() {
        b'k' => PieceKind::General,
        b'a' => PieceKind::Advisor,
        b'b' => PieceKind::Elephant,
        b'n' => PieceKind::Horse,
        b'r' => PieceKind::Rook,
        b'c' => PieceKind::Cannon,
        b'p' => PieceKind::Pawn,
        _ => return None,
    };
    Some((side, kind))
}

/// Parses exactly six canonical FEN fields. FEN rank text runs Black rank 9 to Red rank 0.
pub fn parse_fen(input: &str) -> Result<Game, FenError> {
    if input.len() > MAX_FEN_BYTES {
        return Err(FenError::TooLong);
    }
    if !input.is_ascii() {
        return Err(FenError::NonAscii);
    }
    if input.is_empty() || input.starts_with(' ') || input.ends_with(' ') || input.contains("  ") {
        return Err(FenError::FieldCount);
    }
    let fields: Vec<&str> = input.split(' ').collect();
    if fields.len() != 6 {
        return Err(FenError::FieldCount);
    }
    let ranks: Vec<&str> = fields[0].split('/').collect();
    if ranks.len() != 10 || ranks.iter().any(|rank| rank.is_empty()) {
        return Err(FenError::Placement);
    }
    let mut pieces = Vec::new();
    pieces
        .try_reserve_exact(32)
        .map_err(|_| FenError::Placement)?;
    for (fen_rank_index, rank_text) in ranks.into_iter().enumerate() {
        let rank = 9_u8
            .checked_sub(fen_rank_index as u8)
            .ok_or(FenError::Placement)?;
        let mut file = 0_u8;
        for byte in rank_text.bytes() {
            if byte.is_ascii_digit() {
                if byte == b'0' {
                    return Err(FenError::Placement);
                }
                file = file.checked_add(byte - b'0').ok_or(FenError::Placement)?;
            } else {
                let (side, kind) = parse_piece(byte).ok_or(FenError::Placement)?;
                let square = Square::from_file_rank(file, rank).ok_or(FenError::Placement)?;
                pieces.push(SetupPiece { square, side, kind });
                file = file.checked_add(1).ok_or(FenError::Placement)?;
            }
            if file > 9 {
                return Err(FenError::Placement);
            }
        }
        if file != 9 {
            return Err(FenError::Placement);
        }
    }
    let side = match fields[1] {
        "w" => Side::Red,
        "b" => Side::Black,
        _ => return Err(FenError::SideToMove),
    };
    if fields[2] != "-" || fields[3] != "-" {
        return Err(FenError::Placeholder);
    }
    let halfmove = parse_decimal(fields[4]).ok_or(FenError::Halfmove)?;
    let fullmove = parse_decimal(fields[5])
        .filter(|value| *value != 0)
        .ok_or(FenError::Fullmove)?;
    Game::from_setup(side, &pieces, halfmove, fullmove).map_err(FenError::Core)
}

/// Writes the current canonical state as exactly six UCCI-compatible FEN fields.
pub fn write_fen(game: &Game) -> Result<String, GameError> {
    let mut result = String::new();
    result
        .try_reserve_exact(128)
        .map_err(|_| GameError::HistoryLimit)?;
    for rank in (0_u8..10).rev() {
        let mut empty = 0_u8;
        for file in 0_u8..9 {
            let square = Square::from_file_rank(file, rank).ok_or(GameError::InternalInvariant)?;
            match game.piece_at(square) {
                None => empty = empty.saturating_add(1),
                Some(piece) => {
                    if empty != 0 {
                        result.push(char::from(b'0' + empty));
                        empty = 0;
                    }
                    let mut letter = piece.kind.fen_letter();
                    if piece.side == Side::Red {
                        letter = letter.to_ascii_uppercase();
                    }
                    result.push(char::from(letter));
                }
            }
        }
        if empty != 0 {
            result.push(char::from(b'0' + empty));
        }
        if rank != 0 {
            result.push('/');
        }
    }
    result.push(' ');
    result.push(match game.side_to_move() {
        Side::Red => 'w',
        Side::Black => 'b',
    });
    result.push_str(" - - ");
    result.push_str(&game.halfmove_clock().to_string());
    result.push(' ');
    result.push_str(&game.fullmove_number().to_string());
    Ok(result)
}
