# T060 — Analysis UI, human-versus-AI and bounded cache

## Objective

Deliver candidate/PV/score analysis, human-versus-AI play, conservative resource presets, persistent cache and memory-pressure behavior.

## Dependencies

T050 complete.

## Read first

- `AGENTS.md`
- `docs/01-product-requirements.md`
- `docs/06-documents-and-cache.md`
- `docs/07-performance-and-memory.md`

## Allowed scope

UI/controllers, `PikafishKit`, cache, settings, tests/benchmarks.

## Required work

1. Candidate table/board overlays with score/mate/depth/nodes/NPS/PV.
2. Typed and tested perspective conversion; UI states selected perspective.
3. Throttle partial info to 5 Hz default/10 Hz max.
4. Light/standard/deep presets from dynamically advertised whitelist.
5. Default conservative Hash/threads and Ponder off.
6. Human-vs-AI with fixed/time-aware budget; Rust revalidates bestmove and active profile.
7. One SQLite cache actor with schema, full identity, byte/entry caps and LRU.
8. Persist final validated results only.
9. Implement idle/visibility/low-power/memory pressure policy and helper reclaim.
10. Add stale-generation/crash/restart UX.
11. No arbitrary UCI command injection.
12. Measure Hash presets, repeated cancel/final, 500 switches/lifecycle equivalent and 30-minute RSS/thermal.

## Tests and commands

```bash
make swift-test
make integration-test
make engine-smoke
make benchmark
make verify-release-policy
make test
```

## Acceptance

Stable local analysis and AI play; no illegal move; perspective correct; stale output discarded; cache correct/bounded; helper reclaims; standard resource hard gate passes or work stops for evidence-based ADR. “基础规则模式” remains until T070.

## Non-goals

No WXF classifier, commercial/MAS, online play or arbitrary engine settings.

## Required task report

Next task T070; stop.
