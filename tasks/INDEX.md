# Task execution order

Execute exactly one card at a time. A task is complete only after its report exists and all acceptance commands pass.

| Order | Task | Purpose |
|---:|---|---|
| 0 | `T000-repository-license-and-engine-baseline.md` | Independent repo, source/license policy, fail-closed release |
| 1 | `T010-rust-artifact-and-ffi-smoke.md` | Deterministic Rust artifact and ABI |
| 2 | `T020-xiangqi-rules-perft-and-ffi.md` | Base legality, perft, history, FEN/UCCI |
| 3 | `T030-native-document-window-and-board.md` | Native AppKit board and local play |
| 4 | `T040-native-document-fen-ucci.md` | Versioned document and interchange |
| 5 | `T050-pikafish-helper-uci-and-source.md` | Signed UCI helper and corresponding source |
| 6 | `T060-analysis-ai-and-cache.md` | Analysis, AI, cache and resource presets |
| 7 | `T070-wxf-repetition-adjudication.md` | Explainable WXF repetition/long-check/chase |
| 8 | `T080-hardening-accessibility-localization.md` | Concurrency, recovery, accessibility and performance |
| 9 | `T090-community-release-gate.md` | Free notarized Community artifact and compliance |

Do not start T010 during T000. Do not remove the “基础规则模式” label before T070 passes for the selected profile. Commercial, paid and Mac App Store modes remain disabled unless a later accepted legal/license ADR changes the repository policy.
