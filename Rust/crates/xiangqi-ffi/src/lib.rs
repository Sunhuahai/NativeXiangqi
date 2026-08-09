//! Narrow, versioned C ABI for the Rust Xiangqi core.
//!
//! T010 intentionally exposes only artifact compatibility and owned-buffer smoke calls.
//! Game state, rules, and codecs remain out of this crate until their assigned task cards.

#![deny(unsafe_op_in_unsafe_fn)]

use std::{
    collections::BTreeMap,
    mem,
    panic::{self, AssertUnwindSafe},
    ptr,
    sync::{
        LazyLock, Mutex, MutexGuard,
        atomic::{AtomicU64, Ordering},
    },
};

mod generated_abi;

use generated_abi::{
    ABI_MAJOR, ABI_MINOR, ABI_SOURCE_SHA256, BUILD_INFO, BUILD_INFO_FORMAT, CAPABILITY_ABI_INFO,
    CAPABILITY_BUILD_INFO, CAPABILITY_OWNED_BUFFERS, DETERMINISTIC_FEATURES, MAX_BUILD_INFO_BYTES,
    MAX_LIVE_BUFFERS, OWNERSHIP_TOKEN_BITS, STATUS_ABI_MAJOR_MISMATCH, STATUS_ABI_MINOR_MISMATCH,
    STATUS_ALLOCATION_FAILED, STATUS_INTERNAL_ERROR, STATUS_INVALID_ARGUMENT,
    STATUS_INVALID_OWNED_BUFFER, STATUS_OK, STATUS_OUTPUT_NOT_EMPTY, STATUS_RESOURCE_LIMIT,
};

/// C-compatible typed status code. Constants are generated from `abi/ffi-api.toml`.
pub type XqStatus = u32;

/// Caller-provided version and capability information.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct XqAbiInfo {
    pub abi_major: u32,
    pub abi_minor: u32,
    pub capabilities: u64,
    pub build_info_format: u32,
    pub reserved: u32,
}

/// A Rust-owned allocation returned to C or Swift and released through `xq_ffi_buffer_release`.
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

#[derive(Clone, Copy)]
struct AllocationRecord {
    len: usize,
    capacity: usize,
    allocation_token: u64,
}

#[derive(Default)]
struct AllocationRegistry {
    allocations: BTreeMap<usize, AllocationRecord>,
}

static OWNED_BUFFERS: LazyLock<Mutex<AllocationRegistry>> =
    LazyLock::new(|| Mutex::new(AllocationRegistry::default()));
static NEXT_ALLOCATION_TOKEN: AtomicU64 = AtomicU64::new(1);

const CAPABILITIES: u64 = CAPABILITY_ABI_INFO | CAPABILITY_BUILD_INFO | CAPABILITY_OWNED_BUFFERS;

