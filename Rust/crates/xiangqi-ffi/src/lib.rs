//! Narrow, versioned C ABI for the canonical Rust Xiangqi core.
//!
//! This crate is the only T020 crate with `unsafe`: it validates C boundary data,
//! owns non-reusable game tokens, and exposes fixed-size batch snapshots. Rust rules
//! remain the sole authority; no engine or Swift state participates in legality.

#![deny(unsafe_op_in_unsafe_fn)]

use std::{
    collections::BTreeMap,
    mem,
    panic::{self, AssertUnwindSafe},
    ptr, slice, str,
    sync::{
        LazyLock, Mutex, MutexGuard,
        atomic::{AtomicU64, Ordering},
    },
};

use xiangqi_core::{BoardSnapshotV1, Game, GameError, Move, NodeId, Side, Square, TerminalState};
use xiangqi_io::{
    FenError, UcciError, apply_ucci_mainline, parse_fen, write_fen, write_ucci_mainline,
};

mod generated_abi;

use generated_abi::{
    ABI_MAJOR, ABI_MINOR, ABI_SOURCE_SHA256, BUILD_INFO, BUILD_INFO_FORMAT, CAPABILITY_ABI_INFO,
    CAPABILITY_BASE_HISTORY, CAPABILITY_BATCH_RULES, CAPABILITY_BUILD_INFO, CAPABILITY_FEN_UCCI,
    CAPABILITY_GAME_HANDLES, CAPABILITY_OWNED_BUFFERS, DETERMINISTIC_FEATURES,
    MAX_BUILD_INFO_BYTES, MAX_INPUT_BYTES, MAX_LIVE_BUFFERS, MAX_LIVE_GAMES,
    MAX_OWNED_BUFFER_BYTES, MAX_OWNED_BUFFER_TOTAL_BYTES, OWNERSHIP_TOKEN_BITS,
    STATUS_ABI_MAJOR_MISMATCH, STATUS_ABI_MINOR_MISMATCH, STATUS_ALLOCATION_FAILED,
    STATUS_COUNTER_LIMIT, STATUS_GAME_OVER, STATUS_HISTORY_LIMIT, STATUS_ILLEGAL_MOVE,
    STATUS_INPUT_TOO_LARGE, STATUS_INTERNAL_ERROR, STATUS_INVALID_ARGUMENT, STATUS_INVALID_HANDLE,
    STATUS_INVALID_NODE, STATUS_INVALID_OWNED_BUFFER, STATUS_INVALID_RESERVED,
    STATUS_INVALID_SQUARE, STATUS_NO_REDO, STATUS_NO_UNDO, STATUS_NODE_LIMIT, STATUS_OK,
    STATUS_OUTPUT_NOT_EMPTY, STATUS_PARSE_ERROR, STATUS_RESOURCE_LIMIT,
};

/// C-compatible typed status code. Values are generated from `ffi-api.toml`.
pub type XqStatus = u32;
/// Opaque non-reusable registry token. `0` is always invalid.
pub type XqGameHandle = u64;

/// Caller-provided ABI information output.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct XqAbiInfo {
    pub abi_major: u32,
    pub abi_minor: u32,
    pub capabilities: u64,
    pub build_info_format: u32,
    pub reserved: u32,
}

/// One Rust-owned allocation returned to C and released exactly once.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct XqOwnedBuffer {
    pub data: *mut u8,
    pub len: usize,
    pub capacity: usize,
    pub allocation_token: u64,
}

impl XqOwnedBuffer {
    pub const EMPTY: Self = Self {
        data: ptr::null_mut(),
        len: 0,
        capacity: 0,
        allocation_token: 0,
    };

    fn is_empty(self) -> bool {
        self == Self::EMPTY
    }
}

/// Fixed-width move input. Reserved bits must be zero.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct XqMoveV1 {
    pub from: u8,
    pub to: u8,
    pub reserved: u16,
}

/// Batch response used for selectable squares and legal destinations.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct XqSquareListV1 {
    pub count: u32,
    pub reserved: u32,
    pub squares: [u8; 90],
    pub reserved_tail: [u8; 2],
}

/// Immutable board batch. Encoded cells are stable Red 1..7, Black 8..14, empty 0.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct XqBoardSnapshotV1 {
    pub cells: [u8; 90],
    pub side_to_move: u8,
    pub terminal_kind: u8,
    pub terminal_winner: u8,
    pub checked_side: u8,
    pub reserved0: [u8; 3],
    pub halfmove_clock: u32,
    pub fullmove_number: u32,
    pub current_node_id: u32,
    pub history_length: u32,
    pub profile_id: u32,
    pub profile_version: u32,
    pub position_hash: u64,
    pub repetition_hash: u64,
}

/// Base history evidence. `wxf_responsibility_supported` remains zero in T020.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct XqHistorySummaryV1 {
    pub schema_version: u16,
    pub has_repetition_candidate: u8,
    pub wxf_responsibility_supported: u8,
    pub profile_id: u32,
    pub profile_version: u32,
    pub position_count: u32,
    pub event_count: u32,
    pub current_repetition_hash: u64,
}

/// Transactional UCCI mainline result. Failed imports always report zero accepted plies.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct XqMainlineResultV1 {
    pub accepted_plies: u32,
    pub failed_ply: u32,
    pub status: u32,
    pub reserved: u32,
}

#[derive(Clone, Copy)]
struct AllocationRecord {
    len: usize,
    capacity: usize,
    allocation_token: u64,
}

#[derive(Default)]
struct AllocationRegistry {
    allocations: BTreeMap<usize, AllocationRecord>,
    live_capacity: usize,
}

#[derive(Default)]
struct GameRegistry {
    games: BTreeMap<XqGameHandle, Game>,
}

static OWNED_BUFFERS: LazyLock<Mutex<AllocationRegistry>> =
    LazyLock::new(|| Mutex::new(AllocationRegistry::default()));
static GAMES: LazyLock<Mutex<GameRegistry>> = LazyLock::new(|| Mutex::new(GameRegistry::default()));
static NEXT_ALLOCATION_TOKEN: AtomicU64 = AtomicU64::new(1);
static NEXT_GAME_HANDLE: AtomicU64 = AtomicU64::new(1);

const CAPABILITIES: u64 = CAPABILITY_ABI_INFO
    | CAPABILITY_BUILD_INFO
    | CAPABILITY_OWNED_BUFFERS
    | CAPABILITY_GAME_HANDLES
    | CAPABILITY_BATCH_RULES
    | CAPABILITY_FEN_UCCI
    | CAPABILITY_BASE_HISTORY;
const SIDE_NONE: u8 = 2;
const TERMINAL_ONGOING: u8 = 0;
const TERMINAL_CHECKMATE: u8 = 1;
const TERMINAL_STALEMATE: u8 = 2;

