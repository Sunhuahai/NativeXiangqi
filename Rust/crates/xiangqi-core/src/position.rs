//! Fixed 90-square canonical position and reversible board mutation primitives.

use crate::{
    GameError, Move, Piece, PieceId, PieceKind, SetupPiece, Side, Square,
    hash::{piece_key, recompute_position_hash, side_to_move_key},
    limits::{BOARD_RANKS, BOARD_SQUARES},
};

/// State restored exactly by a variation-tree undo frame.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct AppliedMove {
    pub mv: Move,
    pub moved: Piece,
    pub captured: Option<Piece>,
    pub previous_side_to_move: Side,
    pub previous_halfmove_clock: u32,
    pub previous_fullmove_number: u32,
    pub previous_position_hash: u64,
}

/// The mutable portion of a game position. Tree/history metadata belongs in `Game`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct Position {
    cells: [Option<Piece>; BOARD_SQUARES],
    side_to_move: Side,
    halfmove_clock: u32,
    fullmove_number: u32,
    position_hash: u64,
}

impl Position {
    pub(crate) fn from_setup(
        side_to_move: Side,
        pieces: &[SetupPiece],
        halfmove_clock: u32,
        fullmove_number: u32,
    ) -> Result<Self, GameError> {
        if fullmove_number == 0 {
            return Err(GameError::InvalidSetup("fullmove number must be nonzero"));
        }
        if pieces.len() > 32 {
            return Err(GameError::InvalidSetup("more than 32 physical pieces"));
        }

        let mut pending: [Option<(Side, PieceKind)>; BOARD_SQUARES] = [None; BOARD_SQUARES];
        let mut material = [[0_u8; 7]; 2];
        for setup in pieces {
            let index = setup.square.index();
            if pending[index].is_some() {
                return Err(GameError::InvalidSetup("multiple pieces occupy one square"));
            }
            let count = &mut material[setup.side.index()][setup.kind.index()];
            *count = count
                .checked_add(1)
                .ok_or(GameError::InvalidSetup("material overflow"))?;
            if *count > setup.kind.material_limit() {
                return Err(GameError::InvalidSetup(
                    "material exceeds a Xiangqi starting maximum",
                ));
            }
            pending[index] = Some((setup.side, setup.kind));
        }

        for side in Side::ALL {
            if material[side.index()][PieceKind::General.index()] != 1 {
                return Err(GameError::InvalidSetup(
                    "each side requires exactly one general",
                ));
            }
        }

        let mut cells = [None; BOARD_SQUARES];
        let mut next_id = 1_u8;
        for raw_square in 0..BOARD_SQUARES as u8 {
            if let Some((side, kind)) = pending[raw_square as usize] {
                let square = match Square::new(raw_square) {
                    Some(square) => square,
                    None => return Err(GameError::InternalInvariant),
                };
                if kind == PieceKind::General && !side.palace_contains(square.file(), square.rank())
                {
                    return Err(GameError::InvalidSetup("general is outside its palace"));
                }
                if kind == PieceKind::Advisor && !side.palace_contains(square.file(), square.rank())
                {
                    return Err(GameError::InvalidSetup("advisor is outside its palace"));
                }
                if kind == PieceKind::Elephant && !side.is_home_side_rank(square.rank()) {
                    return Err(GameError::InvalidSetup("elephant has crossed the river"));
                }
                if kind == PieceKind::Pawn
                    && match side {
                        Side::Red => square.rank() < 3,
                        Side::Black => square.rank() > 6,
                    }
                {
                    return Err(GameError::InvalidSetup("pawn is behind its starting rank"));
                }
                cells[raw_square as usize] = Some(Piece {
                    side,
                    kind,
                    id: PieceId(next_id),
                });
                next_id = next_id
                    .checked_add(1)
                    .ok_or(GameError::InvalidSetup("piece identifier overflow"))?;
            }
        }

        let mut position = Self {
            cells,
            side_to_move,
            halfmove_clock,
            fullmove_number,
            position_hash: 0,
        };
        if position.generals_face() {
            return Err(GameError::InvalidSetup("generals may not face each other"));
        }
        position.position_hash = recompute_position_hash(&position);
        Ok(position)
    }

    pub(crate) fn standard() -> Result<Self, GameError> {
        let mut pieces = Vec::with_capacity(32);
        let back_rank = [
            PieceKind::Rook,
            PieceKind::Horse,
            PieceKind::Elephant,
            PieceKind::Advisor,
            PieceKind::General,
            PieceKind::Advisor,
            PieceKind::Elephant,
            PieceKind::Horse,
            PieceKind::Rook,
        ];
        for (file, kind) in back_rank.into_iter().enumerate() {
            let file = file as u8;
            let red_square = Square::from_file_rank(file, 0).ok_or(GameError::InternalInvariant)?;
            let black_square = Square::from_file_rank(file, BOARD_RANKS - 1)
                .ok_or(GameError::InternalInvariant)?;
            pieces.push(SetupPiece {
                square: red_square,
                side: Side::Red,
                kind,
            });
            pieces.push(SetupPiece {
                square: black_square,
                side: Side::Black,
                kind,
            });
        }
        for file in [1_u8, 7] {
            pieces.push(SetupPiece {
                square: Square::from_file_rank(file, 2).ok_or(GameError::InternalInvariant)?,
                side: Side::Red,
                kind: PieceKind::Cannon,
            });
            pieces.push(SetupPiece {
                square: Square::from_file_rank(file, 7).ok_or(GameError::InternalInvariant)?,
                side: Side::Black,
                kind: PieceKind::Cannon,
            });
        }
        for file in [0_u8, 2, 4, 6, 8] {
            pieces.push(SetupPiece {
                square: Square::from_file_rank(file, 3).ok_or(GameError::InternalInvariant)?,
                side: Side::Red,
                kind: PieceKind::Pawn,
            });
            pieces.push(SetupPiece {
                square: Square::from_file_rank(file, 6).ok_or(GameError::InternalInvariant)?,
                side: Side::Black,
                kind: PieceKind::Pawn,
            });
        }
        Self::from_setup(Side::Red, &pieces, 0, 1)
    }

