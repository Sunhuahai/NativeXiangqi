#include <assert.h>
#include <stddef.h>
#include <stdint.h>

#include "xiangqi_ffi.h"

int main(void) {
  xq_ffi_abi_info_t info = {0};
  uint64_t capabilities = 0;
  xq_owned_buffer_t buffer = XQ_OWNED_BUFFER_INIT;

  assert(xq_ffi_get_abi_info(NULL) == XQ_STATUS_INVALID_ARGUMENT);
  assert(xq_ffi_get_capabilities(NULL) == XQ_STATUS_INVALID_ARGUMENT);
  assert(xq_ffi_get_build_info(NULL) == XQ_STATUS_INVALID_ARGUMENT);
  assert(xq_ffi_buffer_release(NULL) == XQ_STATUS_INVALID_ARGUMENT);

  assert(xq_ffi_get_abi_info(&info) == XQ_STATUS_OK);
  assert(info.abi_major == XQ_FFI_ABI_MAJOR);
  assert(info.abi_minor >= XQ_FFI_ABI_MINOR);
  assert(info.build_info_format == XQ_FFI_BUILD_INFO_FORMAT);
  assert((info.capabilities & XQ_CAPABILITY_ABI_INFO) != 0);
  assert((info.capabilities & XQ_CAPABILITY_BUILD_INFO) != 0);
  assert((info.capabilities & XQ_CAPABILITY_OWNED_BUFFERS) != 0);
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
  assert(buffer.len == 0u);
  assert(buffer.capacity == 0u);
  assert(xq_ffi_buffer_release(&buffer) == XQ_STATUS_INVALID_OWNED_BUFFER);

  return 0;
}