fn buffer_registry() -> MutexGuard<'static, AllocationRegistry> {
    match OWNED_BUFFERS.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn game_registry() -> MutexGuard<'static, GameRegistry> {
    match GAMES.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn next_nonreusable(counter: &AtomicU64) -> Option<u64> {
    counter
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
            current.checked_add(1)
        })
        .ok()
}

fn boundary(call: impl FnOnce() -> XqStatus) -> XqStatus {
    match panic::catch_unwind(AssertUnwindSafe(call)) {
        Ok(status) => status,
        Err(_) => STATUS_INTERNAL_ERROR,
    }
}

fn validate_writable<T>(pointer: *mut T) -> Result<(), XqStatus> {
    if pointer.is_null() || pointer.addr() & (mem::align_of::<T>().saturating_sub(1)) != 0 {
        return Err(STATUS_INVALID_ARGUMENT);
    }
    Ok(())
}

fn abi_info() -> XqAbiInfo {
    XqAbiInfo {
        abi_major: ABI_MAJOR,
        abi_minor: ABI_MINOR,
        capabilities: CAPABILITIES,
        build_info_format: BUILD_INFO_FORMAT,
        reserved: 0,
    }
}

fn status_from_game_error(error: &GameError) -> XqStatus {
    match error {
        GameError::InvalidSetup(_) => STATUS_PARSE_ERROR,
        GameError::IllegalMove => STATUS_ILLEGAL_MOVE,
        GameError::GameOver => STATUS_GAME_OVER,
        GameError::NoUndo => STATUS_NO_UNDO,
        GameError::NoRedo => STATUS_NO_REDO,
        GameError::InvalidNode => STATUS_INVALID_NODE,
        GameError::NodeLimit => STATUS_NODE_LIMIT,
        GameError::HistoryLimit => STATUS_HISTORY_LIMIT,
        GameError::AnnotationTooLong
        | GameError::AnnotationQuota
        | GameError::MoveGenerationLimit
        | GameError::PerftDepthLimit => STATUS_RESOURCE_LIMIT,
        GameError::CounterLimit => STATUS_COUNTER_LIMIT,
        GameError::InternalInvariant => STATUS_INTERNAL_ERROR,
    }
}

fn status_from_fen_error(error: &FenError) -> XqStatus {
    match error {
        FenError::TooLong => STATUS_INPUT_TOO_LARGE,
        FenError::Core(error) => status_from_game_error(error),
        FenError::NonAscii
        | FenError::FieldCount
        | FenError::Placement
        | FenError::SideToMove
        | FenError::Placeholder
        | FenError::Halfmove
        | FenError::Fullmove => STATUS_PARSE_ERROR,
    }
}

fn status_from_ucci_error(error: &UcciError) -> XqStatus {
    match error {
        UcciError::TooLong => STATUS_INPUT_TOO_LARGE,
        UcciError::TooManyPlies => STATUS_RESOURCE_LIMIT,
        UcciError::NonAscii | UcciError::EmptyMainline | UcciError::InvalidCoordinate { .. } => {
            STATUS_PARSE_ERROR
        }
        UcciError::IllegalMove { source, .. } => status_from_game_error(source),
    }
}

fn allocate_owned_buffer(out_buffer: *mut XqOwnedBuffer, bytes: &[u8]) -> XqStatus {
    if let Err(status) = validate_writable(out_buffer) {
        return status;
    }
    // SAFETY: a non-null, aligned writable out buffer is part of the C ABI contract.
    let current = unsafe { out_buffer.read() };
    if !current.is_empty() {
        return STATUS_OUTPUT_NOT_EMPTY;
    }
    if bytes.len() > MAX_OWNED_BUFFER_BYTES {
        return STATUS_RESOURCE_LIMIT;
    }
    if OWNERSHIP_TOKEN_BITS != u64::BITS {
        return STATUS_INTERNAL_ERROR;
    }
    let requested_capacity = bytes.len().max(1);
    let mut owned = Vec::new();
    if owned.try_reserve_exact(requested_capacity).is_err() {
        return STATUS_ALLOCATION_FAILED;
    }
    owned.extend_from_slice(bytes);
    let capacity = owned.capacity();
    if capacity > MAX_OWNED_BUFFER_BYTES {
        return STATUS_RESOURCE_LIMIT;
    }

    let mut registry = buffer_registry();
    if registry.allocations.len() >= MAX_LIVE_BUFFERS
        || registry
            .live_capacity
            .checked_add(capacity)
            .is_none_or(|total| total > MAX_OWNED_BUFFER_TOTAL_BYTES)
    {
        return STATUS_RESOURCE_LIMIT;
    }
    let Some(allocation_token) = next_nonreusable(&NEXT_ALLOCATION_TOKEN) else {
        return STATUS_RESOURCE_LIMIT;
    };
    let record = AllocationRecord {
        len: owned.len(),
        capacity,
        allocation_token,
    };
    let data = owned.as_mut_ptr();
    if registry.allocations.contains_key(&data.addr()) {
        return STATUS_INTERNAL_ERROR;
    }
    registry.allocations.insert(data.addr(), record);
    registry.live_capacity = match registry.live_capacity.checked_add(record.capacity) {
        Some(value) => value,
        None => return STATUS_INTERNAL_ERROR,
    };
    mem::forget(owned);

    // SAFETY: the caller supplied writable initialized POD storage and ownership is now recorded.
    unsafe {
        out_buffer.write(XqOwnedBuffer {
            data,
            len: record.len,
            capacity: record.capacity,
            allocation_token: record.allocation_token,
        });
    }
    STATUS_OK
}

fn buffer_release(buffer: *mut XqOwnedBuffer) -> XqStatus {
    if let Err(status) = validate_writable(buffer) {
        return status;
    }
    // SAFETY: a non-null, aligned writable buffer is part of the C ABI contract.
    let supplied = unsafe { buffer.read() };
    if supplied.data.is_null() || supplied.len > supplied.capacity || supplied.allocation_token == 0
    {
        return STATUS_INVALID_OWNED_BUFFER;
    }
    let mut registry = buffer_registry();
    let Some(record) = registry.allocations.get(&supplied.data.addr()).copied() else {
        return STATUS_INVALID_OWNED_BUFFER;
    };
    if supplied.len != record.len
        || supplied.capacity != record.capacity
        || supplied.allocation_token != record.allocation_token
    {
        return STATUS_INVALID_OWNED_BUFFER;
    }
    let Some(next_capacity) = registry.live_capacity.checked_sub(record.capacity) else {
        return STATUS_INTERNAL_ERROR;
    };
    registry.allocations.remove(&supplied.data.addr());
    registry.live_capacity = next_capacity;
    drop(registry);

    // SAFETY: only this registry inserts these Vec allocations, with this exact metadata.
    unsafe {
        drop(Vec::from_raw_parts(
            supplied.data,
            record.len,
            record.capacity,
        ));
    }
    // SAFETY: the caller supplied writable POD storage.
    unsafe { buffer.write(XqOwnedBuffer::EMPTY) };
    STATUS_OK
}

