# T070 — WXF repetition, long check and long chase adjudication

## Objective

Implement a separate, explainable, versioned adjudication module from a selected World Xiangqi Rules snapshot. Upgrade only the verified profile from “基础规则模式”.

## Dependencies

T060 complete.

## Read first

- `AGENTS.md`
- `docs/01-product-requirements.md`
- `docs/04-rust-core-and-ffi.md`
- `docs/08-testing-and-quality.md`

## Allowed scope

Rules research documentation, `xiangqi-core/ffi`, approved corpus, explanation UI/export and focused tests.

## Required work

1. Record exact WXF edition/snapshot, provenance and terminology mapping.
2. Define per-ply event labels: check, chase targets, protection, exchange, idle, escape, alternatives and cycle boundaries.
3. Keep cycle detection separate from responsibility classification.
4. Produce structured result:
   - no action;
   - draw;
   - red/black violation;
   - required change side;
   - unsupported/ambiguous;
   - explanation with ply ranges/evidence/profile.
5. Build manually reviewed corpus covering long/mutual check, long chase, protected/unprotected, alternating targets, exchanges, idle, escapes and ambiguous cases.
6. Validate undo/branch/history and profile compatibility.
7. Expose summary/detail through batched FFI.
8. Add native explanation panel and exportable note.
9. Never use Pikafish evaluation to classify.
10. Keep old/other profiles labeled accurately; no silent reinterpretation.
11. Remove base-mode badge only for the passing profile.

## Quality bar

This is rules research plus implementation, not heuristic patching. Expected corpus labels require independent human review. Unsupported cases remain unsupported.

## Tests and commands

```bash
make rust-test
make swift-test
make integration-test
make benchmark-rules
make test
```

## Acceptance

All approved fixtures pass; explanations are deterministic and reviewable; undo/branch restores events; profile version persists; badge changes only for verified profile.

## Non-goals

No new engine, release or broad notation project.

## Required task report

Next task T080; stop.
