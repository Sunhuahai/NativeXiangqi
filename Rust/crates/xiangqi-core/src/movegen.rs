//! Pseudo-legal movement, attack detection, and self-check filtering.

use crate::{
    GameError, Move, Piece, PieceKind, Side, Square, limits::MAX_GENERATED_MOVES,
    position::Position,
};

const ORTHOGONAL: [(i8, i8); 4] = [(1, 0), (-1, 0), (0, 1), (0, -1)];
const DIAGONAL: [(i8, i8); 4] = [(1, 1), (1, -1), (-1, 1), (-1, -1)];
const HORSE_DELTAS: [(i8, i8); 8] = [
    (1, 2),
    (-1, 2),
    (1, -2),
    (-1, -2),
    (2, 1),
    (2, -1),
    (-2, 1),
    (-2, -1),
];

fn push_move(moves: &mut Vec<Move>, from: Square, to: Square) -> Result<(), GameError> {
    if moves.len() >= MAX_GENERATED_MOVES {
        return Err(GameError::MoveGenerationLimit);
    }
    let mv = Move::new(from, to).ok_or(GameError::InternalInvariant)?;
    moves.push(mv);
    Ok(())
}

fn can_land(position: &Position, side: Side, target: Square) -> bool {
    match position.piece_at(target) {
        None => true,
        Some(piece) => piece.side != side && piece.kind != PieceKind::General,
    }
}

fn push_if_landable(
    moves: &mut Vec<Move>,
    position: &Position,
    side: Side,
    from: Square,
    to: Option<Square>,
) -> Result<(), GameError> {
    if let Some(to) = to
        && can_land(position, side, to)
    {
        push_move(moves, from, to)?;
    }
    Ok(())
}

fn add_ray_moves(
    moves: &mut Vec<Move>,
    position: &Position,
    side: Side,
    from: Square,
    file_delta: i8,
    rank_delta: i8,
) -> Result<(), GameError> {
    let mut current = from.offset(file_delta, rank_delta);
    while let Some(square) = current {
        match position.piece_at(square) {
            None => push_move(moves, from, square)?,
            Some(piece) => {
                if piece.side != side && piece.kind != PieceKind::General {
                    push_move(moves, from, square)?;
                }
                break;
            }
        }
        current = square.offset(file_delta, rank_delta);
    }
    Ok(())
}

fn add_cannon_moves(
    moves: &mut Vec<Move>,
    position: &Position,
    side: Side,
    from: Square,
    file_delta: i8,
    rank_delta: i8,
) -> Result<(), GameError> {
    let mut current = from.offset(file_delta, rank_delta);
    let mut crossed_screen = false;
    while let Some(square) = current {
        match position.piece_at(square) {
            None if !crossed_screen => push_move(moves, from, square)?,
            None => {}
            Some(_) if !crossed_screen => crossed_screen = true,
            Some(piece) => {
                if piece.side != side && piece.kind != PieceKind::General {
                    push_move(moves, from, square)?;
                }
                break;
            }
        }
        current = square.offset(file_delta, rank_delta);
    }
    Ok(())
}

fn add_piece_pseudo_moves(
    moves: &mut Vec<Move>,
    position: &Position,
    from: Square,
    piece: Piece,
) -> Result<(), GameError> {
    match piece.kind {
        PieceKind::General => {
            for (file_delta, rank_delta) in ORTHOGONAL {
                let target = from.offset(file_delta, rank_delta);
                if let Some(target) = target
                    && piece.side.palace_contains(target.file(), target.rank())
                {
                    push_if_landable(moves, position, piece.side, from, Some(target))?;
                }
            }
        }
        PieceKind::Advisor => {
            for (file_delta, rank_delta) in DIAGONAL {
                let target = from.offset(file_delta, rank_delta);
                if let Some(target) = target
                    && piece.side.palace_contains(target.file(), target.rank())
                {
                    push_if_landable(moves, position, piece.side, from, Some(target))?;
                }
            }
        }
        PieceKind::Elephant => {
            for (file_delta, rank_delta) in DIAGONAL {
                let target = from.offset(file_delta * 2, rank_delta * 2);
                let eye = from.offset(file_delta, rank_delta);
                if let (Some(target), Some(eye)) = (target, eye)
                    && piece.side.is_home_side_rank(target.rank())
                    && position.piece_at(eye).is_none()
                {
                    push_if_landable(moves, position, piece.side, from, Some(target))?;
                }
            }
        }
        PieceKind::Horse => {
            for (file_delta, rank_delta) in HORSE_DELTAS {
                let leg = if file_delta.unsigned_abs() == 2 {
                    from.offset(file_delta / 2, 0)
                } else {
                    from.offset(0, rank_delta / 2)
                };
                let target = from.offset(file_delta, rank_delta);
                if let (Some(leg), Some(target)) = (leg, target)
                    && position.piece_at(leg).is_none()
                {
                    push_if_landable(moves, position, piece.side, from, Some(target))?;
                }
            }
        }
        PieceKind::Rook => {
            for (file_delta, rank_delta) in ORTHOGONAL {
                add_ray_moves(moves, position, piece.side, from, file_delta, rank_delta)?;
            }
        }
        PieceKind::Cannon => {
            for (file_delta, rank_delta) in ORTHOGONAL {
                add_cannon_moves(moves, position, piece.side, from, file_delta, rank_delta)?;
            }
        }
        PieceKind::Pawn => {
            push_if_landable(
                moves,
                position,
                piece.side,
                from,
                from.offset(0, piece.side.forward_rank_delta()),
            )?;
            if piece.side.has_crossed_river(from.rank()) {
                push_if_landable(moves, position, piece.side, from, from.offset(1, 0))?;
                push_if_landable(moves, position, piece.side, from, from.offset(-1, 0))?;
            }
        }
    }
    Ok(())
}