fn check_empty_handle(out_handle: *mut XqGameHandle) -> Result<(), XqStatus> {
    validate_writable(out_handle)?;
    // SAFETY: a non-null, aligned writable handle pointer is part of the C ABI contract.
    let current = unsafe { out_handle.read() };
    if current != 0 {
        return Err(STATUS_OUTPUT_NOT_EMPTY);
    }
    Ok(())
}

fn insert_game(out_handle: *mut XqGameHandle, game: Game) -> XqStatus {
    if let Err(status) = check_empty_handle(out_handle) {
        return status;
    }
    let mut registry = game_registry();
    if registry.games.len() >= MAX_LIVE_GAMES {
        return STATUS_RESOURCE_LIMIT;
    }
    let Some(handle) = next_nonreusable(&NEXT_GAME_HANDLE) else {
        return STATUS_RESOURCE_LIMIT;
    };
    if registry.games.insert(handle, game).is_some() {
        return STATUS_INTERNAL_ERROR;
    }
    // SAFETY: check_empty_handle established a writable output location.
    unsafe { out_handle.write(handle) };
    STATUS_OK
}

fn create_initial(out_handle: *mut XqGameHandle) -> XqStatus {
    if let Err(status) = check_empty_handle(out_handle) {
        return status;
    }
    let game = match Game::standard() {
        Ok(game) => game,
        Err(error) => return status_from_game_error(&error),
    };
    insert_game(out_handle, game)
}

fn clone_game(source: XqGameHandle, out_handle: *mut XqGameHandle) -> XqStatus {
    if let Err(status) = check_empty_handle(out_handle) {
        return status;
    }
    if source == 0 {
        return STATUS_INVALID_HANDLE;
    }
    let game = {
        let registry = game_registry();
        match registry.games.get(&source) {
            Some(game) => game.clone(),
            None => return STATUS_INVALID_HANDLE,
        }
    };
    insert_game(out_handle, game)
}

fn destroy_game(handle: *mut XqGameHandle) -> XqStatus {
    if let Err(status) = validate_writable(handle) {
        return status;
    }
    // SAFETY: a non-null, aligned writable handle pointer is part of the C ABI contract.
    let supplied = unsafe { handle.read() };
    if supplied == 0 {
        return STATUS_INVALID_HANDLE;
    }
    let mut registry = game_registry();
    if registry.games.remove(&supplied).is_none() {
        return STATUS_INVALID_HANDLE;
    }
    // SAFETY: the caller supplied writable handle storage and registry removal succeeded.
    unsafe { handle.write(0) };
    STATUS_OK
}

fn with_game<T>(
    handle: XqGameHandle,
    action: impl FnOnce(&Game) -> Result<T, XqStatus>,
) -> Result<T, XqStatus> {
    if handle == 0 {
        return Err(STATUS_INVALID_HANDLE);
    }
    let registry = game_registry();
    let game = registry.games.get(&handle).ok_or(STATUS_INVALID_HANDLE)?;
    action(game)
}

fn with_game_mut(
    handle: XqGameHandle,
    action: impl FnOnce(&mut Game) -> Result<(), XqStatus>,
) -> XqStatus {
    if handle == 0 {
        return STATUS_INVALID_HANDLE;
    }
    let mut registry = game_registry();
    let Some(game) = registry.games.get_mut(&handle) else {
        return STATUS_INVALID_HANDLE;
    };
    match action(game) {
        Ok(()) => STATUS_OK,
        Err(status) => status,
    }
}

unsafe fn bounded_utf8<'a>(data: *const u8, length: u64) -> Result<&'a str, XqStatus> {
    if length > MAX_INPUT_BYTES as u64 {
        return Err(STATUS_INPUT_TOO_LARGE);
    }
    let length = usize::try_from(length).map_err(|_| STATUS_INPUT_TOO_LARGE)?;
    if length == 0 {
        return Ok("");
    }
    if data.is_null() {
        return Err(STATUS_INVALID_ARGUMENT);
    }
    // SAFETY: length was bounded and a non-null valid readable input range is C caller contract.
    let bytes = unsafe { slice::from_raw_parts(data, length) };
    str::from_utf8(bytes).map_err(|_| STATUS_PARSE_ERROR)
}

fn game_from_fen(data: *const u8, length: u64) -> Result<Game, XqStatus> {
    // SAFETY: this helper is called only by extern functions whose pointer contract is documented.
    let text = unsafe { bounded_utf8(data, length)? };
    parse_fen(text).map_err(|error| status_from_fen_error(&error))
}

fn side_code(side: Side) -> u8 {
    side as u8
}

fn terminal_codes(terminal: TerminalState) -> (u8, u8) {
    match terminal {
        TerminalState::Ongoing => (TERMINAL_ONGOING, SIDE_NONE),
        TerminalState::Checkmate { winner } => (TERMINAL_CHECKMATE, side_code(winner)),
        TerminalState::Stalemate { winner } => (TERMINAL_STALEMATE, side_code(winner)),
    }
}

fn ffi_snapshot(snapshot: BoardSnapshotV1) -> XqBoardSnapshotV1 {
    let (terminal_kind, terminal_winner) = terminal_codes(snapshot.terminal);
    XqBoardSnapshotV1 {
        cells: snapshot.cells,
        side_to_move: side_code(snapshot.side_to_move),
        terminal_kind,
        terminal_winner,
        checked_side: snapshot.checked_side.map_or(SIDE_NONE, side_code),
        reserved0: [0; 3],
        halfmove_clock: snapshot.halfmove_clock,
        fullmove_number: snapshot.fullmove_number,
        current_node_id: snapshot.current_node.0,
        history_length: snapshot.history_length,
        profile_id: snapshot.profile_id,
        profile_version: snapshot.profile_version,
        position_hash: snapshot.position_hash,
        repetition_hash: snapshot.repetition_hash,
    }
}

fn ffi_square_list(squares: Vec<Square>) -> Result<XqSquareListV1, XqStatus> {
    if squares.len() > 90 {
        return Err(STATUS_INTERNAL_ERROR);
    }
    let mut result = XqSquareListV1 {
        count: 0,
        reserved: 0,
        squares: [0; 90],
        reserved_tail: [0; 2],
    };
    let mut seen = [false; 90];
    for (index, square) in squares.into_iter().enumerate() {
        let raw = square.raw() as usize;
        if raw >= 90 || seen[raw] {
            return Err(STATUS_INTERNAL_ERROR);
        }
        seen[raw] = true;
        result.squares[index] = raw as u8;
    }
    result.count = u32::try_from(seen.into_iter().filter(|value| *value).count())
        .map_err(|_| STATUS_INTERNAL_ERROR)?;
    Ok(result)
}

