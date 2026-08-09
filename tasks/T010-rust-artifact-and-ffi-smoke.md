# T010 — Rust artifact and FFI smoke

## Objective

Build a deterministic arm64 Rust static artifact and link a minimal versioned ABI smoke call into NativeXiangqi.

## Dependencies

T000 complete.

## Read first

- `AGENTS.md`
- `docs/04-rust-core-and-ffi.md`
- ADR 0003
- `docs/13-build-command-contract.md`

## Allowed scope

Rust workspace, `XiangqiCoreBinary`, scripts/build settings, Makefile, CI and focused tests.

## Required work

1. Configure release profile: reviewed LTO, one codegen unit, panic abort, stripping, deterministic features.
2. Expose from `xiangqi-ffi`: ABI major/minor, capabilities, build info, typed status/error, owned buffer release.
3. Generate C header into the local binary package.
4. Build `aarch64-apple-darwin` static library/XCFramework.
5. Add Swift wrapper and Debug ABI compatibility check.
6. Add offline Debug/Release artifact scripts.
7. Add generate/build/test root commands.
8. CI requires regenerated header/metadata clean diff.
9. Record artifact size/exports/toolchain.
10. Test invalid C inputs and ownership pairs.

## Invariants

`unsafe` only in `xiangqi-ffi`; no panic unwind, references, callbacks or async crossing; every allocation paired.

## Tests and commands

```bash
make generate-ffi
make rust-build
make rust-test
make swift-test
make test
```

Include 100k allocation/release and sanitizer configuration where supported.

## Acceptance

App links and validates ABI; clean checkout rebuilds; generated header stable; all boundary tests pass.

## Non-goals

No board, rules, document or Pikafish.

## Required task report

Next task T020; stop.
