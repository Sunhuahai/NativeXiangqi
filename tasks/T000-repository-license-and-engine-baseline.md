# T000 — Repository, license and engine baseline

## Objective

Create the independent NativeXiangqi repository skeleton, one minimal macOS app target, pinned toolchain, traceable Pikafish/NNUE source state, and fail-closed Community release policy. Do not implement rules, board UI or engine integration.

## Dependencies

None.

## Read first

- `AGENTS.md`
- `README.md`
- `docs/00-executive-decisions.md`
- `docs/09-security-distribution-licenses.md`
- ADR 0001–0005

## Allowed scope

Repository root, Xcode scaffolding, empty local packages, Cargo scaffolding, scripts, `Engines/Pikafish/`, CI, docs/config and release-policy tests.

## Required work

1. Initialize the tree in `README.md`.
2. Create `NativeXiangqi.xcworkspace` and one app target:
   - arm64 only;
   - macOS 15 deployment;
   - Swift 6 strict concurrency;
   - App Sandbox and Hardened Runtime;
   - no network entitlement.
3. Create empty `XiangqiUI`, `XiangqiDocumentKit`, `PikafishKit`, `XiangqiCoreBinary` packages.
4. Create empty `xiangqi-core`, `xiangqi-io`, `xiangqi-ffi` Cargo crates.
5. Copy pinned Rust toolchain; commit Cargo.lock when applicable.
6. Implement `make bootstrap` that checks, never installs, Xcode/Swift/Rust/Make/Python and reports versions.
7. From official sources, select a Pikafish release/tag or exact commit verified as an Apple Silicon build candidate. Run/record its `make help`; do not use an unpinned branch.
8. Record code license, NNUE source/license/permission separately. Development manifests may be unresolved; release manifests may not.
9. Create manifest schema for source archive, build target/toolchain/flags, patch hashes, helper hash, NNUE hash/bytes/license and corresponding-source archive.
10. Create `Engines/Pikafish/corresponding-source`, licenses/notices and source rebuild layout.
11. Implement release policy:
    - Community Developer ID may be prepared;
    - commercial/paid/IAP/subscription/donation-gated bundle false;
    - Mac App Store false;
    - normal scripts cannot override.
12. Add negative tests that unsafe release requests fail clearly.
13. Add no-network-build checks, secrets policy, formatting, `.gitignore`, `.gitattributes`.
14. Build only a static shell window.
15. Report exact selected source/version, current NNUE permission evidence and unresolved legal questions.

## Tests and commands

```bash
make bootstrap
xcodebuild -list -workspace NativeXiangqi.xcworkspace
cargo metadata --locked --format-version 1
scripts/validate-manifests.sh
make verify-release-policy
scripts/check-no-build-downloads.sh
make build
```

Negative tests must attempt commercial and Mac App Store release modes and fail.

## Acceptance

One minimal app scheme builds; toolchain is pinned; engine/source/network state is traceable; release policy fails closed; no cross-platform dependency or unrelated-game target; no build phase downloads assets.

## Non-goals

No rules, board, FEN/UCCI behavior, helper build, NNUE bundling, credentials or notarization.

## Required task report

Next task T010; stop.