fn raw_move(raw: XqMoveV1) -> Result<Move, XqStatus> {
    if raw.reserved != 0 {
        return Err(STATUS_INVALID_RESERVED);
    }
    let from = Square::new(raw.from).ok_or(STATUS_INVALID_SQUARE)?;
    let to = Square::new(raw.to).ok_or(STATUS_INVALID_SQUARE)?;
    Move::new(from, to).ok_or(STATUS_INVALID_ARGUMENT)
}

fn get_abi_info(out_info: *mut XqAbiInfo) -> XqStatus {
    if let Err(status) = validate_writable(out_info) {
        return status;
    }
    // SAFETY: a non-null, aligned writable output pointer is part of the C ABI contract.
    unsafe { out_info.write(abi_info()) };
    STATUS_OK
}

fn get_capabilities(out_capabilities: *mut u64) -> XqStatus {
    if let Err(status) = validate_writable(out_capabilities) {
        return status;
    }
    // SAFETY: a non-null, aligned writable output pointer is part of the C ABI contract.
    unsafe { out_capabilities.write(CAPABILITIES) };
    STATUS_OK
}

fn validate_abi(expected_major: u32, minimum_minor: u32) -> XqStatus {
    if expected_major != ABI_MAJOR {
        return STATUS_ABI_MAJOR_MISMATCH;
    }
    if minimum_minor > ABI_MINOR {
        return STATUS_ABI_MINOR_MISMATCH;
    }
    STATUS_OK
}

fn get_build_info(out_buffer: *mut XqOwnedBuffer) -> XqStatus {
    let bytes = BUILD_INFO.as_bytes();
    if bytes.len() > MAX_BUILD_INFO_BYTES
        || !BUILD_INFO.contains(ABI_SOURCE_SHA256)
        || !BUILD_INFO.contains(DETERMINISTIC_FEATURES)
    {
        return STATUS_INTERNAL_ERROR;
    }
    allocate_owned_buffer(out_buffer, bytes)
}

fn create_from_fen(data: *const u8, length: u64, out_handle: *mut XqGameHandle) -> XqStatus {
    if let Err(status) = check_empty_handle(out_handle) {
        return status;
    }
    let game = match game_from_fen(data, length) {
        Ok(game) => game,
        Err(status) => return status,
    };
    insert_game(out_handle, game)
}

fn get_snapshot(handle: XqGameHandle, out_snapshot: *mut XqBoardSnapshotV1) -> XqStatus {
    if let Err(status) = validate_writable(out_snapshot) {
        return status;
    }
    let snapshot = match with_game(handle, |game| Ok(ffi_snapshot(game.snapshot()))) {
        Ok(snapshot) => snapshot,
        Err(status) => return status,
    };
    // SAFETY: a non-null, aligned writable output pointer is part of the C ABI contract.
    unsafe { out_snapshot.write(snapshot) };
    STATUS_OK
}

fn get_selectable_squares(handle: XqGameHandle, out_squares: *mut XqSquareListV1) -> XqStatus {
    if let Err(status) = validate_writable(out_squares) {
        return status;
    }
    let list = match with_game(handle, |game| {
        game.selectable_squares()
            .map_err(|error| status_from_game_error(&error))
            .and_then(ffi_square_list)
    }) {
        Ok(list) => list,
        Err(status) => return status,
    };
    // SAFETY: a non-null, aligned writable output pointer is part of the C ABI contract.
    unsafe { out_squares.write(list) };
    STATUS_OK
}

fn get_legal_destinations(
    handle: XqGameHandle,
    from: u8,
    out_squares: *mut XqSquareListV1,
) -> XqStatus {
    if let Err(status) = validate_writable(out_squares) {
        return status;
    }
    let from = match Square::new(from) {
        Some(square) => square,
        None => return STATUS_INVALID_SQUARE,
    };
    let list = match with_game(handle, |game| {
        game.legal_destinations(from)
            .map_err(|error| status_from_game_error(&error))
            .and_then(ffi_square_list)
    }) {
        Ok(list) => list,
        Err(status) => return status,
    };
    // SAFETY: a non-null, aligned writable output pointer is part of the C ABI contract.
    unsafe { out_squares.write(list) };
    STATUS_OK
}

fn apply_move(handle: XqGameHandle, raw: XqMoveV1) -> XqStatus {
    let mv = match raw_move(raw) {
        Ok(mv) => mv,
        Err(status) => return status,
    };
    with_game_mut(handle, |game| {
        game.apply_move(mv)
            .map(|_| ())
            .map_err(|error| status_from_game_error(&error))
    })
}

fn undo(handle: XqGameHandle) -> XqStatus {
    with_game_mut(handle, |game| {
        game.undo()
            .map(|_| ())
            .map_err(|error| status_from_game_error(&error))
    })
}

fn redo(handle: XqGameHandle) -> XqStatus {
    with_game_mut(handle, |game| {
        game.redo()
            .map(|_| ())
            .map_err(|error| status_from_game_error(&error))
    })
}

fn redo_child(handle: XqGameHandle, child_node: u32) -> XqStatus {
    with_game_mut(handle, |game| {
        game.redo_child(NodeId(child_node))
            .map(|_| ())
            .map_err(|error| status_from_game_error(&error))
    })
}

fn navigate(handle: XqGameHandle, target_node: u32) -> XqStatus {
    with_game_mut(handle, |game| {
        game.navigate(NodeId(target_node))
            .map(|_| ())
            .map_err(|error| status_from_game_error(&error))
    })
}

fn copy_fen(handle: XqGameHandle, out_buffer: *mut XqOwnedBuffer) -> XqStatus {
    if let Err(status) = validate_writable(out_buffer) {
        return status;
    }
    let fen = match with_game(handle, |game| {
        write_fen(game).map_err(|error| status_from_game_error(&error))
    }) {
        Ok(fen) => fen,
        Err(status) => return status,
    };
    allocate_owned_buffer(out_buffer, fen.as_bytes())
}

fn replace_from_fen(handle: XqGameHandle, data: *const u8, length: u64) -> XqStatus {
    let replacement = match game_from_fen(data, length) {
        Ok(game) => game,
        Err(status) => return status,
    };
    with_game_mut(handle, |game| {
        *game = replacement;
        Ok(())
    })
}

fn copy_ucci_mainline(handle: XqGameHandle, out_buffer: *mut XqOwnedBuffer) -> XqStatus {
    if let Err(status) = validate_writable(out_buffer) {
        return status;
    }
    let mainline = match with_game(handle, |game| {
        write_ucci_mainline(game).map_err(|error| status_from_game_error(&error))
    }) {
        Ok(mainline) => mainline,
        Err(status) => return status,
    };
    allocate_owned_buffer(out_buffer, mainline.as_bytes())
}

fn write_mainline_result(
    out_result: *mut XqMainlineResultV1,
    status: XqStatus,
    failed_ply: u32,
    accepted: u32,
) {
    // SAFETY: callers check non-null output before invoking this helper.
    unsafe {
        out_result.write(XqMainlineResultV1 {
            accepted_plies: accepted,
            failed_ply,
            status,
            reserved: 0,
        });
    }
}