fn registry() -> MutexGuard<'static, AllocationRegistry> {
    match OWNED_BUFFERS.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn next_allocation_token() -> Option<u64> {
    NEXT_ALLOCATION_TOKEN
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

fn abi_info() -> XqAbiInfo {
    XqAbiInfo {
        abi_major: ABI_MAJOR,
        abi_minor: ABI_MINOR,
        capabilities: CAPABILITIES,
        build_info_format: BUILD_INFO_FORMAT,
        reserved: 0,
    }
}

fn get_abi_info(out_info: *mut XqAbiInfo) -> XqStatus {
    if out_info.is_null() {
        return STATUS_INVALID_ARGUMENT;
    }

    // SAFETY: non-null validity and writable storage are part of this C ABI's caller contract.
    unsafe { out_info.write(abi_info()) };
    STATUS_OK
}

fn get_capabilities(out_capabilities: *mut u64) -> XqStatus {
    if out_capabilities.is_null() {
        return STATUS_INVALID_ARGUMENT;
    }

    // SAFETY: non-null validity and writable storage are part of this C ABI's caller contract.
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
    if out_buffer.is_null() {
        return STATUS_INVALID_ARGUMENT;
    }

    // SAFETY: non-null validity and initialized storage are part of this C ABI's caller contract.
    let current = unsafe { out_buffer.read() };
    if !current.is_empty() {
        return STATUS_OUTPUT_NOT_EMPTY;
    }

    let bytes = BUILD_INFO.as_bytes();
    if bytes.len() > MAX_BUILD_INFO_BYTES
        || !BUILD_INFO.contains(ABI_SOURCE_SHA256)
        || !BUILD_INFO.contains(DETERMINISTIC_FEATURES)
    {
        return STATUS_INTERNAL_ERROR;
    }

    let mut registry = registry();
    if registry.allocations.len() >= MAX_LIVE_BUFFERS {
        return STATUS_RESOURCE_LIMIT;
    }
    if OWNERSHIP_TOKEN_BITS != u64::BITS {
        return STATUS_INTERNAL_ERROR;
    }
    let Some(allocation_token) = next_allocation_token() else {
        return STATUS_RESOURCE_LIMIT;
    };

    let mut owned = Vec::new();
    if owned.try_reserve_exact(bytes.len()).is_err() {
        return STATUS_ALLOCATION_FAILED;
    }
    owned.extend_from_slice(bytes);

    let record = AllocationRecord {
        len: owned.len(),
        capacity: owned.capacity(),
        allocation_token,
    };
    let data = owned.as_mut_ptr();
    if registry.allocations.contains_key(&data.addr()) {
        return STATUS_INTERNAL_ERROR;
    }
    registry.allocations.insert(data.addr(), record);
    mem::forget(owned);

    // SAFETY: non-null validity and writable storage are part of this C ABI's caller contract.
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
    if buffer.is_null() {
        return STATUS_INVALID_ARGUMENT;
    }

    // SAFETY: non-null validity and initialized storage are part of this C ABI's caller contract.
    let supplied = unsafe { buffer.read() };
    if supplied.data.is_null() || supplied.len > supplied.capacity {
        return STATUS_INVALID_OWNED_BUFFER;
    }

    let mut registry = registry();
    let Some(record) = registry.allocations.get(&supplied.data.addr()).copied() else {
        return STATUS_INVALID_OWNED_BUFFER;
    };
    if supplied.len != record.len
        || supplied.capacity != record.capacity
        || supplied.allocation_token != record.allocation_token
    {
        return STATUS_INVALID_OWNED_BUFFER;
    }
    registry.allocations.remove(&supplied.data.addr());
    drop(registry);

    // SAFETY: only this registry inserts pointers made by Vec::into_raw_parts-equivalent
    // ownership transfer, and the exact length/capacity match was verified above.
    unsafe {
        drop(Vec::from_raw_parts(
            supplied.data,
            record.len,
            record.capacity,
        ))
    };
    // SAFETY: non-null validity and writable storage are part of this C ABI's caller contract.
    unsafe { buffer.write(XqOwnedBuffer::EMPTY) };
    STATUS_OK
}

/// Writes the ABI version and supported capability bitmap to a caller-provided POD structure.
///
/// # Safety
/// `out_info` must be non-null, aligned, and point to writable initialized `XqAbiInfo` storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_ffi_get_abi_info(out_info: *mut XqAbiInfo) -> XqStatus {
    boundary(|| get_abi_info(out_info))
}

/// Writes the supported capability bitmap to a caller-provided `uint64_t`.
///
/// # Safety
/// `out_capabilities` must be non-null, aligned, and point to writable `u64` storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_ffi_get_capabilities(out_capabilities: *mut u64) -> XqStatus {
    boundary(|| get_capabilities(out_capabilities))
}

/// Checks a caller's required ABI version without allocating or mutating shared state.
#[unsafe(no_mangle)]
pub extern "C" fn xq_ffi_validate_abi(expected_major: u32, minimum_minor: u32) -> XqStatus {
    boundary(|| validate_abi(expected_major, minimum_minor))
}

/// Allocates a bounded UTF-8 build-info payload. The output must be initialized to EMPTY.
///
/// # Safety
/// `out_buffer` must be non-null, aligned, and point to writable initialized `XqOwnedBuffer`
/// storage. On success, it must be released exactly once using `xq_ffi_buffer_release`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_ffi_get_build_info(out_buffer: *mut XqOwnedBuffer) -> XqStatus {
    boundary(|| get_build_info(out_buffer))
}

/// Releases exactly one buffer allocated by `xq_ffi_get_build_info` and clears its POD fields.
///
/// # Safety
/// `buffer` must be non-null, aligned, and point to writable initialized `XqOwnedBuffer` storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xq_ffi_buffer_release(buffer: *mut XqOwnedBuffer) -> XqStatus {
    boundary(|| buffer_release(buffer))
}

