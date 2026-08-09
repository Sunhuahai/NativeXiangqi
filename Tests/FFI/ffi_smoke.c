#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "xiangqi_ffi.h"

static void *misaligned_pointer(uint8_t *storage, size_t alignment) {
  uintptr_t base = (uintptr_t)storage;
  uintptr_t aligned = (base + alignment - 1u) & ~(uintptr_t)(alignment - 1u);
  return (void *)(aligned + 1u);
}

int main(void) {
  xq_ffi_abi_info_t info = {0};
  uint64_t capabilities = 0;
  xq_game_handle_t handle = XQ_GAME_HANDLE_INVALID;
  xq_game_handle_t clone = XQ_GAME_HANDLE_INVALID;
  xq_board_snapshot_v1_t snapshot = {0};
  xq_square_list_v1_t selectable = {0};
  xq_square_list_v1_t destinations = {0};
  xq_history_summary_v1_t history = {0};
  xq_mainline_result_v1_t result = {0};
  xq_variation_child_list_v1_t children = {0};
  xq_fen_result_v1_t fen_result = {0};
  xq_owned_buffer_t buffer = XQ_OWNED_BUFFER_INIT;
  xq_document_restore_handle_t restore = XQ_DOCUMENT_RESTORE_HANDLE_INVALID;
  xq_document_restore_handle_t stale_restore = XQ_DOCUMENT_RESTORE_HANDLE_INVALID;
  xq_game_handle_t restored_game = XQ_GAME_HANDLE_INVALID;
  uint8_t misaligned_info_storage[sizeof(xq_ffi_abi_info_t) + _Alignof(xq_ffi_abi_info_t) + 1u] = {0};
  const uint8_t bad_mainline[] = "b7b6 a0a9";
  const uint8_t valid_mainline[] = "b7b6";
  const uint8_t mate_fen[] = "3RkR3/9/4P4/9/9/9/9/9/9/4K4 b - - 0 1";
  const uint8_t standard_fen[] =
      "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1";

  assert(xq_ffi_get_abi_info(NULL) == XQ_STATUS_INVALID_ARGUMENT);
  assert(xq_ffi_get_capabilities(NULL) == XQ_STATUS_INVALID_ARGUMENT);
  assert(xq_ffi_get_build_info(NULL) == XQ_STATUS_INVALID_ARGUMENT);
  assert(xq_ffi_buffer_release(NULL) == XQ_STATUS_INVALID_ARGUMENT);
  assert(xq_game_create_initial(NULL) == XQ_STATUS_INVALID_ARGUMENT);
  assert(xq_game_destroy(NULL) == XQ_STATUS_INVALID_ARGUMENT);
  assert(xq_game_get_variation_children(0, 0u, NULL) == XQ_STATUS_INVALID_ARGUMENT);
  assert(xq_document_restore_destroy(NULL) == XQ_STATUS_INVALID_ARGUMENT);
  assert(xq_ffi_get_abi_info(
             (xq_ffi_abi_info_t *)misaligned_pointer(
                 misaligned_info_storage,
                 _Alignof(xq_ffi_abi_info_t))) == XQ_STATUS_INVALID_ARGUMENT);

  assert(xq_ffi_get_abi_info(&info) == XQ_STATUS_OK);
  assert(info.abi_major == XQ_FFI_ABI_MAJOR);
  assert(info.abi_minor >= XQ_FFI_ABI_MINOR);
  assert(info.build_info_format == XQ_FFI_BUILD_INFO_FORMAT);
  assert((info.capabilities & XQ_CAPABILITY_ABI_INFO) != 0);
  assert((info.capabilities & XQ_CAPABILITY_GAME_HANDLES) != 0);
  assert((info.capabilities & XQ_CAPABILITY_BATCH_RULES) != 0);
  assert((info.capabilities & XQ_CAPABILITY_FEN_UCCI) != 0);
  assert((info.capabilities & XQ_CAPABILITY_BASE_HISTORY) != 0);
  assert((info.capabilities & XQ_CAPABILITY_DOCUMENT_TREE) != 0);
  assert((info.capabilities & XQ_CAPABILITY_DOCUMENT_RESTORE) != 0);
  assert(xq_ffi_get_capabilities(&capabilities) == XQ_STATUS_OK);
  assert(capabilities == info.capabilities);
  assert(xq_ffi_validate_abi(XQ_FFI_ABI_MAJOR, XQ_FFI_ABI_MINOR) == XQ_STATUS_OK);
  assert(xq_ffi_validate_abi(XQ_FFI_ABI_MAJOR + 1u, XQ_FFI_ABI_MINOR) == XQ_STATUS_ABI_MAJOR_MISMATCH);

  assert(xq_ffi_get_build_info(&buffer) == XQ_STATUS_OK);
  assert(buffer.data != NULL);
  assert(buffer.len > 0u);
  assert(buffer.len <= XQ_FFI_MAX_BUILD_INFO_BYTES);
  assert(buffer.capacity >= buffer.len);
  assert(xq_ffi_buffer_release(&buffer) == XQ_STATUS_OK);
  assert(buffer.data == NULL);
  assert(xq_ffi_buffer_release(&buffer) == XQ_STATUS_INVALID_OWNED_BUFFER);

  assert(xq_game_create_from_fen(
             standard_fen,
             (uint64_t)(sizeof(standard_fen) - 1u),
             &clone) == XQ_STATUS_OK);
  assert(clone != XQ_GAME_HANDLE_INVALID);
  assert(xq_game_create_from_fen(
             standard_fen,
             (uint64_t)(sizeof(standard_fen) - 1u),
             &clone) == XQ_STATUS_OUTPUT_NOT_EMPTY);
  assert(xq_game_destroy(&clone) == XQ_STATUS_OK);
  assert(xq_game_create_from_fen((const uint8_t *)"bad", UINT64_C(3), &clone) == XQ_STATUS_PARSE_ERROR);
  assert(clone == XQ_GAME_HANDLE_INVALID);
  assert(xq_game_create_from_fen(
             NULL,
             XQ_FFI_MAX_INPUT_BYTES + UINT64_C(1),
             &clone) == XQ_STATUS_INPUT_TOO_LARGE);
  assert(clone == XQ_GAME_HANDLE_INVALID);
  assert(xq_game_create_from_fen_diagnostic(
             (const uint8_t *)"bad",
             UINT64_C(3),
             &clone,
             &fen_result) == XQ_STATUS_PARSE_ERROR);
  assert(clone == XQ_GAME_HANDLE_INVALID);
  assert(fen_result.status == XQ_STATUS_PARSE_ERROR);
  assert(fen_result.field == XQ_FEN_FIELD_FIELD_COUNT);
  assert(fen_result.reserved0 == 0u && fen_result.reserved1 == 0u);

  {
    union {
      xq_game_handle_t game;
      xq_fen_result_v1_t diagnostic;
    } overlap = {.game = XQ_GAME_HANDLE_INVALID};
    assert(xq_game_create_from_fen_diagnostic(
               standard_fen,
               (uint64_t)(sizeof(standard_fen) - 1u),
               &overlap.game,
               &overlap.diagnostic) == XQ_STATUS_INVALID_ARGUMENT);
    assert(overlap.game == XQ_GAME_HANDLE_INVALID);
  }

  assert(xq_game_create_initial(&handle) == XQ_STATUS_OK);
  assert(handle != XQ_GAME_HANDLE_INVALID);
  assert(xq_game_create_initial(&handle) == XQ_STATUS_OUTPUT_NOT_EMPTY);
  assert(xq_game_get_snapshot(handle, NULL) == XQ_STATUS_INVALID_ARGUMENT);
  assert(xq_game_get_snapshot(handle, &snapshot) == XQ_STATUS_OK);
  assert(snapshot.side_to_move == 0u);
  assert(snapshot.history_length == 1u);
  assert(snapshot.profile_id == 1u);
  assert(snapshot.profile_version == 1u);
  assert(snapshot.terminal_kind == 0u);
  assert(xq_game_get_selectable_squares(handle, &selectable) == XQ_STATUS_OK);
  assert(selectable.count > 0u && selectable.count <= XQ_FFI_SQUARE_COUNT);
  assert(xq_game_get_legal_destinations(handle, 19u, &destinations) == XQ_STATUS_OK);
  assert(destinations.count > 0u && destinations.count <= XQ_FFI_SQUARE_COUNT);
  assert(xq_game_get_legal_destinations(handle, 90u, &destinations) == XQ_STATUS_INVALID_SQUARE);

  {
    uint8_t too_many_tokens[(4096u + 1u) * 5u];
    size_t index = 0u;
    while (index < sizeof(too_many_tokens)) {
      too_many_tokens[index++] = (uint8_t)'a';
      too_many_tokens[index++] = (uint8_t)'0';
      too_many_tokens[index++] = (uint8_t)'a';
      too_many_tokens[index++] = (uint8_t)'1';
      too_many_tokens[index++] = (uint8_t)' ';
    }
    assert(xq_game_apply_ucci_mainline(
               handle,
               too_many_tokens,
               (uint64_t)sizeof(too_many_tokens),
               &result) == XQ_STATUS_RESOURCE_LIMIT);
    assert(result.status == XQ_STATUS_RESOURCE_LIMIT);
    assert(result.accepted_plies == 0u);
    assert(result.failed_ply == 0u);
    assert(xq_game_get_snapshot(handle, &snapshot) == XQ_STATUS_OK);
    assert(snapshot.history_length == 1u);
  }

  {
    const xq_move_v1_t invalid_reserved = {19u, 28u, 1u};
    const xq_move_v1_t valid = {19u, 28u, 0u};
    assert(xq_game_apply_move(handle, invalid_reserved) == XQ_STATUS_INVALID_RESERVED);
    assert(xq_game_apply_move(handle, valid) == XQ_STATUS_OK);
  }
  assert(xq_game_get_snapshot(handle, &snapshot) == XQ_STATUS_OK);
  assert(snapshot.side_to_move == 1u);
  assert(snapshot.history_length == 2u);
  assert(xq_game_undo(handle) == XQ_STATUS_OK);
  assert(xq_game_redo(handle) == XQ_STATUS_OK);

  assert(xq_game_apply_ucci_mainline(
             handle,
             bad_mainline,
             (uint64_t)(sizeof(bad_mainline) - 1u),
             &result) == XQ_STATUS_ILLEGAL_MOVE);
  assert(result.status == XQ_STATUS_ILLEGAL_MOVE);
  assert(result.accepted_plies == 0u);
  assert(result.failed_ply == 2u);
  assert(xq_game_get_snapshot(handle, &snapshot) == XQ_STATUS_OK);
  assert(snapshot.history_length == 2u);
  assert(xq_game_apply_ucci_mainline(
             handle,
             valid_mainline,
             (uint64_t)(sizeof(valid_mainline) - 1u),
             &result) == XQ_STATUS_OK);
  assert(result.accepted_plies == 1u);
  assert(result.failed_ply == 0u);
  assert(xq_game_get_history_summary(handle, &history) == XQ_STATUS_OK);
  assert(history.schema_version == 1u);
  assert(history.event_count == 2u);
  assert(history.wxf_responsibility_supported == 0u);

  assert(xq_game_copy_fen(handle, &buffer) == XQ_STATUS_OK);
  assert(buffer.len > 0u && buffer.len <= XQ_FFI_MAX_OWNED_BUFFER_BYTES);
  assert(xq_ffi_buffer_release(&buffer) == XQ_STATUS_OK);
  assert(xq_game_copy_ucci_mainline(handle, &buffer) == XQ_STATUS_OK);
  assert(buffer.len > 0u);
  assert(xq_ffi_buffer_release(&buffer) == XQ_STATUS_OK);

  assert(xq_game_clone(handle, &clone) == XQ_STATUS_OK);
  assert(clone != handle && clone != XQ_GAME_HANDLE_INVALID);
  assert(xq_game_destroy(&clone) == XQ_STATUS_OK);
  assert(clone == XQ_GAME_HANDLE_INVALID);
  assert(xq_game_replace_from_fen(
             handle,
             mate_fen,
             (uint64_t)(sizeof(mate_fen) - 1u)) == XQ_STATUS_OK);
  assert(xq_game_get_snapshot(handle, &snapshot) == XQ_STATUS_OK);
  assert(snapshot.terminal_kind == 1u);
  assert(snapshot.terminal_winner == 0u);
  assert(xq_game_replace_from_fen(
             handle,
             standard_fen,
             (uint64_t)(sizeof(standard_fen) - 1u)) == XQ_STATUS_OK);
  assert(xq_game_get_snapshot(handle, &snapshot) == XQ_STATUS_OK);
  assert(snapshot.history_length == 1u);

  {
    const xq_move_v1_t first = {19u, 28u, 0u};
    const xq_move_v1_t alternate = {25u, 34u, 0u};
    const uint8_t annotation[] = "root note";
    assert(xq_game_apply_move(handle, first) == XQ_STATUS_OK);
    assert(xq_game_get_snapshot(handle, &snapshot) == XQ_STATUS_OK);
    assert(snapshot.current_node_id == 1u);
    assert(xq_game_undo(handle) == XQ_STATUS_OK);
    assert(xq_game_apply_move(handle, alternate) == XQ_STATUS_OK);
    assert(xq_game_get_snapshot(handle, &snapshot) == XQ_STATUS_OK);
    assert(snapshot.current_node_id == 2u);
    assert(xq_game_undo(handle) == XQ_STATUS_OK);
    assert(xq_game_get_variation_children(handle, 0u, &children) == XQ_STATUS_OK);
    assert(children.count == 2u);
    assert(children.reserved == 0u);
    assert(children.children[0].node_id == 1u);
    assert(children.children[0].from == first.from && children.children[0].to == first.to);
    assert(children.children[0].is_selected == 0u);
    assert(children.children[1].node_id == 2u);
    assert(children.children[1].is_selected == 1u);
    assert(xq_game_select_child(handle, 0u, 1u) == XQ_STATUS_OK);
    assert(xq_game_select_child(handle, 1u, 2u) == XQ_STATUS_INVALID_NODE);
    assert(xq_game_get_variation_children(handle, 0u, &children) == XQ_STATUS_OK);
    assert(children.children[0].is_selected == 1u);
    assert(children.children[1].is_selected == 0u);
    assert(xq_game_set_annotation(
               handle,
               0u,
               annotation,
               (uint64_t)(sizeof(annotation) - 1u)) == XQ_STATUS_OK);
    assert(xq_game_copy_annotation(handle, 0u, &buffer) == XQ_STATUS_OK);
    assert(buffer.len == sizeof(annotation) - 1u);
    assert(memcmp(buffer.data, annotation, buffer.len) == 0);
    assert(xq_ffi_buffer_release(&buffer) == XQ_STATUS_OK);
  }

  assert(xq_document_restore_create_from_fen_diagnostic(
             standard_fen,
             (uint64_t)(sizeof(standard_fen) - 1u),
             &restore,
             &fen_result) == XQ_STATUS_OK);
  assert(restore != XQ_DOCUMENT_RESTORE_HANDLE_INVALID);
  assert(fen_result.status == XQ_STATUS_OK && fen_result.field == XQ_FEN_FIELD_NONE);
  assert(xq_document_restore_append_node(
             restore,
             1u,
             0u,
             (xq_move_v1_t){19u, 28u, 0u}) == XQ_STATUS_OK);
  assert(xq_document_restore_set_annotation(
             restore,
             1u,
             (const uint8_t *)"restored",
             UINT64_C(8)) == XQ_STATUS_OK);
  assert(xq_document_restore_navigate(restore, 1u) == XQ_STATUS_OK);
  assert(xq_document_restore_finish(&restore, &restored_game) == XQ_STATUS_OK);
  assert(restore == XQ_DOCUMENT_RESTORE_HANDLE_INVALID);
  assert(restored_game != XQ_GAME_HANDLE_INVALID);
  assert(xq_game_get_snapshot(restored_game, &snapshot) == XQ_STATUS_OK);
  assert(snapshot.current_node_id == 1u && snapshot.history_length == 2u);
  assert(xq_game_copy_annotation(restored_game, 1u, &buffer) == XQ_STATUS_OK);
  assert(buffer.len == 8u && memcmp(buffer.data, "restored", buffer.len) == 0);
  assert(xq_ffi_buffer_release(&buffer) == XQ_STATUS_OK);
  assert(xq_document_restore_destroy(&restore) == XQ_STATUS_INVALID_HANDLE);
  assert(xq_game_destroy(&restored_game) == XQ_STATUS_OK);

  assert(xq_document_restore_create_from_fen_diagnostic(
             standard_fen,
             (uint64_t)(sizeof(standard_fen) - 1u),
             &restore,
             &fen_result) == XQ_STATUS_OK);
  stale_restore = restore;
  assert(xq_document_restore_append_node(
             restore,
             1u,
             0u,
             (xq_move_v1_t){19u, 28u, 1u}) == XQ_STATUS_INVALID_RESERVED);
  assert(xq_document_restore_navigate(restore, 0u) == XQ_STATUS_INVALID_ARGUMENT);
  assert(xq_document_restore_finish(&restore, &restored_game) == XQ_STATUS_INVALID_ARGUMENT);
  assert(restore == stale_restore);
  assert(restored_game == XQ_GAME_HANDLE_INVALID);
  assert(xq_document_restore_destroy(&restore) == XQ_STATUS_OK);
  assert(restore == XQ_DOCUMENT_RESTORE_HANDLE_INVALID);
  assert(xq_document_restore_navigate(stale_restore, 0u) == XQ_STATUS_INVALID_HANDLE);

  assert(xq_document_restore_create_from_fen_diagnostic(
             standard_fen,
             (uint64_t)(sizeof(standard_fen) - 1u),
             &restore,
             &fen_result) == XQ_STATUS_OK);
  assert(xq_document_restore_finish(
             &restore,
             (xq_game_handle_t *)&restore) == XQ_STATUS_INVALID_ARGUMENT);
  assert(restore != XQ_DOCUMENT_RESTORE_HANDLE_INVALID);
  assert(xq_document_restore_destroy(&restore) == XQ_STATUS_OK);

  assert(xq_game_destroy(&handle) == XQ_STATUS_OK);
  assert(handle == XQ_GAME_HANDLE_INVALID);
  assert(xq_game_destroy(&handle) == XQ_STATUS_INVALID_HANDLE);
  assert(xq_game_get_snapshot(handle, &snapshot) == XQ_STATUS_INVALID_HANDLE);

  return 0;
}
