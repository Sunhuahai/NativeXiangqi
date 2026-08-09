//! Transactional canonical game state, compact variation arena, and raw history evidence.

use crate::{
    GameError, Move, NodeId, Piece, PieceId, PieceKind, RuleProfile, SetupPiece, Side, Square,
    TerminalState,
    hash::next_repetition_hash,
    limits::{
        BASE_RULE_PROFILE_ID, BASE_RULE_PROFILE_VERSION, BOARD_SQUARES,
        MAX_ANNOTATION_BYTES_PER_NODE, MAX_PERFT_DEPTH, MAX_POSITION_HISTORY,
        MAX_TOTAL_ANNOTATION_BYTES, MAX_TREE_DEPTH, MAX_VARIATION_NODES, PLY_EVENT_SCHEMA_VERSION,
    },
    movegen::{is_in_check, legal_moves_for, piece_attacks_square},
    position::{AppliedMove, Position},
};

/// A versioned raw event record. It intentionally contains no WXF responsibility verdict.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct PlyEventV1 {
    pub schema_version: u16,
    pub mover: Side,
    pub mv: Move,
    pub moved_kind: PieceKind,
    pub moved_id: PieceId,
    pub captured_kind: Option<PieceKind>,
    pub captured_id: Option<PieceId>,
    pub was_in_check: bool,
    pub gives_check: bool,
    pub legal_reply_count: u16,
    pub before_position_hash: u64,
    pub after_position_hash: u64,
    /// Bit set `n` means physical piece identity `n` is attacked by the moved piece.
    pub moved_piece_targets_after: u64,
    /// An equal base position was observed at this earlier history index, if any.
    pub repetition_anchor: Option<u32>,
}

impl PlyEventV1 {
    #[must_use]
    fn fingerprint(self) -> u64 {
        let captured = self.captured_id.map_or(0_u64, |id| id.raw() as u64);
        let checks = ((self.was_in_check as u64) << 1) | self.gives_check as u64;
        self.before_position_hash
            ^ self.after_position_hash.rotate_left(11)
            ^ ((self.moved_id.raw() as u64) << 48)
            ^ (captured << 40)
            ^ ((self.legal_reply_count as u64) << 16)
            ^ checks
            ^ self.moved_piece_targets_after.rotate_right(7)
    }
}

/// A bounded summary that explicitly says base history has no WXF classification.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct HistorySummaryV1 {
    pub schema_version: u16,
    pub profile_id: u32,
    pub profile_version: u32,
    pub position_count: u32,
    pub event_count: u32,
    pub current_repetition_hash: u64,
    pub has_repetition_candidate: bool,
    pub wxf_responsibility_supported: bool,
}

/// Immutable, batch-friendly canonical state for Swift/FFI consumers.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct BoardSnapshotV1 {
    pub cells: [u8; BOARD_SQUARES],
    pub side_to_move: Side,
    pub terminal: TerminalState,
    pub checked_side: Option<Side>,
    pub halfmove_clock: u32,
    pub fullmove_number: u32,
    pub current_node: NodeId,
    pub history_length: u32,
    pub profile_id: u32,
    pub profile_version: u32,
    pub position_hash: u64,
    pub repetition_hash: u64,
}

/// Position-only equality evidence used by properties and transactional importer tests.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PositionDigestV1 {
    pub cells: [u8; BOARD_SQUARES],
    pub side_to_move: Side,
    pub terminal: TerminalState,
    pub halfmove_clock: u32,
    pub fullmove_number: u32,
    pub current_node: NodeId,
    pub history_length: u32,
    pub position_hash: u64,
    pub repetition_hash: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct UndoFrame {
    applied: AppliedMove,
    previous_repetition_hash: u64,
    previous_terminal: TerminalState,
    previous_history_length: usize,
}

#[derive(Clone, Debug)]
struct VariationNode {
    parent: Option<NodeId>,
    first_child: Option<NodeId>,
    last_child: Option<NodeId>,
    next_sibling: Option<NodeId>,
    selected_child: Option<NodeId>,
    mv: Option<Move>,
    undo: Option<UndoFrame>,
    event: Option<PlyEventV1>,
    after_position_hash: u64,
    after_repetition_hash: u64,
    after_terminal: TerminalState,
    annotation: String,
}

