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
  board flip, and temporary-persistence failure paths. It does not launch an engine
  or access a network.
- `make benchmark-ui` displays the actual local three-pane `NSDocument`, waits for
  its Rust-backed session to become ready under a bounded monotonic deadline, then
  emits one machine-readable JSON record containing no-engine idle RSS plus p50/p95
  offscreen-board draw and synthetic pointer-event-to-board-delegate latency. It
  reads `budgetsMiB.emptyWindowHard` from `config/memory-budgets.json` and fails
  above that hard gate.

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
