//! Strict FEN and UCCI codecs for the canonical Rust rules state.
//!
//! Parsing never mutates a caller's game until the entire bounded input has been validated.

#![forbid(unsafe_code)]

mod fen;
mod ucci;

pub use fen::{FenError, MAX_FEN_BYTES, parse_fen, write_fen};
pub use ucci::{
    MAX_UCCI_BYTES, MAX_UCCI_PLIES, UcciError, apply_ucci_mainline, parse_ucci_move,
    write_ucci_mainline, write_ucci_move,
};