fn apply_mainline(
    handle: XqGameHandle,
    data: *const u8,
    length: u64,
    out_result: *mut XqMainlineResultV1,
) -> XqStatus {
    if let Err(status) = validate_writable(out_result) {
        return status;
    }
    // SAFETY: this helper runs inside an extern call with the documented input-pointer contract.
    let input = match unsafe { bounded_utf8(data, length) } {
        Ok(input) => input,
        Err(status) => {
            write_mainline_result(out_result, status, 0, 0);
            return status;
        }
    };
    if handle == 0 {
        write_mainline_result(out_result, STATUS_INVALID_HANDLE, 0, 0);
        return STATUS_INVALID_HANDLE;
    }
    let mut registry = game_registry();
    let Some(game) = registry.games.get_mut(&handle) else {
        write_mainline_result(out_result, STATUS_INVALID_HANDLE, 0, 0);
        return STATUS_INVALID_HANDLE;
    };
    match apply_ucci_mainline(game, input) {
        Ok(accepted) => {
            write_mainline_result(out_result, STATUS_OK, 0, accepted);
            STATUS_OK
        }
        Err(error) => {
            let status = status_from_ucci_error(&error);
            write_mainline_result(out_result, status, error.failing_ply().unwrap_or(0), 0);
            status
        }
    }
}

fn get_history_summary(handle: XqGameHandle, out_summary: *mut XqHistorySummaryV1) -> XqStatus {
    if let Err(status) = validate_writable(out_summary) {
        return status;
    }
    let summary = match with_game(handle, |game| {
        game.history_summary()
            .map_err(|error| status_from_game_error(&error))
    }) {
        Ok(summary) => summary,
        Err(status) => return status,
    };
    let output = XqHistorySummaryV1 {
        schema_version: summary.schema_version,
        has_repetition_candidate: u8::from(summary.has_repetition_candidate),
        wxf_responsibility_supported: u8::from(summary.wxf_responsibility_supported),
        profile_id: summary.profile_id,
        profile_version: summary.profile_version,
        position_count: summary.position_count,
        event_count: summary.event_count,
        current_repetition_hash: summary.current_repetition_hash,
    };
    // SAFETY: a non-null, aligned writable output pointer is part of the C ABI contract.
    unsafe { out_summary.write(output) };
    STATUS_OK
}

/// Writes ABI information to caller-provided POD storage.
///
/// # Safety
/// `out_info` must be non-null, aligned, and writable for `XqAbiInfo`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_ffi_get_abi_info(out_info: *mut XqAbiInfo) -> XqStatus {
    boundary(|| get_abi_info(out_info))
}

/// Writes the capability bitmap to caller-provided POD storage.
///
/// # Safety
/// `out_capabilities` must be non-null, aligned, and writable for `u64`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_ffi_get_capabilities(out_capabilities: *mut u64) -> XqStatus {
    boundary(|| get_capabilities(out_capabilities))
}

#[unsafe(no_mangle)]
pub extern "C" fn xq_ffi_validate_abi(expected_major: u32, minimum_minor: u32) -> XqStatus {
    boundary(|| validate_abi(expected_major, minimum_minor))
}

/// # Safety
/// `out_buffer` must be initialized to `XqOwnedBuffer::EMPTY` and writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_ffi_get_build_info(out_buffer: *mut XqOwnedBuffer) -> XqStatus {
    boundary(|| get_build_info(out_buffer))
}

/// # Safety
/// `buffer` must point to writable initialized `XqOwnedBuffer` storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_ffi_buffer_release(buffer: *mut XqOwnedBuffer) -> XqStatus {
    boundary(|| buffer_release(buffer))
}

/// # Safety
/// `out_handle` must be initialized to zero and writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_game_create_initial(out_handle: *mut XqGameHandle) -> XqStatus {
    boundary(|| create_initial(out_handle))
}

/// # Safety
/// `fen_bytes` must be readable for `length` bytes when nonempty and `out_handle` must be zero/writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_game_create_from_fen(
    fen_bytes: *const u8,
    length: u64,
    out_handle: *mut XqGameHandle,
) -> XqStatus {
    boundary(|| create_from_fen(fen_bytes, length, out_handle))
}

/// # Safety
/// `out_handle` must be initialized to zero and writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_game_clone(
    source: XqGameHandle,
    out_handle: *mut XqGameHandle,
) -> XqStatus {
    boundary(|| clone_game(source, out_handle))
}

/// # Safety
/// `handle` must point to initialized writable handle storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_game_destroy(handle: *mut XqGameHandle) -> XqStatus {
    boundary(|| destroy_game(handle))
}

/// # Safety
/// `out_snapshot` must be non-null, aligned, and writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_game_get_snapshot(
    handle: XqGameHandle,
    out_snapshot: *mut XqBoardSnapshotV1,
) -> XqStatus {
    boundary(|| get_snapshot(handle, out_snapshot))
}

/// # Safety
/// `out_squares` must be non-null, aligned, and writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_game_get_selectable_squares(
    handle: XqGameHandle,
    out_squares: *mut XqSquareListV1,
) -> XqStatus {
    boundary(|| get_selectable_squares(handle, out_squares))
}

/// # Safety
/// `out_squares` must be non-null, aligned, and writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_game_get_legal_destinations(
    handle: XqGameHandle,
    from: u8,
    out_squares: *mut XqSquareListV1,
) -> XqStatus {
    boundary(|| get_legal_destinations(handle, from, out_squares))
}

#[unsafe(no_mangle)]
pub extern "C" fn xq_game_apply_move(handle: XqGameHandle, mv: XqMoveV1) -> XqStatus {
    boundary(|| apply_move(handle, mv))
}

#[unsafe(no_mangle)]
pub extern "C" fn xq_game_undo(handle: XqGameHandle) -> XqStatus {
    boundary(|| undo(handle))
}

#[unsafe(no_mangle)]
pub extern "C" fn xq_game_redo(handle: XqGameHandle) -> XqStatus {
    boundary(|| redo(handle))
}

#[unsafe(no_mangle)]
pub extern "C" fn xq_game_redo_child(handle: XqGameHandle, child_node: u32) -> XqStatus {
    boundary(|| redo_child(handle, child_node))
}

#[unsafe(no_mangle)]
pub extern "C" fn xq_game_navigate(handle: XqGameHandle, target_node: u32) -> XqStatus {
    boundary(|| navigate(handle, target_node))
}

/// # Safety
/// `out_buffer` must be initialized to `XqOwnedBuffer::EMPTY` and writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_game_copy_fen(
    handle: XqGameHandle,
    out_buffer: *mut XqOwnedBuffer,
) -> XqStatus {
    boundary(|| copy_fen(handle, out_buffer))
}

/// # Safety
/// `fen_bytes` must be readable for `length` bytes when nonempty.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_game_replace_from_fen(
    handle: XqGameHandle,
    fen_bytes: *const u8,
    length: u64,
) -> XqStatus {
    boundary(|| replace_from_fen(handle, fen_bytes, length))
}

