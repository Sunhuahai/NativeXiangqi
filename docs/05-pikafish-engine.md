# 05. Pikafish 引擎集成

## 1. 选型与边界

Pikafish 是 v1 高水平搜索后端。App 负责文档、规则、判罚和 UI，不修改其搜索逻辑。Rust 是合法性与规则裁决来源。

## 2. 版本锁

不得跟随 unpinned branch。T000 必须选择一个在 Apple Silicon 上验证的 release/tag 或精确 commit，并记录：

- repository、tag/commit；
- source archive hash；
- `make help` 输出对应 build target；
- compiler、flags、CPU features；
- executable hash；
- NNUE 来源、文件名、字节数、hash；
- GPL/source license；
- NNUE license/permission；
- corresponding-source 路径与重建命令。

计划文件允许 `unresolved = true`，Release manifest 不允许。

T050 已解决 helper 构建并记录：

- engine: `Pikafish-2026-01-02`，commit `ce0679e0`…；
- build: `make build ARCH=apple-silicon COMP=clang GIT_SHA=ce0679e0 GIT_DATE=20260103`
  （`make help` 确认 `apple-silicon` 目标存在；选择非 PGO 的 `build` 而不是
  `profile-build`，因为 PGO 输出依赖时序、无法做字节级重建验证；两次独立构建
  的 SHA-256 一致）；
- helper: `Engines/Pikafish/artifacts/pikafish-2026-01-02-apple-silicon`
  （752,808 字节，SHA-256 记录于 manifest）；
- NNUE: 来自引擎自身 release 归档 `Pikafish.2026-01-02.7z` 内的
  `pikafish.nnue`（53,212,941 字节，SHA-256 与版本头 `0x7AF32F20` 均已校验）。
  **资产修正记录**：T000 锁定的 mutable `master-net` 资产（51,585,654 字节）
  携带版本头 `0x6a448afa`，被锁定引擎拒绝；引擎发布归档内的网络与引擎完全
  匹配，因此锁移动到该归档；
- 对应源码归档：
  `corresponding-source/archive/Pikafish-2026-01-02-corresponding-source.tar.gz`
  （含精确源码树、`0001-pin-release-version.patch`、许可证/通知、构建说明与
  校验和；`make verify-source` 从归档离线重建并与锁定 helper 字节级一致）。

## 3. 构建

锁定源码后先运行其 `make help`，不要把历史 ARCH 名称当永久事实。构建脚本需：

- 使用预取 source；
- 记录环境和命令；
- 产生 arm64 helper；
- 运行 `uci`、`isready` 和固定 FEN 小搜索；
- 归档 exact source、patch、Makefile/build instructions；
- 不在用户机器编译；
- 不在 Xcode archive 下载。

## 4. UCI 会话

握手：

```text
launch
uci
parse id and option lines
uciok
setoption only for discovered whitelist options
isready
readyok
```

新局/搜索：

```text
ucinewgame
isready
position fen <fen> moves <ucci...>
go movetime <ms> | go nodes <n> | go depth <d>
```

停止：

```text
stop
wait bounded bestmove
quit on shutdown
```

解析 typed fields：

- depth、seldepth；
- score cp/mate + bounds；
- nodes、nps、time；
- multipv（若支持且启用）；
- pv；
- bestmove/ponder。

未知 token 忽略并低频诊断。行长、总字节、PV、pending 与 diagnostics 受限。

T050 已实现 `PikafishKit.PikafishSession`：actor 会话、严格阶段机、UCI 握手与
动态选项发现、白名单 preset（light/standard/deep，仅设置引擎实际提供的选项且
数值落在其声明范围内）、`ucinewgame/position/go/stop/quit`、每代搜索的
deadline/cancel/terminal、崩溃检测与有界重启、优雅/强制关闭、有界 stdout/
stderr 行读取（原始 fd 读取，避免 Foundation FileHandle 在
readabilityHandler 下的阻塞问题）、typed info/bestmove 解析（数字范围校验、
PV 语法校验、未知 token 忽略）。UI 只接收 typed 值。

## 5. Option policy

动态发现 option，只设置实际存在项。App 提供：

- `light`：Hash 16–32 MiB，1 thread，Ponder off；
- `standard`：8GB 默认 32 MiB；16GB+ 可 64 MiB；1–2 threads；
- `deep`：用户主动，仍有 Hash/threads/time 上限。

不能允许任意 UCI command/config 注入。切局 `stop` + `ucinewgame` + `isready`。

## 6. Typed result 与视角

```swift
enum XiangqiEvaluation: Sendable {
    case centipawn(Int, perspective: XiangqiSide)
    case mateIn(Int, perspective: XiangqiSide)
}
```

保留 raw 信息，UI 明确转换为红方或 side-to-move。不要把国际象棋 pawn 单位直接称为“兵值”而无说明。mate 符号和视角有 fixtures。

## 7. Move validation

每个 bestmove：

- parse coordinate；
- current side/piece；
- base movement；
- self-check/flying general；
- active rule profile/repetition restriction（若 profile 定义）；
- generation/current position hash。

失败：停止 session、记录受限诊断、提示重试。不选择第二候选，不让 engine 覆盖 Rust。

## 8. 生命周期

- 一个 heavy process。
- no ponder。
- 取消有 terminal state，不用 sleep。
- idle timeout、窗口关闭、低电量、内存压力停止/退出。
- crash 后需用户或受限策略显式重启。
- stderr 受限，不阻塞 pipe。
- archived sandbox test。

## 9. License gate

Pikafish code 与 NNUE 分开验证。Community release 必须携带：

- GPLv3；
- AUTHORS/notices；
- exact corresponding source；
- project patches；
- build instructions；
- source/executable/NNUE checksums；
- exact NNUE license。

commercial/paid/MAS 仍 disabled，除非 accepted ADR 满足 `config/release-policy.json` 全部条件。

## 10. 发布测试

- handshake option variants；
- timeout、ignore stop、crash、stderr flood、malformed lines；
- 500 次切局/启动停止等价压力；
- fixed FEN legality/perspective；
- NNUE missing/corrupt；
- archive sandbox launch；
- M1 8GB Hash/threads/RSS/thermal；
- corresponding source rebuild verification。