    #[must_use]
    pub(crate) const fn side_to_move(&self) -> Side {
        self.side_to_move
    }

    #[must_use]
    pub(crate) const fn halfmove_clock(&self) -> u32 {
        self.halfmove_clock
    }

    #[must_use]
    pub(crate) const fn fullmove_number(&self) -> u32 {
        self.fullmove_number
    }

    #[must_use]
    pub(crate) const fn position_hash(&self) -> u64 {
        self.position_hash
    }

    #[must_use]
    pub(crate) fn piece_at(&self, square: Square) -> Option<Piece> {
        self.cells[square.index()]
    }

    /// All occupied (square, piece) pairs, in canonical square order.
    #[must_use]
    pub(crate) fn pieces(&self) -> Vec<(Square, Piece)> {
        let mut result = Vec::with_capacity(32);
        for raw_square in 0..BOARD_SQUARES as u8 {
            if let Some(square) = Square::new(raw_square)
                && let Some(piece) = self.piece_at(square)
            {
                result.push((square, piece));
            }
        }
        result
    }

    /// The current square of one physical piece identity, if it is alive.
    #[must_use]
    pub(crate) fn square_of(&self, id: PieceId) -> Option<Square> {
        self.pieces()
            .into_iter()
            .find_map(|(square, piece)| (piece.id == id).then_some(square))
    }

    #[must_use]
    pub(crate) fn general_square(&self, side: Side) -> Option<Square> {
        for raw_square in 0..BOARD_SQUARES as u8 {
            let square = Square::new(raw_square)?;
            if let Some(piece) = self.piece_at(square)
                && piece.side == side
                && piece.kind == PieceKind::General
            {
                return Some(square);
            }
        }
        None
    }

    #[must_use]
    pub(crate) fn generals_face(&self) -> bool {
        let Some(red) = self.general_square(Side::Red) else {
            return false;
        };
        let Some(black) = self.general_square(Side::Black) else {
            return false;
        };
        red.file() == black.file() && self.clear_file_between(red, black)
    }

    #[must_use]
    pub(crate) fn clear_file_between(&self, first: Square, second: Square) -> bool {
        if first.file() != second.file() {
            return false;
        }
        let low = first.rank().min(second.rank());
        let high = first.rank().max(second.rank());
        for rank in (low + 1)..high {
            let square = match Square::from_file_rank(first.file(), rank) {
                Some(square) => square,
                None => return false,
            };
            if self.piece_at(square).is_some() {
                return false;
            }
        }
        true
    }

    pub(crate) fn apply_legal_move(&mut self, mv: Move) -> Result<AppliedMove, GameError> {
        let moved = self.piece_at(mv.from).ok_or(GameError::IllegalMove)?;
        if moved.side != self.side_to_move {
            return Err(GameError::IllegalMove);
        }
        let captured = self.piece_at(mv.to);
        if captured
            .is_some_and(|piece| piece.side == moved.side || piece.kind == PieceKind::General)
        {
            return Err(GameError::IllegalMove);
        }
        let new_halfmove_clock = if moved.kind == PieceKind::Pawn || captured.is_some() {
            0
        } else {
            self.halfmove_clock
                .checked_add(1)
                .ok_or(GameError::CounterLimit)?
        };
        let new_fullmove_number = if moved.side == Side::Black {
            self.fullmove_number
                .checked_add(1)
                .ok_or(GameError::CounterLimit)?
        } else {
            self.fullmove_number
        };
        let applied = AppliedMove {
            mv,
            moved,
            captured,
            previous_side_to_move: self.side_to_move,
            previous_halfmove_clock: self.halfmove_clock,
            previous_fullmove_number: self.fullmove_number,
            previous_position_hash: self.position_hash,
        };

        self.cells[mv.from.index()] = None;
        self.cells[mv.to.index()] = Some(moved);
        self.position_hash ^=
            piece_key(moved, mv.from) ^ piece_key(moved, mv.to) ^ side_to_move_key();
        if let Some(piece) = captured {
            self.position_hash ^= piece_key(piece, mv.to);
        }
        self.side_to_move = self.side_to_move.opponent();
        self.halfmove_clock = new_halfmove_clock;
        self.fullmove_number = new_fullmove_number;
        Ok(applied)
    }

    pub(crate) fn undo_move(&mut self, applied: AppliedMove) {
        self.cells[applied.mv.from.index()] = Some(applied.moved);
        self.cells[applied.mv.to.index()] = applied.captured;
        self.side_to_move = applied.previous_side_to_move;
        self.halfmove_clock = applied.previous_halfmove_clock;
        self.fullmove_number = applied.previous_fullmove_number;
        self.position_hash = applied.previous_position_hash;
    }

    #[must_use]
    pub(crate) fn encoded_cells(&self) -> [u8; BOARD_SQUARES] {
        let mut encoded = [0_u8; BOARD_SQUARES];
        for (index, cell) in self.cells.iter().enumerate() {
            if let Some(piece) = cell {
                encoded[index] = piece.encoded();
            }
        }
        encoded
    }

    #[must_use]
    pub(crate) fn recompute_hash(&self) -> u64 {
        recompute_position_hash(self)
    }

    #[must_use]
    pub(crate) fn piece_count(&self) -> usize {
        self.cells.iter().flatten().count()
    }
}