/// # Safety
/// `out_buffer` must be initialized to `XqOwnedBuffer::EMPTY` and writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_game_copy_ucci_mainline(
    handle: XqGameHandle,
    out_buffer: *mut XqOwnedBuffer,
) -> XqStatus {
    boundary(|| copy_ucci_mainline(handle, out_buffer))
}

/// # Safety
/// `ucci_bytes` must be readable for `length` bytes when nonempty and `out_result` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_game_apply_ucci_mainline(
    handle: XqGameHandle,
    ucci_bytes: *const u8,
    length: u64,
    out_result: *mut XqMainlineResultV1,
) -> XqStatus {
    boundary(|| apply_mainline(handle, ucci_bytes, length, out_result))
}

/// # Safety
/// `out_summary` must be non-null, aligned, and writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_game_get_history_summary(
    handle: XqGameHandle,
    out_summary: *mut XqHistorySummaryV1,
) -> XqStatus {
    boundary(|| get_history_summary(handle, out_summary))
}

#[cfg(test)]
mod tests {
    use std::{
        mem, ptr, slice,
        sync::{LazyLock, Mutex, MutexGuard},
    };

    use super::*;

    static TEST_SERIAL: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

    fn serial_test_guard() -> MutexGuard<'static, ()> {
        match TEST_SERIAL.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    fn initial_handle() -> XqGameHandle {
        let mut handle = 0;
        // SAFETY: handle is initialized writable storage.
        assert_eq!(unsafe { xq_game_create_initial(&mut handle) }, STATUS_OK);
        handle
    }

    fn destroy(handle: &mut XqGameHandle) {
        // SAFETY: handle is initialized writable storage.
        assert_eq!(unsafe { xq_game_destroy(handle) }, STATUS_OK);
        assert_eq!(*handle, 0);
    }

    fn misaligned_pointer<T>(storage: &mut Vec<u8>) -> *mut T {
        let alignment = mem::align_of::<T>();
        assert!(
            alignment > 1,
            "test type must have an alignment requirement"
        );
        storage.resize(mem::size_of::<T>() + alignment + 1, 0);
        let base = storage.as_mut_ptr().addr();
        let aligned = (base + alignment - 1) & !(alignment - 1);
        let offset = aligned - base + 1;
        // SAFETY: offset remains inside the storage allocation; this pointer is intentionally
        // misaligned and is only passed to APIs that reject it before dereferencing.
        unsafe { storage.as_mut_ptr().add(offset).cast::<T>() }
    }

    #[test]
    fn abi_info_and_capabilities_include_additive_t020_features() {
        let _serial = serial_test_guard();
        let mut info = XqAbiInfo {
            abi_major: 0,
            abi_minor: 0,
            capabilities: 0,
            build_info_format: 0,
            reserved: u32::MAX,
        };
        let mut capabilities = 0_u64;
        // SAFETY: output variables are valid writable storage.
        assert_eq!(unsafe { xq_ffi_get_abi_info(&mut info) }, STATUS_OK);
        // SAFETY: output variable is valid writable storage.
        assert_eq!(
            unsafe { xq_ffi_get_capabilities(&mut capabilities) },
            STATUS_OK
        );
        assert_eq!(info, abi_info());
        assert_eq!(capabilities, CAPABILITIES);
        assert_ne!(capabilities & CAPABILITY_GAME_HANDLES, 0);
        assert_eq!(xq_ffi_validate_abi(ABI_MAJOR, ABI_MINOR), STATUS_OK);
        assert_eq!(
            xq_ffi_validate_abi(ABI_MAJOR.saturating_add(1), ABI_MINOR),
            STATUS_ABI_MAJOR_MISMATCH
        );
        assert_eq!(
            xq_ffi_validate_abi(ABI_MAJOR, ABI_MINOR.saturating_add(1)),
            STATUS_ABI_MINOR_MISMATCH
        );
    }

