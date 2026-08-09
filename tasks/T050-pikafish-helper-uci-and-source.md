# T050 — Pikafish helper, UCI session and corresponding source

## Objective

Build and bundle the pinned Apple Silicon Pikafish helper/NNUE, implement a robust typed UCI session, prove archived sandbox execution, and produce exact corresponding source. Do not build final analysis UX yet.

## Dependencies

T040 complete; T000 manifests/licensing resolved sufficiently for Community development.

## Read first

- `AGENTS.md`
- `docs/05-pikafish-engine.md`
- `docs/09-security-distribution-licenses.md`
- ADR 0002 and 0005

## Allowed scope

`Engines/Pikafish`, vendor/build/source scripts, `PikafishKit`, app embedding/signing/status, engine fakes and focused tests.

## Required work

1. Fetch only via explicit vendor command and verify source/NNUE/license hashes.
2. Run pinned source `make help`; select/record actual arm64 target and compiler.
3. Build helper and run version/UCI/isready/fixed-FEN smoke.
4. Archive exact source, patches, build files/instructions and checksums.
5. Embed helper/NNUE/licenses and sign nested helper.
6. Implement `PikafishSession` actor:
   - launch;
   - UCI handshake and dynamic options;
   - whitelist setoption;
   - isready/ucinewgame/position/go/stop/quit;
   - bounded stdout/stderr;
   - typed info/bestmove;
   - generation/deadline/cancel/terminal;
   - crash/restart;
   - graceful/forced shutdown.
7. Validate PV/moves/numbers and ignore unknown tokens.
8. Add fake scenarios: option variants, slow handshake, flood, malformed, no bestmove, ignore stop, crash, illegal bestmove.
9. Add real `make engine-smoke`.
10. Prove archived sandbox helper.
11. Implement `make verify-source` that rebuilds or reproducibly verifies corresponding source against distributed helper according to documented method.
12. Keep all unsafe release modes disabled and run negative tests.

## Tests and commands

```bash
make vendor-verify
make integration-test
make engine-smoke
make verify-assets
make verify-source
make verify-release-policy
make verify-signing
```

## Acceptance

Archived app receives typed bestmove; all fakes bounded; missing/corrupt NNUE disables analysis only; exact source/license/network materials complete; unsafe release requests fail.

## Non-goals

No final analysis table, AI play, cache, WXF full profile or release.

## Required task report

Next task T060; stop.
