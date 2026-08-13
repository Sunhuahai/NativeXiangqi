# 13. 构建与命令契约

## 1. 工具链

- Xcode 27.x；Swift 6。T000 的迁移验证基线为 Xcode 27.0 Beta build 27A5228h；
  后续 stable/build 更新必须重新运行任务验收并记录精确 build。
- macOS 15 deployment。
- arm64 only。
- Rust pinned `rust-toolchain.toml`。
- Pikafish build toolchain/target 由 pinned source `make help` 决定并记录。
- Make 是根入口；复杂逻辑在 scripts。

T000 重新核验版本。

## 2. Commands

```bash
make bootstrap
make vendor-verify
make generate-ffi
make rust-build
make format
make lint
make rust-test
make swift-test
make benchmark-rules
make integration-test
make fuzz-smoke
make engine-smoke
make build
make benchmark
make verify-assets
make verify-source
make verify-release-policy
make verify-signing
make release-gate
make test
```

非交互、root 执行、失败非零。普通 build/archive offline。

T030 command ownership:

- `make swift-test` stages the local Debug Rust XCFramework and runs the Core ABI,
  pure board geometry/accessibility, and AppKit document-package suites. It uses
  only repository-local Swift packages.
- `make integration-test` runs the real AppKit `NSDocument`/three-pane assembly
  suite, including Rust-backed local play, branching, undo/redo, terminal states,
  board flip, and bounded document failure paths. It does not launch an engine or
  access a network.
- `make benchmark-ui` displays the actual local three-pane `NSDocument`, waits for
  its Rust-backed session to become ready under a bounded monotonic deadline, then
  emits one machine-readable JSON record containing no-engine idle RSS plus p50/p95
  offscreen-board draw and synthetic pointer-event-to-board-delegate latency. It
  reads `budgetsMiB.emptyWindowHard` from `config/memory-budgets.json` and fails
  above that hard gate.

T040 command ownership:

- `make swift-test` and `make integration-test` additionally cover actual
  `.xqgame` Save As/autosave/prepared reopen/local-version recovery, exact
  FEN/UCCI diagnostics, branches, annotations, and recovery failures. They use
  only the local Rust XCFramework and repository-local Swift packages.
- `make fuzz-smoke` runs a deterministic, repository-contained corpus for old
  `.xqgame` migration fixtures, preserved unknown extensions, malformed document
  inputs, and FEN/UCCI mutation inputs. It processes exactly 512 deterministic inputs
  per Rust and Swift corpus suite, caps each generated input at 1 KiB, runs every Cargo
  invocation with `--offline`, and terminates each build/test subprocess after a
  fixed 180-second wall-clock deadline. It never opens a document for installation
  or contacts a network.

T050 command ownership:

- `make vendor-verify` is the ONLY networked engine command: it downloads the
  locked source archive and the engine release archive, verifies SHA-256 and
  byte counts, extracts the matching NNUE, re-runs the pinned source's `make
  help`, and enforces the recorded output. Normal builds never download.
- `make archive-corresponding-source` builds the immutable corresponding-source
  archive (exact tree, project patch, licenses, build instructions, checksums)
  deterministically (fixed mtimes, `gzip -n`) and offline. It fails closed when
  the separately verified vendor source cache is absent; it never invokes
  `make vendor-verify` implicitly.
- `make engine-smoke` verifies the built helper and NNUE hashes, runs the real
  `uci`/`isready`/fixed-FEN `go` search, and proves that missing or corrupt NNUE
  disables analysis with a bounded diagnostic instead of corrupting the session.
- `make verify-assets` re-verifies helper/NNUE hashes against the locked
  manifest, the complete license/notice set, and that the development manifest
  stays not release-eligible.
- `make verify-source` rebuilds the helper from the committed
  corresponding-source archive (offline, network denied by sandbox-exec) and
  byte-compares the executable with the locked helper hash. It uses the local
  hash-verified NNUE cache and fails with instructions to run the explicit
  networked vendor command when that cache is absent.
- `make verify-signing` proves the archived sandbox helper: the built app's
  embedded helper is ad-hoc signed, its code-directory hash matches the locked
  artifact, the NNUE matches the lock, and the embedded helper completes a
  handshake and search inside a restrictive sandbox with network denied.

T090 command ownership:

- `make build-community-release` builds the unstaged Community Release app
  (CODE_SIGNING_ALLOWED=NO) with the verified helper, NNUE, licenses/notices,
  and the locked manifest embedded. It never signs and never downloads.
- `make sign-notarize-community` Developer ID signs (inside-out: nested
  helper first) and notarizes the Community artifact, staples, and writes
  SHA-256 checksums. Credentials never enter the repository: it requires a
  "Developer ID Application" identity in the keychain plus `NOTARY_PROFILE` (or
  the keychain item `nativexiangqi-notary`), and fails closed without them.
- `make release-gate` runs every hard gate (assets, source rebuild, release
  policy, signing, lint, Swift/AppKit suites, exact rule label, Developer ID
  and notary availability) and writes `build/reports/release-gate.json` plus a
  human-readable Markdown report. It never fakes signing success.

T080 command ownership:

- `make regression-dashboard` writes one deterministic machine-readable JSON
  record (`build/regression-dashboard.json`) aggregating git identity, dirty
  path count, and the outcomes of the cheap static gates (release policy, lint,
  generated-FFI cleanliness, assets, source, signing). It never runs network
  commands and never launches the real engine; it fails nonzero when any gate
  fails.

T060 command ownership:

- `make swift-test` and `make integration-test` additionally run the analysis
  suites: typed perspective/budget conversions, bounded SQLite analysis cache
  (identity, LRU, caps, corruption quarantine), coordinator arbitration and
  lifecycle, and fake-engine end-to-end AI play with Rust revalidation. All
  engine interactions use the deterministic C fakes; no real helper is needed.
- `make benchmark-engine` measures, offline against the verified artifacts,
  per-preset search latency, 100 cancel + 100 final + 500 lifecycle switches,
  helper RSS, and prints machine-readable JSON. The standard combined hard gate
  stays 512 MiB; the short mode fails on a session that ends failed.
- `make benchmark` aggregates `benchmark-rules`, `benchmark-ui`, and
  `benchmark-engine`. The 30-minute RSS/thermal run is a separate opt-in mode
  (`benchmark-engine --long-run`) and is never part of `make test`.
- Analysis updates are throttled to 5 Hz by default with a hard maximum of
  10 Hz; the analysis cache defaults to 256 MiB disk with 64/256/1024 MiB
  choices and a 32-entry/16 MiB memory LRU.

## 3. Reproducibility

- commit Cargo.lock；
- source/helper/NNUE/config/license manifests；
- exact patches/build command；
- no personal Homebrew runtime dependency；
- Release bundle contains helper/NNUE/licenses；
- corresponding source archive rebuild test；
- generated header/metadata clean diff。

## 4. CI

### Every commit

format/lint/Rust/Swift/fake UCI/perft/policy negative/schema/docs.

### Main

real engine smoke/archive sandbox/basic RSS/source package dry run.

### Release candidate

long stress、WXF corpus、source rebuild、memory/thermal、sign/notarize、licenses/accessibility/localization.

最终门在 Apple Silicon 实机，不用 x86 模拟。