    #[test]
    fn null_outputs_and_bad_handles_are_rejected() {
        let _serial = serial_test_guard();
        // SAFETY: null values are explicit invalid-input test cases.
        assert_eq!(
            unsafe { xq_ffi_get_abi_info(ptr::null_mut()) },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: null values are explicit invalid-input test cases.
        assert_eq!(
            unsafe { xq_ffi_get_capabilities(ptr::null_mut()) },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: null values are explicit invalid-input test cases.
        assert_eq!(
            unsafe { xq_ffi_get_build_info(ptr::null_mut()) },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: null values are explicit invalid-input test cases.
        assert_eq!(
            unsafe { xq_ffi_buffer_release(ptr::null_mut()) },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: null values are explicit invalid-input test cases.
        assert_eq!(
            unsafe { xq_game_create_initial(ptr::null_mut()) },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: null values are explicit invalid-input test cases.
        assert_eq!(
            unsafe { xq_game_destroy(ptr::null_mut()) },
            STATUS_INVALID_ARGUMENT
        );
        let mut rejected_handle = XqGameHandle::default();
        // SAFETY: the length is rejected before the null input pointer is observed.
        assert_eq!(
            unsafe {
                xq_game_create_from_fen(
                    ptr::null(),
                    MAX_INPUT_BYTES as u64 + 1,
                    &mut rejected_handle,
                )
            },
            STATUS_INPUT_TOO_LARGE
        );
        assert_eq!(rejected_handle, 0);
        let mut snapshot = XqBoardSnapshotV1 {
            cells: [0; 90],
            side_to_move: 0,
            terminal_kind: 0,
            terminal_winner: 0,
            checked_side: 0,
            reserved0: [0; 3],
            halfmove_clock: 0,
            fullmove_number: 0,
            current_node_id: 0,
            history_length: 0,
            profile_id: 0,
            profile_version: 0,
            position_hash: 0,
            repetition_hash: 0,
        };
        // SAFETY: snapshot is writable but handle is forged.
        assert_eq!(
            unsafe { xq_game_get_snapshot(999_999, &mut snapshot) },
            STATUS_INVALID_HANDLE
        );
    }

    #[test]
    fn misaligned_typed_pointers_are_rejected_before_any_dereference() {
        let _serial = serial_test_guard();
        let mut storage = Vec::new();
        // SAFETY: the FFI must reject the deliberately misaligned byte-buffer pointer.
        assert_eq!(
            unsafe { xq_ffi_get_abi_info(misaligned_pointer::<XqAbiInfo>(&mut storage)) },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: the FFI must reject the deliberately misaligned byte-buffer pointer.
        assert_eq!(
            unsafe { xq_ffi_get_capabilities(misaligned_pointer::<u64>(&mut storage)) },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: the FFI must reject the deliberately misaligned byte-buffer pointer.
        assert_eq!(
            unsafe { xq_ffi_get_build_info(misaligned_pointer::<XqOwnedBuffer>(&mut storage)) },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: the FFI must reject the deliberately misaligned byte-buffer pointer.
        assert_eq!(
            unsafe { xq_ffi_buffer_release(misaligned_pointer::<XqOwnedBuffer>(&mut storage)) },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: the FFI must reject the deliberately misaligned byte-buffer pointer.
        assert_eq!(
            unsafe { xq_game_create_initial(misaligned_pointer::<XqGameHandle>(&mut storage)) },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: output-pointer validation precedes FEN input validation.
        assert_eq!(
            unsafe {
                xq_game_create_from_fen(
                    ptr::null(),
                    0,
                    misaligned_pointer::<XqGameHandle>(&mut storage),
                )
            },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: output-pointer validation precedes source handle lookup.
        assert_eq!(
            unsafe { xq_game_clone(0, misaligned_pointer::<XqGameHandle>(&mut storage)) },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: the FFI must reject the deliberately misaligned byte-buffer pointer.
        assert_eq!(
            unsafe { xq_game_destroy(misaligned_pointer::<XqGameHandle>(&mut storage)) },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: output-pointer validation precedes handle lookup.
        assert_eq!(
            unsafe {
                xq_game_get_snapshot(0, misaligned_pointer::<XqBoardSnapshotV1>(&mut storage))
            },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: output-pointer validation precedes handle lookup.
        assert_eq!(
            unsafe {
                xq_game_get_selectable_squares(
                    0,
                    misaligned_pointer::<XqSquareListV1>(&mut storage),
                )
            },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: output-pointer validation precedes handle lookup.
        assert_eq!(
            unsafe {
                xq_game_get_legal_destinations(
                    0,
                    0,
                    misaligned_pointer::<XqSquareListV1>(&mut storage),
                )
            },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: result-pointer validation precedes input and handle processing.
        assert_eq!(
            unsafe {
                xq_game_apply_ucci_mainline(
                    0,
                    ptr::null(),
                    0,
                    misaligned_pointer::<XqMainlineResultV1>(&mut storage),
                )
            },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: output-pointer validation precedes handle lookup.
        assert_eq!(
            unsafe {
                xq_game_get_history_summary(
                    0,
                    misaligned_pointer::<XqHistorySummaryV1>(&mut storage),
                )
            },
            STATUS_INVALID_ARGUMENT
        );

        let mut handle = initial_handle();
        // SAFETY: output-pointer validation precedes serializing a live game.
        assert_eq!(
            unsafe { xq_game_copy_fen(handle, misaligned_pointer::<XqOwnedBuffer>(&mut storage)) },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: output-pointer validation precedes serializing a live game.
        assert_eq!(
            unsafe {
                xq_game_copy_ucci_mainline(
                    handle,
                    misaligned_pointer::<XqOwnedBuffer>(&mut storage),
                )
            },
            STATUS_INVALID_ARGUMENT
        );
        destroy(&mut handle);
    }

    #[test]
    fn malformed_and_double_buffer_releases_do_not_free_foreign_memory() {
        let _serial = serial_test_guard();
        let mut forged = XqOwnedBuffer {
            data: ptr::dangling_mut(),
            len: 1,
            capacity: 1,
            allocation_token: 0,
        };
        // SAFETY: forged is writable POD but does not name a registered allocation.
        assert_eq!(
            unsafe { xq_ffi_buffer_release(&mut forged) },
            STATUS_INVALID_OWNED_BUFFER
        );
        let mut output = XqOwnedBuffer::EMPTY;
        // SAFETY: output is writable initialized POD storage.
        assert_eq!(unsafe { xq_ffi_get_build_info(&mut output) }, STATUS_OK);
        let mut mismatched = XqOwnedBuffer {
            data: output.data,
            len: output.len.saturating_sub(1),
            capacity: output.capacity,
            allocation_token: output.allocation_token,
        };
        // SAFETY: mismatched has altered metadata and must not free the real allocation.
        assert_eq!(
            unsafe { xq_ffi_buffer_release(&mut mismatched) },
            STATUS_INVALID_OWNED_BUFFER
        );
        // SAFETY: output retains exact registry metadata.
        assert_eq!(unsafe { xq_ffi_buffer_release(&mut output) }, STATUS_OK);
        // SAFETY: output is now empty and double release is rejected.
        assert_eq!(
            unsafe { xq_ffi_buffer_release(&mut output) },
            STATUS_INVALID_OWNED_BUFFER
        );
    }

    #[test]
    fn build_info_is_bounded_utf8_and_one_hundred_thousand_lifecycles_leave_no_live_buffer() {
        let _serial = serial_test_guard();
        for _ in 0..100_000 {
            let mut output = XqOwnedBuffer::EMPTY;
            // SAFETY: output is writable initialized POD storage.
            assert_eq!(unsafe { xq_ffi_get_build_info(&mut output) }, STATUS_OK);
            assert!(output.len <= MAX_BUILD_INFO_BYTES);
            // SAFETY: API returned this registered pointer/length.
            let bytes = unsafe { slice::from_raw_parts(output.data, output.len) };
            assert!(str::from_utf8(bytes).is_ok());
            // SAFETY: output retains exact registry metadata.
            assert_eq!(unsafe { xq_ffi_buffer_release(&mut output) }, STATUS_OK);
        }
        assert!(buffer_registry().allocations.is_empty());
    }

    #[test]
    fn game_lifecycle_snapshot_batches_and_transactional_mainline_work() {
        let _serial = serial_test_guard();
        let standard_fen = b"rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1";
        let mut parsed_handle = 0;
        // SAFETY: input bytes remain live and output storage is initialized to the invalid token.
        assert_eq!(
            unsafe {
                xq_game_create_from_fen(
                    standard_fen.as_ptr(),
                    standard_fen.len() as u64,
                    &mut parsed_handle,
                )
            },
            STATUS_OK
        );
        assert_ne!(parsed_handle, 0);
        // SAFETY: a nonempty output token must not be overwritten.
        assert_eq!(
            unsafe {
                xq_game_create_from_fen(
                    standard_fen.as_ptr(),
                    standard_fen.len() as u64,
                    &mut parsed_handle,
                )
            },
            STATUS_OUTPUT_NOT_EMPTY
        );
        // SAFETY: malformed UTF8 FEN input is bounded and output is initialized invalid storage.
        let mut rejected_handle = 0;
        assert_eq!(
            unsafe { xq_game_create_from_fen(b"bad".as_ptr(), 3, &mut rejected_handle) },
            STATUS_PARSE_ERROR
        );
        assert_eq!(rejected_handle, 0);
        destroy(&mut parsed_handle);

        let mut handle = initial_handle();
        let mut snapshot = XqBoardSnapshotV1 {
            cells: [0; 90],
            side_to_move: SIDE_NONE,
            terminal_kind: 0,
            terminal_winner: SIDE_NONE,
            checked_side: SIDE_NONE,
            reserved0: [0; 3],
            halfmove_clock: 0,
            fullmove_number: 0,
            current_node_id: 0,
            history_length: 0,
            profile_id: 0,
            profile_version: 0,
            position_hash: 0,
            repetition_hash: 0,
        };
        // SAFETY: snapshot is writable POD storage.
        assert_eq!(
            unsafe { xq_game_get_snapshot(handle, &mut snapshot) },
            STATUS_OK
        );
        assert_eq!(snapshot.side_to_move, Side::Red as u8);
        assert_eq!(snapshot.cells.iter().filter(|cell| **cell != 0).count(), 32);

        let mut selectable = XqSquareListV1 {
            count: 0,
            reserved: 0,
            squares: [0; 90],
            reserved_tail: [0; 2],
        };
        // SAFETY: selectable is writable POD storage.
        assert_eq!(
            unsafe { xq_game_get_selectable_squares(handle, &mut selectable) },
            STATUS_OK
        );
        assert!(selectable.count > 0 && selectable.count <= 90);
        let mut destinations = XqSquareListV1 {
            count: 0,
            reserved: 0,
            squares: [0; 90],
            reserved_tail: [0; 2],
        };
        // SAFETY: destination list is writable POD storage.
        assert_eq!(
            unsafe { xq_game_get_legal_destinations(handle, 19, &mut destinations) },
            STATUS_OK
        );
        assert!(destinations.count > 0);

        let input = b"b2b3 b7b6 a0a9";
        let mut result = XqMainlineResultV1 {
            accepted_plies: 0,
            failed_ply: 0,
            status: 0,
            reserved: 0,
        };
        // SAFETY: input bytes remain live for the call and result is writable.
        assert_eq!(
            unsafe {
                xq_game_apply_ucci_mainline(handle, input.as_ptr(), input.len() as u64, &mut result)
            },
            STATUS_ILLEGAL_MOVE
        );
        assert_eq!(result.failed_ply, 3);
        assert_eq!(result.accepted_plies, 0);
        // SAFETY: snapshot is writable POD storage.
        assert_eq!(
            unsafe { xq_game_get_snapshot(handle, &mut snapshot) },
            STATUS_OK
        );
        assert_eq!(snapshot.history_length, 1);

        let too_many_tokens = b"a0a1 ".repeat(xiangqi_io::MAX_UCCI_PLIES + 1);
        // SAFETY: input bytes remain live for the call and result is writable.
        assert_eq!(
            unsafe {
                xq_game_apply_ucci_mainline(
                    handle,
                    too_many_tokens.as_ptr(),
                    too_many_tokens.len() as u64,
                    &mut result,
                )
            },
            STATUS_RESOURCE_LIMIT
        );
        assert_eq!(result.status, STATUS_RESOURCE_LIMIT);
        assert_eq!(result.accepted_plies, 0);
        assert_eq!(result.failed_ply, 0);
        // SAFETY: snapshot is writable POD storage.
        assert_eq!(
            unsafe { xq_game_get_snapshot(handle, &mut snapshot) },
            STATUS_OK
        );
        assert_eq!(snapshot.history_length, 1);

        let valid = b"b2b3 b7b6";
        // SAFETY: input bytes remain live for the call and result is writable.
        assert_eq!(
            unsafe {
                xq_game_apply_ucci_mainline(handle, valid.as_ptr(), valid.len() as u64, &mut result)
            },
            STATUS_OK
        );
        assert_eq!(result.accepted_plies, 2);
        let mut fen = XqOwnedBuffer::EMPTY;
        // SAFETY: fen is writable initialized POD storage.
        assert_eq!(unsafe { xq_game_copy_fen(handle, &mut fen) }, STATUS_OK);
        // SAFETY: FFI returned this owned buffer.
        let fen_text =
            unsafe { str::from_utf8(slice::from_raw_parts(fen.data, fen.len)) }.expect("UTF8 FEN");
        assert!(fen_text.contains(" w - - "));
        // SAFETY: fen retains exact registered metadata.
        assert_eq!(unsafe { xq_ffi_buffer_release(&mut fen) }, STATUS_OK);
        let mut history = XqHistorySummaryV1 {
            schema_version: 0,
            has_repetition_candidate: 0,
            wxf_responsibility_supported: 1,
            profile_id: 0,
            profile_version: 0,
            position_count: 0,
            event_count: 0,
            current_repetition_hash: 0,
        };
        // SAFETY: history is writable POD storage.
        assert_eq!(
            unsafe { xq_game_get_history_summary(handle, &mut history) },
            STATUS_OK
        );
        assert_eq!(history.wxf_responsibility_supported, 0);
        assert_eq!(history.event_count, 2);
        destroy(&mut handle);
        // SAFETY: handle is empty writable storage after destroy.
        assert_eq!(
            unsafe { xq_game_destroy(&mut handle) },
            STATUS_INVALID_HANDLE
        );
    }

    #[test]
    fn game_handle_tokens_reject_stale_forged_and_one_hundred_thousand_lifecycles() {
        let _serial = serial_test_guard();
        let mut first = initial_handle();
        let stale = first;
        destroy(&mut first);
        let mut second = initial_handle();
        assert_ne!(second, stale);
        let mut snapshot = XqBoardSnapshotV1 {
            cells: [0; 90],
            side_to_move: 0,
            terminal_kind: 0,
            terminal_winner: 0,
            checked_side: 0,
            reserved0: [0; 3],
            halfmove_clock: 0,
            fullmove_number: 0,
            current_node_id: 0,
            history_length: 0,
            profile_id: 0,
            profile_version: 0,
            position_hash: 0,
            repetition_hash: 0,
        };
        // SAFETY: snapshot is writable and stale is an explicit invalid handle test.
        assert_eq!(
            unsafe { xq_game_get_snapshot(stale, &mut snapshot) },
            STATUS_INVALID_HANDLE
        );
        destroy(&mut second);
        for _ in 0..100_000 {
            let mut handle = initial_handle();
            destroy(&mut handle);
        }
        assert!(game_registry().games.is_empty());
    }

    #[test]
    fn live_game_registry_limit_recovers_after_explicit_destroy() {
        let _serial = serial_test_guard();
        let mut handles = Vec::new();
        handles
            .try_reserve_exact(MAX_LIVE_GAMES)
            .expect("fixed registry test capacity");
        for _ in 0..MAX_LIVE_GAMES {
            handles.push(initial_handle());
        }
        let mut rejected = 0;
        // SAFETY: rejected is initialized writable handle storage.
        assert_eq!(
            unsafe { xq_game_create_initial(&mut rejected) },
            STATUS_RESOURCE_LIMIT
        );
        assert_eq!(rejected, 0);
        for handle in &mut handles {
            destroy(handle);
        }
        assert!(game_registry().games.is_empty());
        let mut recovered = 0;
        // SAFETY: recovered is initialized writable handle storage after capacity release.
        assert_eq!(unsafe { xq_game_create_initial(&mut recovered) }, STATUS_OK);
        destroy(&mut recovered);
    }
}
