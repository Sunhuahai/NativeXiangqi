# T080 — Hardening, accessibility and localization

## Objective

Harden the complete Community application before release without adding scope.

## Dependencies

T070 complete for full WXF label; T060 is sufficient if release intentionally remains base-rule mode and labels it accurately.

## Read first

- `AGENTS.md`
- `docs/07-performance-and-memory.md`
- `docs/08-testing-and-quality.md`
- `docs/09-security-distribution-licenses.md`

## Allowed scope

Whole repository for focused hardening, diagnostics, localization, recovery and documentation only.

## Required work

1. Eliminate Swift 6 warnings/unjustified `@unchecked Sendable`.
2. Audit FFI ownership/nullability/conversions/capabilities.
3. Run leak/allocations/time/hangs/file activity.
4. Complete keyboard, VoiceOver, high contrast, Reduce Motion.
5. Add Simplified Chinese and English infrastructure; human-review Xiangqi/WXF terms.
6. Drill autosave, corrupt document/migration/cache, missing helper/NNUE, crash and forced stop.
7. Audit errors/diagnostics privacy and actionability.
8. Audit bundle size/resources/architectures.
9. Add machine-readable regression dashboard.
10. Review source archive/notices/manifests/release policy against shipped state.
11. Re-run unsafe-release negative tests.
12. Resolve all data-loss defects.

## Tests and commands

```bash
make format
make lint
make test
make benchmark
make verify-assets
make verify-source
make verify-release-policy
make verify-signing
```

## Acceptance

No known data loss; core workflows accessible; recovery drills pass; source/license policy intact; resource regression stable; rule label exact; no unsafe mode enabled.

## Non-goals

No redesign, new engine/network, XQF, online or commercial work.

## Required task report

Next task T090; stop.
