Treat a Pikafish or NNUE update as an isolated source, license and performance change.

Read `AGENTS.md`, ADR 0002/0005, `docs/05-pikafish-engine.md`, current manifests, corresponding source, licenses and release reports. Do not combine with UI/rules work.

Verify official repository/tag/commit, run the pinned source's `make help`, record target/compiler/flags, source archive hash, executable hash, NNUE source/hash/bytes/license, patches and exact corresponding-source rebuild. Run UCI fixtures, fixed FEN, legality validation, perspective tests, cancellation/crash stress, memory/thermal benchmarks and archived sandbox launch.

Commercial, paid and Mac App Store modes remain disabled. If source, license, protocol, resource or rebuild evidence regresses, retain the old version and report the blocker.
