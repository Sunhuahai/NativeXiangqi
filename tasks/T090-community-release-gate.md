# T090 — Community release gate

## Objective

Produce a signed, notarized, free Community release candidate with complete source/network compliance, rules labeling, resource evidence and reproducible artifacts.

## Dependencies

T080 complete.

## Read first

- `AGENTS.md`
- ADR 0005
- `docs/05-pikafish-engine.md`
- `docs/09-security-distribution-licenses.md`

## Allowed scope

Release manifests/configs, reports, notices, corresponding source, signing/notarization and fixes required to pass existing gates. No new product features.

## Required work

1. Freeze app, Rust, Pikafish, NNUE, toolchain, rule profile and manifest hashes.
2. Run rules/perft/FEN/UCCI/document/migration/fuzz/WXF-or-base-label suites.
3. Run UCI lifecycle/cancel/crash/illegal move/long stress.
4. Measure idle/active RSS, Hash presets, CPU/thermal and helper reclaim on M1 8GB plus one newer Mac.
5. Validate bestmove legality and score perspective corpus.
6. Rebuild distributed helper from exact corresponding source; compare documented identity/equivalence and hashes.
7. Include GPLv3, AUTHORS, modifications, source archive/offer, build instructions, NNUE license and notices prominently.
8. Confirm artifact is free/open-source Developer ID distribution outside Mac App Store.
9. Run negative tests for commercial/paid/MAS configurations.
10. Archive, nested-sign, notarize, staple and clean-account test.
11. Produce checksums, release notes, `build/reports/release-gate.json` and human report.
12. Do not publish unless repository policy explicitly authorizes publishing.

## Hard failures

- Missing/nonrebuildable corresponding source.
- NNUE use outside permission.
- Unsafe release mode enabled/bypassable.
- Illegal/unvalidated bestmove.
- Incorrect/overstated rule label.
- Data-loss defect.
- Zombie/unbounded RSS or memory hard gate.
- Archived app cannot launch helper.
- License/hash mismatch.

## Commands

```bash
make release-gate
make verify-assets
make verify-source
make verify-release-policy
make verify-signing
```

## Output

Notarized Community `.dmg`/`.zip`, checksums, exact source archive, notices, benchmark/rule/license reports and reproducible build instructions. All gates pass. Publishing remains outside scope unless authorized.

## Acceptance

All hard failures are absent, all mandated reports and artifacts exist, and the exact release eligibility is recorded.

## Required task report

State Community release eligibility and stop; no automatic next task.
