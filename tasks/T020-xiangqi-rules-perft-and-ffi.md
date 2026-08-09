# T020 — Xiangqi rules, perft, history and production FFI

## Objective

Implement the canonical Rust Xiangqi model with complete base legality, check/mate/stalemate, compact variations, apply/undo, hashes, repetition event history scaffolding, FEN/UCCI and batched FFI. Do not implement final WXF responsibility classification yet.

## Dependencies

T010 complete.

## Read first

- `AGENTS.md`
- `docs/04-rust-core-and-ffi.md`
- `docs/08-testing-and-quality.md`

## Allowed scope

`xiangqi-core`, `xiangqi-io`, `xiangqi-ffi`, wrappers, fixtures, perft/property/fuzz tests.

## Required work

1. Implement fixed 90-square board, piece/side/square/move types and standard initial FEN.
2. Implement palace, river, advisor, elephant eye, horse leg, rook, cannon, pawn and flying-general rules.
3. Generate legal moves excluding self-check.
4. Detect check, checkmate and stalemate/困毙 under the baseline profile.
5. Implement compact arena variation tree, stable IDs and exact undo/redo.
6. Implement fixed/versioned hashes and incremental/recompute checks.
7. Track bounded position history and per-ply event data sufficient for later WXF work, without claiming adjudication.
8. Implement strict FEN parse/write.
9. Implement UCCI coordinate parse/write and transactional mainline application primitive.
10. Add hard limits for nodes, annotations, history and input.
11. Expose handle lifecycle, selectable pieces, legal destinations, apply/navigation, board snapshot, terminal state, FEN/UCCI and history capability through FFI.
12. Add fixed perft corpus, randomized apply/undo and 100k FFI lifecycle.

## Invariants

- Failed move does not mutate.
- apply + undo restores board/history/events/hash.
- Engine-independent legality rejects self-check/flying general.
- Base mode never pretends to decide long-check/chase responsibility.
- No per-square FFI needed.

## Tests and commands

```bash
make generate-ffi
make rust-test
make swift-test
make benchmark-rules
make test
```

## Acceptance

All piece fixtures/perft pass; FEN/UCCI round trip; UI-capable batch snapshot/legal APIs exist; history is adequate and versioned for T070; no false WXF completion claim.

## Non-goals

No AppKit, native document, Pikafish or final WXF classifier.

## Required task report

Next task T030; stop.