#[cfg(test)]
mod tests {
    use std::{ptr, slice};

    use super::*;

    #[test]
    fn abi_info_and_capabilities_are_stable() {
        let mut info = XqAbiInfo {
            abi_major: 0,
            abi_minor: 0,
            capabilities: 0,
            build_info_format: 0,
            reserved: u32::MAX,
        };
        let mut capabilities = 0_u64;

        // SAFETY: both output variables are valid writable storage.
        assert_eq!(unsafe { xq_ffi_get_abi_info(&mut info) }, STATUS_OK);
        // SAFETY: the output variable is valid writable storage.
        assert_eq!(
            unsafe { xq_ffi_get_capabilities(&mut capabilities) },
            STATUS_OK
        );

        assert_eq!(info, abi_info());
        assert_eq!(capabilities, CAPABILITIES);
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
    fn null_outputs_are_rejected() {
        // SAFETY: null values are the explicit invalid-input test cases.
        assert_eq!(
            unsafe { xq_ffi_get_abi_info(ptr::null_mut()) },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: null values are the explicit invalid-input test cases.
        assert_eq!(
            unsafe { xq_ffi_get_capabilities(ptr::null_mut()) },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: null values are the explicit invalid-input test cases.
        assert_eq!(
            unsafe { xq_ffi_get_build_info(ptr::null_mut()) },
            STATUS_INVALID_ARGUMENT
        );
        // SAFETY: null values are the explicit invalid-input test cases.
        assert_eq!(
            unsafe { xq_ffi_buffer_release(ptr::null_mut()) },
            STATUS_INVALID_ARGUMENT
        );
    }

    #[test]
    fn malformed_and_double_releases_are_rejected_without_freeing_foreign_memory() {
        let mut forged = XqOwnedBuffer {
            data: ptr::dangling_mut(),
            len: 1,
            capacity: 1,
            allocation_token: 0,
        };
        // SAFETY: forged points at writable POD storage and intentionally has no registered data.
        assert_eq!(
            unsafe { xq_ffi_buffer_release(&mut forged) },
            STATUS_INVALID_OWNED_BUFFER
        );

        let mut malformed = XqOwnedBuffer {
            data: ptr::null_mut(),
            len: 1,
            capacity: 0,
            allocation_token: 0,
        };
        // SAFETY: malformed points at writable POD storage.
        assert_eq!(
            unsafe { xq_ffi_buffer_release(&mut malformed) },
            STATUS_INVALID_OWNED_BUFFER
        );

        let mut output = XqOwnedBuffer::EMPTY;
        // SAFETY: output points at writable initialized POD storage.
        assert_eq!(unsafe { xq_ffi_get_build_info(&mut output) }, STATUS_OK);
        let mut mismatched = XqOwnedBuffer {
            data: output.data,
            len: output.len.saturating_sub(1),
            capacity: output.capacity,
            allocation_token: output.allocation_token,
        };
        // SAFETY: mismatched points at writable POD storage; registry rejects its altered metadata.
        assert_eq!(
            unsafe { xq_ffi_buffer_release(&mut mismatched) },
            STATUS_INVALID_OWNED_BUFFER
        );
        // SAFETY: output still retains the exact registered allocation metadata.
        assert_eq!(unsafe { xq_ffi_buffer_release(&mut output) }, STATUS_OK);
        // SAFETY: output is now the initialized empty sentinel and double release is rejected.
        assert_eq!(
            unsafe { xq_ffi_buffer_release(&mut output) },
            STATUS_INVALID_OWNED_BUFFER
        );
    }

    #[test]
    fn output_must_be_empty_and_build_info_is_bounded_utf8() {
        let mut nonempty = XqOwnedBuffer {
            data: ptr::dangling_mut(),
            len: 1,
            capacity: 1,
            allocation_token: 0,
        };
        // SAFETY: nonempty points at writable initialized POD storage.
        assert_eq!(
            unsafe { xq_ffi_get_build_info(&mut nonempty) },
            STATUS_OUTPUT_NOT_EMPTY
        );

        let mut output = XqOwnedBuffer::EMPTY;
        // SAFETY: output points at writable initialized POD storage.
        assert_eq!(unsafe { xq_ffi_get_build_info(&mut output) }, STATUS_OK);
        assert!(output.len <= MAX_BUILD_INFO_BYTES);
        // SAFETY: the API returned this registered pointer and exact length.
        let text = unsafe { slice::from_raw_parts(output.data, output.len) };
        assert_eq!(text, BUILD_INFO.as_bytes());
        assert!(std::str::from_utf8(text).is_ok());
        // SAFETY: output retains the exact registered allocation metadata.
        assert_eq!(unsafe { xq_ffi_buffer_release(&mut output) }, STATUS_OK);
        assert_eq!(output, XqOwnedBuffer::EMPTY);
    }

    #[test]
    fn one_hundred_thousand_owned_buffer_lifecycles_leave_no_live_allocation() {
        for _ in 0..100_000 {
            let mut output = XqOwnedBuffer::EMPTY;
            // SAFETY: output points at writable initialized POD storage.
            assert_eq!(unsafe { xq_ffi_get_build_info(&mut output) }, STATUS_OK);
            assert!(output.len <= MAX_BUILD_INFO_BYTES);
            // SAFETY: output retains the exact registered allocation metadata.
            assert_eq!(unsafe { xq_ffi_buffer_release(&mut output) }, STATUS_OK);
            assert_eq!(output, XqOwnedBuffer::EMPTY);
        }
        assert!(registry().allocations.is_empty());
    }

    #[test]
    fn live_buffer_limit_rejects_an_extra_allocation_and_recovers_after_release() {
        let mut buffers = Vec::with_capacity(MAX_LIVE_BUFFERS);
        for _ in 0..MAX_LIVE_BUFFERS {
            let mut output = XqOwnedBuffer::EMPTY;
            // SAFETY: output points at writable initialized POD storage.
            assert_eq!(unsafe { xq_ffi_get_build_info(&mut output) }, STATUS_OK);
            buffers.push(output);
        }

        let mut overflow = XqOwnedBuffer::EMPTY;
        // SAFETY: overflow points at writable initialized POD storage.
        assert_eq!(
            unsafe { xq_ffi_get_build_info(&mut overflow) },
            STATUS_RESOURCE_LIMIT
        );
        assert_eq!(overflow, XqOwnedBuffer::EMPTY);

        for buffer in &mut buffers {
            // SAFETY: each buffer retains its exact registered allocation metadata.
            assert_eq!(unsafe { xq_ffi_buffer_release(buffer) }, STATUS_OK);
        }
        assert!(registry().allocations.is_empty());

        let mut recovered = XqOwnedBuffer::EMPTY;
        // SAFETY: recovered points at writable initialized POD storage after cleanup.
        assert_eq!(unsafe { xq_ffi_get_build_info(&mut recovered) }, STATUS_OK);
        // SAFETY: recovered retains its exact registered allocation metadata.
        assert_eq!(unsafe { xq_ffi_buffer_release(&mut recovered) }, STATUS_OK);
    }

    #[test]
    fn stale_buffer_copy_cannot_release_a_simulated_reused_address() {
        struct RegistryCleanup(usize);

        impl Drop for RegistryCleanup {
            fn drop(&mut self) {
                registry().allocations.remove(&self.0);
            }
        }

        let reused_data = ptr::dangling_mut::<u8>();
        let stale_token = 41_u64;
        let current_token = 42_u64;
        let mut stale_copy = XqOwnedBuffer {
            data: reused_data,
            len: 3,
            capacity: 3,
            allocation_token: stale_token,
        };
        {
            let mut entries = registry();
            assert!(
                entries
                    .allocations
                    .insert(
                        reused_data.addr(),
                        AllocationRecord {
                            len: 3,
                            capacity: 3,
                            allocation_token: current_token,
                        },
                    )
                    .is_none()
            );
        }
        let _cleanup = RegistryCleanup(reused_data.addr());

        // SAFETY: stale_copy itself is valid POD storage; the synthetic registry record simulates
        // an allocator reusing this address for a newer allocation with a different token.
        assert_eq!(
            unsafe { xq_ffi_buffer_release(&mut stale_copy) },
            STATUS_INVALID_OWNED_BUFFER
        );
        assert_eq!(stale_copy.allocation_token, stale_token);
        let registered_token = registry()
            .allocations
            .get(&reused_data.addr())
            .map(|record| record.allocation_token);
        assert_eq!(registered_token, Some(current_token));
    }
}