/// Fully validated payload for a new child node; linkage belongs to the arena.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct PendingVariationNode {
    mv: Move,
    undo: UndoFrame,
    event: PlyEventV1,
    after_position_hash: u64,
    after_repetition_hash: u64,
    after_terminal: TerminalState,
}

#[derive(Clone, Debug)]
struct VariationTree {
    nodes: Vec<VariationNode>,
}

impl VariationTree {
    fn new(initial_hash: u64, initial_repetition_hash: u64) -> Result<Self, GameError> {
        let mut nodes = Vec::new();
        nodes
            .try_reserve_exact(1)
            .map_err(|_| GameError::NodeLimit)?;
        nodes.push(VariationNode {
            parent: None,
            first_child: None,
            last_child: None,
            next_sibling: None,
            selected_child: None,
            mv: None,
            undo: None,
            event: None,
            after_position_hash: initial_hash,
            after_repetition_hash: initial_repetition_hash,
            after_terminal: TerminalState::Ongoing,
            annotation: String::new(),
        });
        Ok(Self { nodes })
    }

    fn node(&self, id: NodeId) -> Result<&VariationNode, GameError> {
        self.nodes.get(id.index()).ok_or(GameError::InvalidNode)
    }

    fn node_mut(&mut self, id: NodeId) -> Result<&mut VariationNode, GameError> {
        self.nodes.get_mut(id.index()).ok_or(GameError::InvalidNode)
    }

    fn child_with_move(&self, parent: NodeId, mv: Move) -> Result<Option<NodeId>, GameError> {
        let mut child = self.node(parent)?.first_child;
        while let Some(id) = child {
            let node = self.node(id)?;
            if node.mv == Some(mv) {
                return Ok(Some(id));
            }
            child = node.next_sibling;
        }
        Ok(None)
    }

    fn append(
        &mut self,
        parent: NodeId,
        pending: PendingVariationNode,
    ) -> Result<NodeId, GameError> {
        if self.nodes.len() >= MAX_VARIATION_NODES {
            return Err(GameError::NodeLimit);
        }
        self.node(parent)?;
        self.nodes
            .try_reserve_exact(1)
            .map_err(|_| GameError::NodeLimit)?;
        let raw_id = u32::try_from(self.nodes.len()).map_err(|_| GameError::NodeLimit)?;
        let id = NodeId(raw_id);
        let prior_last = self.node(parent)?.last_child;
        self.nodes.push(VariationNode {
            parent: Some(parent),
            first_child: None,
            last_child: None,
            next_sibling: None,
            selected_child: None,
            mv: Some(pending.mv),
            undo: Some(pending.undo),
            event: Some(pending.event),
            after_position_hash: pending.after_position_hash,
            after_repetition_hash: pending.after_repetition_hash,
            after_terminal: pending.after_terminal,
            annotation: String::new(),
        });
        if let Some(last) = prior_last {
            self.node_mut(last)?.next_sibling = Some(id);
        }
        let parent_node = self.node_mut(parent)?;
        if parent_node.first_child.is_none() {
            parent_node.first_child = Some(id);
        }
        parent_node.last_child = Some(id);
        parent_node.selected_child = Some(id);
        Ok(id)
    }

    fn children(&self, parent: NodeId) -> Result<Vec<NodeId>, GameError> {
        let mut result = Vec::new();
        result
            .try_reserve_exact(MAX_VARIATION_NODES.min(64))
            .map_err(|_| GameError::NodeLimit)?;
        let mut child = self.node(parent)?.first_child;
        while let Some(id) = child {
            result.push(id);
            child = self.node(id)?.next_sibling;
        }
        Ok(result)
    }

    fn depth(&self, node: NodeId) -> Result<usize, GameError> {
        let mut depth = 0_usize;
        let mut current = node;
        while let Some(parent) = self.node(current)?.parent {
            depth = depth.checked_add(1).ok_or(GameError::NodeLimit)?;
            if depth > MAX_TREE_DEPTH {
                return Err(GameError::NodeLimit);
            }
            current = parent;
        }
        Ok(depth)
    }

