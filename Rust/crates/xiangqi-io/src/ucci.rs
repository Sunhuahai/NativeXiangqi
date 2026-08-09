//! Bounded UCCI coordinate conversion and transactional mainline import.

use std::{error::Error, fmt};

use xiangqi_core::{Game, GameError, Move, Square};

pub const MAX_UCCI_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_UCCI_PLIES: usize = 4_096;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum UcciError {
    TooLong,
    NonAscii,
    EmptyMainline,
    TooManyPlies,
    InvalidCoordinate { ply: u32 },
    IllegalMove { ply: u32, source: GameError },
}

impl UcciError {
    #[must_use]
    pub const fn failing_ply(&self) -> Option<u32> {
        match self {
            Self::InvalidCoordinate { ply } | Self::IllegalMove { ply, .. } => Some(*ply),
            Self::TooLong | Self::NonAscii | Self::EmptyMainline | Self::TooManyPlies => None,
        }
    }
}

impl fmt::Display for UcciError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TooLong => formatter.write_str("UCCI input exceeds its byte limit"),
            Self::NonAscii => formatter.write_str("UCCI input must be ASCII"),
            Self::EmptyMainline => formatter.write_str("UCCI mainline is empty"),
            Self::TooManyPlies => formatter.write_str("UCCI mainline exceeds its ply limit"),
            Self::InvalidCoordinate { ply } => {
                write!(formatter, "invalid UCCI coordinate at ply {ply}")
            }
            Self::IllegalMove { ply, source } => {
                write!(formatter, "illegal UCCI move at ply {ply}: {source}")
            }
        }
    }
}

impl Error for UcciError {}

/// Parses one exact lower-case four-byte UCCI coordinate move, for example `h2e2`.
pub fn parse_ucci_move(token: &str) -> Option<Move> {
    let bytes = token.as_bytes();
    if bytes.len() != 4
        || !(b'a'..=b'i').contains(&bytes[0])
        || !bytes[1].is_ascii_digit()
        || !(b'a'..=b'i').contains(&bytes[2])
        || !bytes[3].is_ascii_digit()
    {
        return None;
    }
    let from = Square::from_file_rank(bytes[0] - b'a', bytes[1] - b'0')?;
    let to = Square::from_file_rank(bytes[2] - b'a', bytes[3] - b'0')?;
    Move::new(from, to)
}

#[must_use]
pub fn write_ucci_move(mv: Move) -> String {
    mv.to_string()
}

/// Serializes the selected root-to-cursor variation using a single ASCII space separator.
pub fn write_ucci_mainline(game: &Game) -> Result<String, GameError> {
    let moves = game.mainline_moves()?;
    let mut text = String::new();
    text.try_reserve_exact(moves.len().saturating_mul(5))
        .map_err(|_| GameError::HistoryLimit)?;
    for (index, mv) in moves.into_iter().enumerate() {
        if index != 0 {
            text.push(' ');
        }
        text.push_str(&write_ucci_move(mv));
    }
    Ok(text)
}

/// Applies all UCCI plies to a cloned bounded state and commits only if every ply succeeds.
pub fn apply_ucci_mainline(game: &mut Game, input: &str) -> Result<u32, UcciError> {
    if input.len() > MAX_UCCI_BYTES {
        return Err(UcciError::TooLong);
    }
    if !input.is_ascii() {
        return Err(UcciError::NonAscii);
    }
    let token_count = input
        .split_ascii_whitespace()
        .take(MAX_UCCI_PLIES.saturating_add(1))
        .count();
    if token_count == 0 {
        return Err(UcciError::EmptyMainline);
    }
    if token_count > MAX_UCCI_PLIES {
        return Err(UcciError::TooManyPlies);
    }
    let accepted_plies = u32::try_from(token_count).map_err(|_| UcciError::TooManyPlies)?;
    let mut candidate = game.clone();
    for (index, token) in input.split_ascii_whitespace().enumerate() {
        let ply = u32::try_from(index + 1).map_err(|_| UcciError::TooManyPlies)?;
        let mv = parse_ucci_move(token).ok_or(UcciError::InvalidCoordinate { ply })?;
        candidate
            .apply_move(mv)
            .map_err(|source| UcciError::IllegalMove { ply, source })?;
    }
    *game = candidate;
    Ok(accepted_plies)
}