/// Generates movement without deciding whether it leaves the mover's general in check.
pub(crate) fn pseudo_moves_for(position: &Position, side: Side) -> Result<Vec<Move>, GameError> {
    let mut moves = Vec::new();
    moves
        .try_reserve_exact(MAX_GENERATED_MOVES)
        .map_err(|_| GameError::MoveGenerationLimit)?;
    for raw_square in 0..crate::limits::BOARD_SQUARES as u8 {
        let square = Square::new(raw_square).ok_or(GameError::InternalInvariant)?;
        if let Some(piece) = position.piece_at(square)
            && piece.side == side
        {
            add_piece_pseudo_moves(&mut moves, position, square, piece)?;
        }
    }
    Ok(moves)
}

fn blockers_between(position: &Position, first: Square, second: Square) -> Option<usize> {
    if first.file() != second.file() && first.rank() != second.rank() {
        return None;
    }
    let file_delta = (second.file() as i8 - first.file() as i8).signum();
    let rank_delta = (second.rank() as i8 - first.rank() as i8).signum();
    let mut current = first.offset(file_delta, rank_delta)?;
    let mut blockers = 0_usize;
    while current != second {
        if position.piece_at(current).is_some() {
            blockers = blockers.checked_add(1)?;
        }
        current = current.offset(file_delta, rank_delta)?;
    }
    Some(blockers)
}

/// Returns whether a single piece attacks a square. It intentionally ignores self-check.
pub(crate) fn piece_attacks_square(
    position: &Position,
    from: Square,
    piece: Piece,
    target: Square,
) -> bool {
    let file_delta = target.file() as i8 - from.file() as i8;
    let rank_delta = target.rank() as i8 - from.rank() as i8;
    match piece.kind {
        PieceKind::General => {
            let regular = file_delta.unsigned_abs() + rank_delta.unsigned_abs() == 1
                && piece.side.palace_contains(target.file(), target.rank());
            let flying = file_delta == 0
                && position
                    .piece_at(target)
                    .is_some_and(|target_piece| target_piece.kind == PieceKind::General)
                && position.clear_file_between(from, target);
            regular || flying
        }
        PieceKind::Advisor => {
            file_delta.unsigned_abs() == 1
                && rank_delta.unsigned_abs() == 1
                && piece.side.palace_contains(target.file(), target.rank())
        }
        PieceKind::Elephant => {
            if file_delta.unsigned_abs() != 2
                || rank_delta.unsigned_abs() != 2
                || !piece.side.is_home_side_rank(target.rank())
            {
                return false;
            }
            let Some(eye) = from.offset(file_delta / 2, rank_delta / 2) else {
                return false;
            };
            position.piece_at(eye).is_none()
        }
        PieceKind::Horse => {
            let valid = (file_delta.unsigned_abs() == 1 && rank_delta.unsigned_abs() == 2)
                || (file_delta.unsigned_abs() == 2 && rank_delta.unsigned_abs() == 1);
            if !valid {
                return false;
            }
            let leg = if file_delta.unsigned_abs() == 2 {
                from.offset(file_delta / 2, 0)
            } else {
                from.offset(0, rank_delta / 2)
            };
            leg.is_some_and(|square| position.piece_at(square).is_none())
        }
        PieceKind::Rook => blockers_between(position, from, target) == Some(0),
        PieceKind::Cannon => blockers_between(position, from, target) == Some(1),
        PieceKind::Pawn => {
            (file_delta == 0 && rank_delta == piece.side.forward_rank_delta())
                || (piece.side.has_crossed_river(from.rank())
                    && rank_delta == 0
                    && file_delta.unsigned_abs() == 1)
        }
    }
}

#[must_use]
pub(crate) fn is_in_check(position: &Position, side: Side) -> bool {
    let Some(general) = position.general_square(side) else {
        return true;
    };
    for raw_square in 0..crate::limits::BOARD_SQUARES as u8 {
        let Some(square) = Square::new(raw_square) else {
            return true;
        };
        if let Some(piece) = position.piece_at(square)
            && piece.side == side.opponent()
            && piece_attacks_square(position, square, piece, general)
        {
            return true;
        }
    }
    false
}

/// Generates all moves that leave the specified side's general safe.
pub(crate) fn legal_moves_for(position: &Position, side: Side) -> Result<Vec<Move>, GameError> {
    if position.side_to_move() != side {
        return Err(GameError::InternalInvariant);
    }
    let pseudo = pseudo_moves_for(position, side)?;
    let mut legal = Vec::new();
    legal
        .try_reserve_exact(pseudo.len())
        .map_err(|_| GameError::MoveGenerationLimit)?;
    for mv in pseudo {
        let mut candidate = position.clone();
        candidate.apply_legal_move(mv)?;
        if !is_in_check(&candidate, side) {
            if legal.len() >= MAX_GENERATED_MOVES {
                return Err(GameError::MoveGenerationLimit);
            }
            legal.push(mv);
        }
    }
    Ok(legal)
}
