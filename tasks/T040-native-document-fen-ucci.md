# T040 — Native document, FEN and UCCI workflow

## Objective

Replace temporary persistence with versioned `.xqgame`, robust migration, branching/annotations and strict FEN/UCCI interchange.

## Dependencies

T030 complete.

## Read first

- `AGENTS.md`
- `docs/06-documents-and-cache.md`
- `docs/08-testing-and-quality.md`

## Allowed scope

`xiangqi-io/core/ffi`, `XiangqiDocumentKit`, document UI, fixtures/fuzz/tests.

## Required work

1. Define `.xqgame` v1 with schema, document ID, initial FEN, explicit rule profile/version, variation tree, metadata, annotations and preserved extensions.
2. Implement bounded decode, validation, migration scaffold and immutable serialization snapshot.
3. Implement `NSDocument` open/save/save-as/autosave/version recovery.
4. Connect branch/comment editing and change count.
5. Implement FEN import/export with explicit current/initial semantics.
6. Implement transactional UCCI mainline import and path export.
7. Report exact failing ply/field; never leave half-imported state.
8. Preserve safe unknown extensions.
9. Add limits for bytes/depth/nodes/text.
10. Remove temporary T030 format.
11. Add old-version fixtures, malformed corpus and fuzz smoke.
12. Ensure engine/UI state does not dirty document.

## Tests and commands

```bash
make rust-test
make swift-test
make integration-test
make fuzz-smoke
make test
```

## Acceptance

User can play/branch/comment/save/reopen; FEN/UCCI are strict and transactional; migrations cannot overwrite source on failure; unknown extensions survive; base rule profile remains explicit.

## Non-goals

No XQF writer, Pikafish or final WXF classifier.

## Required task report

Next task T050; stop.