    fn path_from_root(&self, node: NodeId) -> Result<Vec<NodeId>, GameError> {
        let mut reversed = Vec::new();
        reversed
            .try_reserve_exact(MAX_TREE_DEPTH + 1)
            .map_err(|_| GameError::NodeLimit)?;
        let mut current = node;
        loop {
            reversed.push(current);
            let Some(parent) = self.node(current)?.parent else {
                break;
            };
            if reversed.len() > MAX_TREE_DEPTH + 1 {
                return Err(GameError::NodeLimit);
            }
            current = parent;
        }
        reversed.reverse();
        if reversed.first().copied() != Some(NodeId::ROOT) {
            return Err(GameError::InternalInvariant);
        }
        Ok(reversed)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct HistoryEntry {
    node: NodeId,
    position_hash: u64,
    repetition_hash: u64,
}

/// Canonical Xiangqi game state. Rust owns all legality and terminal semantics.
#[derive(Clone, Debug)]
pub struct Game {
    position: Position,
    profile: RuleProfile,
    tree: VariationTree,
    current_node: NodeId,
    history: Vec<HistoryEntry>,
    repetition_hash: u64,
    terminal: TerminalState,
    annotation_bytes: usize,
}

/// A private-state document rebuild transaction.
///
/// Normal interactive operations keep using the clone-and-commit methods on
/// [`Game`] so a failed move can never partially alter a live game. A document
/// restore instead operates only on this unpublished candidate. It may mutate
/// its candidate while replaying a flat, already bounded record; callers must
/// discard it on the first error and can publish the completed game only through
/// [`DocumentRestoreCandidate::finish`]. This avoids copying the growing arena
/// once per restored node.
#[derive(Debug)]
pub struct DocumentRestoreCandidate {
    game: Game,
    failed: bool,
}

impl DocumentRestoreCandidate {
    /// Starts an unpublished candidate from an already strict initial position.
    #[must_use]
    pub fn new(game: Game) -> Self {
        Self {
            game,
            failed: false,
        }
    }

    /// Replays one flat document node. The caller supplies the expected stable
    /// node id so malformed/out-of-order records cannot be silently remapped.
    pub fn append_node(
        &mut self,
        parent: NodeId,
        mv: Move,
        expected_node: NodeId,
    ) -> Result<NodeId, GameError> {
        self.ensure_active()?;
        let result = (|| {
            self.game.navigate_inner(parent)?;
            let actual = self.game.apply_move_inner(mv)?;
            if actual != expected_node {
                return Err(GameError::CorruptDocument);
            }
            Ok(actual)
        })();
        self.record(result)
    }

    /// Installs one bounded annotation after every move has been replayed.
    pub fn set_annotation(&mut self, node: NodeId, annotation: &str) -> Result<(), GameError> {
        self.ensure_active()?;
        let result = self.game.set_annotation(node, annotation);
        self.record(result)
    }

    /// Selects the canonical redo child for a restored parent.
    pub fn select_child(&mut self, parent: NodeId, child: NodeId) -> Result<(), GameError> {
        self.ensure_active()?;
        let result = self.game.select_child(parent, child);
        self.record(result)
    }

    /// Restores the saved cursor after all nodes exist and before the persisted
    /// selected-child choices are reapplied. Navigating updates the choices along
    /// its path, so the caller restores every stored choice afterwards to retain
    /// redo behavior on both the selected path and off-path branches.
    pub fn navigate_to(&mut self, target: NodeId) -> Result<(), GameError> {
        self.ensure_active()?;
        let result = self.game.navigate_inner(target);
        self.record(result)
    }

    /// Publishes the candidate only if every restore operation succeeded.
    pub fn finish(self) -> Result<Game, GameError> {
        if self.failed {
            return Err(GameError::InternalInvariant);
        }
        Ok(self.game)
    }

    #[must_use]
    pub const fn is_failed(&self) -> bool {
        self.failed
    }

    /// Permanently rejects publication of this candidate after its FFI envelope
    /// has observed an invalid restore operation before it could enter a core
    /// method (for example an invalid POD move or UTF-8 payload). Keeping that
    /// failure in the same transaction prevents a caller from ignoring a failed
    /// record field and publishing only a prefix of the document.
    pub fn invalidate(&mut self) {
        self.failed = true;
    }

    fn ensure_active(&self) -> Result<(), GameError> {
        if self.failed {
            Err(GameError::InternalInvariant)
        } else {
            Ok(())
        }
    }

    fn record<T>(&mut self, result: Result<T, GameError>) -> Result<T, GameError> {
        if result.is_err() {
            self.failed = true;
        }
        result
    }
}

impl Game {
    /// Creates the deterministic standard opening position with Red to move.
    pub fn standard() -> Result<Self, GameError> {
        Self::from_position(Position::standard()?)
    }

    /// Creates a strict canonical position from bounded setup data.
    pub fn from_setup(
        side_to_move: Side,
        pieces: &[SetupPiece],
        halfmove_clock: u32,
        fullmove_number: u32,
    ) -> Result<Self, GameError> {
        Self::from_position(Position::from_setup(
            side_to_move,
            pieces,
            halfmove_clock,
            fullmove_number,
        )?)
    }

    fn from_position(position: Position) -> Result<Self, GameError> {
        let initial_repetition_hash = next_repetition_hash(
            u64::from(BASE_RULE_PROFILE_ID) << 32 | u64::from(BASE_RULE_PROFILE_VERSION),
            position.position_hash(),
            0,
        );
        let tree = VariationTree::new(position.position_hash(), initial_repetition_hash)?;
        let mut history = Vec::new();
        history
            .try_reserve_exact(MAX_POSITION_HISTORY.min(16))
            .map_err(|_| GameError::HistoryLimit)?;
        history.push(HistoryEntry {
            node: NodeId::ROOT,
            position_hash: position.position_hash(),
            repetition_hash: initial_repetition_hash,
        });
        let mut game = Self {
            position,
            profile: RuleProfile::BaseV1,
            tree,
            current_node: NodeId::ROOT,
            history,
            repetition_hash: initial_repetition_hash,
            terminal: TerminalState::Ongoing,
            annotation_bytes: 0,
        };
        game.terminal = game.terminal_for_current_position()?;
        game.tree.node_mut(NodeId::ROOT)?.after_terminal = game.terminal;
        Ok(game)
    }

    #[must_use]
    pub const fn profile(&self) -> RuleProfile {
        self.profile
    }

    #[must_use]
    pub const fn current_node(&self) -> NodeId {
        self.current_node
    }

    #[must_use]
    pub const fn terminal_state(&self) -> TerminalState {
        self.terminal
    }

    #[must_use]
    pub const fn position_hash(&self) -> u64 {
        self.position.position_hash()
    }

    #[must_use]
    pub const fn repetition_hash(&self) -> u64 {
        self.repetition_hash
    }

    #[must_use]
    pub const fn side_to_move(&self) -> Side {
        self.position.side_to_move()
    }

    #[must_use]
    pub const fn halfmove_clock(&self) -> u32 {
        self.position.halfmove_clock()
    }

    #[must_use]
    pub const fn fullmove_number(&self) -> u32 {
        self.position.fullmove_number()
    }

    #[must_use]
    pub fn piece_at(&self, square: Square) -> Option<Piece> {
        self.position.piece_at(square)
    }

    #[must_use]
    pub fn is_in_check(&self, side: Side) -> bool {
        is_in_check(&self.position, side)
    }

    pub fn legal_moves(&self) -> Result<Vec<Move>, GameError> {
        legal_moves_for(&self.position, self.position.side_to_move())
    }

    pub fn legal_destinations(&self, from: Square) -> Result<Vec<Square>, GameError> {
        let mut destinations = Vec::new();
        let moves = self.legal_moves()?;
        destinations
            .try_reserve_exact(moves.len())
            .map_err(|_| GameError::MoveGenerationLimit)?;
        for mv in moves {
            if mv.from == from {
                destinations.push(mv.to);
            }
        }
        Ok(destinations)
    }

    pub fn selectable_squares(&self) -> Result<Vec<Square>, GameError> {
        let moves = self.legal_moves()?;
        let mut selected = [false; BOARD_SQUARES];
        for mv in moves {
            selected[mv.from.index()] = true;
        }
        let mut squares = Vec::new();
        squares
            .try_reserve_exact(BOARD_SQUARES)
            .map_err(|_| GameError::MoveGenerationLimit)?;
        for raw_square in 0..BOARD_SQUARES as u8 {
            if selected[raw_square as usize] {
                squares.push(Square::new(raw_square).ok_or(GameError::InternalInvariant)?);
            }
        }
        Ok(squares)
    }

    #[must_use]
    pub fn snapshot(&self) -> BoardSnapshotV1 {
        let side = self.position.side_to_move();
        BoardSnapshotV1 {
            cells: self.position.encoded_cells(),
            side_to_move: side,
            terminal: self.terminal,
            checked_side: is_in_check(&self.position, side).then_some(side),
            halfmove_clock: self.position.halfmove_clock(),
            fullmove_number: self.position.fullmove_number(),
            current_node: self.current_node,
            history_length: self.history.len() as u32,
            profile_id: BASE_RULE_PROFILE_ID,
            profile_version: BASE_RULE_PROFILE_VERSION,
            position_hash: self.position.position_hash(),
            repetition_hash: self.repetition_hash,
        }
    }

    #[must_use]
    pub fn position_digest(&self) -> PositionDigestV1 {
        PositionDigestV1 {
            cells: self.position.encoded_cells(),
            side_to_move: self.position.side_to_move(),
            terminal: self.terminal,
            halfmove_clock: self.position.halfmove_clock(),
            fullmove_number: self.position.fullmove_number(),
            current_node: self.current_node,
            history_length: self.history.len() as u32,
            position_hash: self.position.position_hash(),
            repetition_hash: self.repetition_hash,
        }
    }

    /// Canonical current-path bytes intentionally exclude retained future variations.
    #[must_use]
    pub fn canonical_position_bytes(&self) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(BOARD_SQUARES + 48);
        bytes.extend_from_slice(&self.position.encoded_cells());
        bytes.push(self.position.side_to_move() as u8);
        bytes.extend_from_slice(&self.position.halfmove_clock().to_le_bytes());
        bytes.extend_from_slice(&self.position.fullmove_number().to_le_bytes());
        bytes.extend_from_slice(&self.current_node.0.to_le_bytes());
        bytes.extend_from_slice(&(self.history.len() as u32).to_le_bytes());
        bytes.extend_from_slice(&self.position.position_hash().to_le_bytes());
        bytes.extend_from_slice(&self.repetition_hash.to_le_bytes());
        match self.terminal {
            TerminalState::Ongoing => bytes.extend_from_slice(&[0, 0]),
            TerminalState::Checkmate { winner } => bytes.extend_from_slice(&[1, winner as u8]),
            TerminalState::Stalemate { winner } => bytes.extend_from_slice(&[2, winner as u8]),
        }
        bytes
    }

    pub fn history_summary(&self) -> Result<HistorySummaryV1, GameError> {
        let current_entry = self.history.last().ok_or(GameError::InternalInvariant)?;
        if current_entry.node != self.current_node
            || current_entry.position_hash != self.position.position_hash()
            || current_entry.repetition_hash != self.repetition_hash
        {
            return Err(GameError::InternalInvariant);
        }
        let mut has_repetition_candidate = false;
        for entry in self.history.iter().skip(1) {
            let event = self
                .tree
                .node(entry.node)?
                .event
                .ok_or(GameError::InternalInvariant)?;
            has_repetition_candidate |= event.repetition_anchor.is_some();
        }
        Ok(HistorySummaryV1 {
            schema_version: PLY_EVENT_SCHEMA_VERSION,
            profile_id: BASE_RULE_PROFILE_ID,
            profile_version: BASE_RULE_PROFILE_VERSION,
            position_count: self.history.len() as u32,
            event_count: self.history.len().saturating_sub(1) as u32,
            current_repetition_hash: self.repetition_hash,
            has_repetition_candidate,
            wxf_responsibility_supported: false,
        })
    }

    pub fn children(&self, node: NodeId) -> Result<Vec<NodeId>, GameError> {
        self.tree.children(node)
    }

    pub fn event_for_node(&self, node: NodeId) -> Result<Option<PlyEventV1>, GameError> {
        Ok(self.tree.node(node)?.event)
    }

    /// Returns the currently selected child for one retained variation node.
    ///
    /// The selection is part of the canonical variation tree: `redo()` follows it,
    /// so document serialization must preserve it instead of inventing a Swift-side
    /// default after reopening a record.
    pub fn selected_child_for_node(&self, node: NodeId) -> Result<Option<NodeId>, GameError> {
        Ok(self.tree.node(node)?.selected_child)
    }

    /// Returns one bounded UTF-8 annotation owned by the canonical variation node.
    ///
    /// Callers receive a borrow only while the game is immutably borrowed. FFI code
    /// copies it into a registered owned buffer before crossing the ABI boundary.
    pub fn annotation_for_node(&self, node: NodeId) -> Result<&str, GameError> {
        Ok(&self.tree.node(node)?.annotation)
    }

    /// Chooses which retained child `redo()` follows without moving the cursor.
    ///
    /// Document restoration uses this after every branch has been replayed. Keeping
    /// it separate from navigation preserves each parent's redo choice even when
    /// the saved cursor lives on another branch.
    pub fn select_child(&mut self, parent: NodeId, child: NodeId) -> Result<(), GameError> {
        let child_parent = self.tree.node(child)?.parent;
        if child_parent != Some(parent) {
            return Err(GameError::InvalidNode);
        }
        // Both node lookups and the relationship check happen before mutation.
        // Unlike move application, this tiny scalar change cannot fail after the
        // assignment, so cloning the full 4,096-node arena is unnecessary.
        self.tree.node_mut(parent)?.selected_child = Some(child);
        Ok(())
    }

    pub fn set_annotation(&mut self, node: NodeId, annotation: &str) -> Result<(), GameError> {
        if annotation.len() > MAX_ANNOTATION_BYTES_PER_NODE {
            return Err(GameError::AnnotationTooLong);
        }
        let old_length = self.tree.node(node)?.annotation.len();
        let proposed = self
            .annotation_bytes
            .checked_sub(old_length)
            .and_then(|value| value.checked_add(annotation.len()))
            .ok_or(GameError::AnnotationQuota)?;
        if proposed > MAX_TOTAL_ANNOTATION_BYTES {
            return Err(GameError::AnnotationQuota);
        }
        // Allocate before the single in-place assignment. All recoverable
        // validation has completed at this point, so a failed request leaves the
        // existing annotation and quota unchanged without cloning the full game.
        let mut replacement = String::new();
        replacement
            .try_reserve_exact(annotation.len())
            .map_err(|_| GameError::AnnotationQuota)?;
        replacement.push_str(annotation);
        self.tree.node_mut(node)?.annotation = replacement;
        self.annotation_bytes = proposed;
        Ok(())
    }

    pub fn apply_move(&mut self, mv: Move) -> Result<NodeId, GameError> {
        let mut candidate = self.clone();
        let node = candidate.apply_move_inner(mv)?;
        *self = candidate;
        Ok(node)
    }

    fn apply_move_inner(&mut self, mv: Move) -> Result<NodeId, GameError> {
        if self.terminal.is_terminal() {
            return Err(GameError::GameOver);
        }
        let mover = self.position.side_to_move();
        let legal = legal_moves_for(&self.position, mover)?;
        if !legal.contains(&mv) {
            return Err(GameError::IllegalMove);
        }
        if let Some(existing) = self.tree.child_with_move(self.current_node, mv)? {
            return self.redo_child_inner(existing);
        }
        if self.history.len() >= MAX_POSITION_HISTORY
            || self.tree.depth(self.current_node)? >= MAX_TREE_DEPTH
        {
            return Err(GameError::HistoryLimit);
        }
        if self.tree.nodes.len() >= MAX_VARIATION_NODES {
            return Err(GameError::NodeLimit);
        }
        self.tree
            .nodes
            .try_reserve_exact(1)
            .map_err(|_| GameError::NodeLimit)?;
        self.history
            .try_reserve_exact(1)
            .map_err(|_| GameError::HistoryLimit)?;

        let was_in_check = is_in_check(&self.position, mover);
        let previous_repetition_hash = self.repetition_hash;
        let previous_terminal = self.terminal;
        let previous_history_length = self.history.len();
        let applied = self.position.apply_legal_move(mv)?;
        let (event, next_repetition, next_terminal) =
            self.event_after_apply(applied, was_in_check)?;
        let undo = UndoFrame {
            applied,
            previous_repetition_hash,
            previous_terminal,
            previous_history_length,
        };
        let parent = self.current_node;
        let node = self.tree.append(
            parent,
            PendingVariationNode {
                mv,
                undo,
                event,
                after_position_hash: self.position.position_hash(),
                after_repetition_hash: next_repetition,
                after_terminal: next_terminal,
            },
        )?;
        self.history.push(HistoryEntry {
            node,
            position_hash: self.position.position_hash(),
            repetition_hash: next_repetition,
        });
        self.current_node = node;
        self.repetition_hash = next_repetition;
        self.terminal = next_terminal;
        Ok(node)
    }

    fn event_after_apply(
        &self,
        applied: AppliedMove,
        was_in_check: bool,
    ) -> Result<(PlyEventV1, u64, TerminalState), GameError> {
        let next_side = self.position.side_to_move();
        let legal_replies = legal_moves_for(&self.position, next_side)?;
        let next_terminal = if legal_replies.is_empty() {
            if is_in_check(&self.position, next_side) {
                TerminalState::Checkmate {
                    winner: next_side.opponent(),
                }
            } else {
                TerminalState::Stalemate {
                    winner: next_side.opponent(),
                }
            }
        } else {
            TerminalState::Ongoing
        };
        let moved_after = self
            .position
            .piece_at(applied.mv.to)
            .ok_or(GameError::InternalInvariant)?;
        let mut targets = 0_u64;
        for raw_square in 0..BOARD_SQUARES as u8 {
            let square = Square::new(raw_square).ok_or(GameError::InternalInvariant)?;
            if let Some(piece) = self.position.piece_at(square)
                && piece.side == moved_after.side.opponent()
                && piece_attacks_square(&self.position, applied.mv.to, moved_after, square)
            {
                targets |= piece.id.bit();
            }
        }
        let repetition_anchor = self
            .history
            .iter()
            .enumerate()
            .rev()
            .find_map(|(index, entry)| {
                (entry.position_hash == self.position.position_hash()).then_some(index as u32)
            });
        let event = PlyEventV1 {
            schema_version: PLY_EVENT_SCHEMA_VERSION,
            mover: applied.moved.side,
            mv: applied.mv,
            moved_kind: applied.moved.kind,
            moved_id: applied.moved.id,
            captured_kind: applied.captured.map(|piece| piece.kind),
            captured_id: applied.captured.map(|piece| piece.id),
            was_in_check,
            gives_check: is_in_check(&self.position, next_side),
            legal_reply_count: u16::try_from(legal_replies.len())
                .map_err(|_| GameError::MoveGenerationLimit)?,
            before_position_hash: applied.previous_position_hash,
            after_position_hash: self.position.position_hash(),
            moved_piece_targets_after: targets,
            repetition_anchor,
        };
        let next_repetition = next_repetition_hash(
            self.repetition_hash,
            self.position.position_hash(),
            event.fingerprint(),
        );
        Ok((event, next_repetition, next_terminal))
    }

    pub fn undo(&mut self) -> Result<NodeId, GameError> {
        let mut candidate = self.clone();
        let node = candidate.undo_inner()?;
        *self = candidate;
        Ok(node)
    }

    fn undo_inner(&mut self) -> Result<NodeId, GameError> {
        if self.current_node == NodeId::ROOT {
            return Err(GameError::NoUndo);
        }
        let node = self.tree.node(self.current_node)?.clone();
        let parent = node.parent.ok_or(GameError::InternalInvariant)?;
        let undo = node.undo.ok_or(GameError::InternalInvariant)?;
        self.position.undo_move(undo.applied);
        self.history.truncate(undo.previous_history_length);
        self.current_node = parent;
        self.repetition_hash = undo.previous_repetition_hash;
        self.terminal = undo.previous_terminal;
        Ok(parent)
    }

    pub fn redo(&mut self) -> Result<NodeId, GameError> {
        let child = self
            .tree
            .node(self.current_node)?
            .selected_child
            .ok_or(GameError::NoRedo)?;
        self.redo_child(child)
    }

    pub fn redo_child(&mut self, child: NodeId) -> Result<NodeId, GameError> {
        let mut candidate = self.clone();
        let node = candidate.redo_child_inner(child)?;
        *self = candidate;
        Ok(node)
    }

    fn redo_child_inner(&mut self, child: NodeId) -> Result<NodeId, GameError> {
        if self.terminal.is_terminal() {
            return Err(GameError::GameOver);
        }
        let saved = self.tree.node(child)?.clone();
        if saved.parent != Some(self.current_node) {
            return Err(GameError::InvalidNode);
        }
        let mv = saved.mv.ok_or(GameError::InternalInvariant)?;
        let mover = self.position.side_to_move();
        let legal = legal_moves_for(&self.position, mover)?;
        if !legal.contains(&mv) {
            return Err(GameError::InternalInvariant);
        }
        if self.history.len() >= MAX_POSITION_HISTORY {
            return Err(GameError::HistoryLimit);
        }
        self.history
            .try_reserve_exact(1)
            .map_err(|_| GameError::HistoryLimit)?;
        let was_in_check = is_in_check(&self.position, mover);
        let applied = self.position.apply_legal_move(mv)?;
        let (event, next_repetition, next_terminal) =
            self.event_after_apply(applied, was_in_check)?;
        if Some(event) != saved.event
            || self.position.position_hash() != saved.after_position_hash
            || next_repetition != saved.after_repetition_hash
            || next_terminal != saved.after_terminal
        {
            return Err(GameError::InternalInvariant);
        }
        self.history.push(HistoryEntry {
            node: child,
            position_hash: self.position.position_hash(),
            repetition_hash: next_repetition,
        });
        self.tree.node_mut(self.current_node)?.selected_child = Some(child);
        self.current_node = child;
        self.repetition_hash = next_repetition;
        self.terminal = next_terminal;
        Ok(child)
    }

    pub fn navigate(&mut self, target: NodeId) -> Result<NodeId, GameError> {
        let mut candidate = self.clone();
        candidate.navigate_inner(target)?;
        *self = candidate;
        Ok(target)
    }

    fn navigate_inner(&mut self, target: NodeId) -> Result<(), GameError> {
        self.tree.node(target)?;
        let current_path = self.tree.path_from_root(self.current_node)?;
        let target_path = self.tree.path_from_root(target)?;
        let mut shared = 0_usize;
        while shared < current_path.len()
            && shared < target_path.len()
            && current_path[shared] == target_path[shared]
        {
            shared += 1;
        }
        let lca = current_path
            .get(shared.saturating_sub(1))
            .copied()
            .ok_or(GameError::InternalInvariant)?;
        while self.current_node != lca {
            self.undo_inner()?;
        }
        for child in target_path.into_iter().skip(shared) {
            self.redo_child_inner(child)?;
        }
        Ok(())
    }

    pub fn mainline_moves(&self) -> Result<Vec<Move>, GameError> {
        let path = self.tree.path_from_root(self.current_node)?;
        let mut moves = Vec::new();
        moves
            .try_reserve_exact(path.len().saturating_sub(1))
            .map_err(|_| GameError::HistoryLimit)?;
        for node in path.into_iter().skip(1) {
            let mv = self
                .tree
                .node(node)?
                .mv
                .ok_or(GameError::InternalInvariant)?;
            moves.push(mv);
        }
        Ok(moves)
    }

    pub fn perft(&self, depth: u8) -> Result<u64, GameError> {
        if depth > MAX_PERFT_DEPTH {
            return Err(GameError::PerftDepthLimit);
        }
        perft_position(&self.position, depth)
    }

    #[must_use]
    pub fn recompute_position_hash(&self) -> u64 {
        self.position.recompute_hash()
    }

    #[must_use]
    pub fn piece_count(&self) -> usize {
        self.position.piece_count()
    }

    fn terminal_for_current_position(&self) -> Result<TerminalState, GameError> {
        let side = self.position.side_to_move();
        let legal = legal_moves_for(&self.position, side)?;
        if !legal.is_empty() {
            return Ok(TerminalState::Ongoing);
        }
        if is_in_check(&self.position, side) {
            Ok(TerminalState::Checkmate {
                winner: side.opponent(),
            })
        } else {
            Ok(TerminalState::Stalemate {
                winner: side.opponent(),
            })
        }
    }
}

fn perft_position(position: &Position, depth: u8) -> Result<u64, GameError> {
    if depth == 0 {
        return Ok(1);
    }
    let legal = legal_moves_for(position, position.side_to_move())?;
    if depth == 1 {
        return u64::try_from(legal.len()).map_err(|_| GameError::MoveGenerationLimit);
    }
    let mut total = 0_u64;
    for mv in legal {
        let mut child = position.clone();
        child.apply_legal_move(mv)?;
        total = total
            .checked_add(perft_position(&child, depth - 1)?)
            .ok_or(GameError::CounterLimit)?;
    }
    Ok(total)
}
