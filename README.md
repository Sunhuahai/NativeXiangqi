# NativeXiangqi：macOS 原生中国象棋 App 开发执行包

本仓库分阶段实现一款 Apple Silicon 原生 macOS 中国象棋应用：本地对弈、分支棋谱编辑、FEN/UCCI 交换、可解释规则判罚，以及 Pikafish 本地分析与人机对弈。T000 已建立可审计的工程骨架；规则、棋盘、文档行为和引擎通信仍按后续任务卡逐项实现。

文档基线日期：**2026-08-09**。外部版本、权重许可、Apple 分发政策和 WXF 规则快照必须在 T000、相关任务及每次发布前重新核验。

## 核心决策

| 领域 | 决策 |
|---|---|
| 产品 | 单一中国象棋 App，不做“通用棋类平台” |
| 平台 | v1 仅 Apple Silicon，最低 macOS 15 |
| UI | AppKit-first；`NSDocument`、原生菜单/工具栏/分栏，自定义 `NSView + Core Graphics` 棋盘 |
| Swift | Xcode 26.x，Swift 6 严格并发；Swift 负责 macOS 集成与引擎进程管理 |
| Rust | 合法着、将军/将死/困毙、变化树、重复事件、WXF 判罚、FEN/UCCI 与窄 C ABI |
| 引擎 | Pikafish 作为签名 helper 子进程，通过 UCI 协议通信；引擎不是规则裁判 |
| 数据 | 版本化 `.xqgame` 主文档；FEN/UCCI 仅用于交换 |
| 缓存 | 系统 SQLite3，严格字节/条目上限和 LRU |
| 网络 | v1 无运行时网络权限；构建与归档不下载资产 |
| 分发 | 默认免费开源 Community 版、Developer ID 签名、公证、站外分发 |
| 许可门 | 商业、付费和 Mac App Store 默认强制关闭，必须由书面授权、替代资产和法律审查后的 ADR 解锁 |
| 内存 | 保守 Hash/线程、Ponder 关闭、单重型进程、空闲退出 |

## 当前仓库结构

```text
NativeXiangqi/
├── AGENTS.md
├── LICENSE
├── Makefile
├── Cargo.toml
├── Cargo.lock
├── NativeXiangqi.xcworkspace
├── App/NativeXiangqi/
│   ├── NativeXiangqi.xcodeproj/
│   ├── Resources/
│   └── Sources/
├── Packages/
│   ├── XiangqiUI/
│   ├── XiangqiDocumentKit/
│   ├── PikafishKit/
│   └── XiangqiCoreBinary/
├── Rust/
│   └── crates/
│       ├── xiangqi-core/
│       ├── xiangqi-io/
│       └── xiangqi-ffi/
├── Engines/Pikafish/
│   ├── manifests/            # schema 与不可发布的 development lock
│   ├── configs/              # 锁定源码的 make help 证据
│   ├── licenses/             # GPL、AUTHORS 与独立 NNUE 条款
│   └── corresponding-source/ # 后续发行的 fail-closed 布局
├── Tests/
│   └── Policy/
├── scripts/
└── docs/
```

当前 App target 只显示静态 AppKit 外壳窗口；四个 Swift package 和三个 Rust crate 只有边界声明，不包含产品行为。T000 不打包 Pikafish helper 或 NNUE，development manifest 因未解决 helper、对应源码归档与书面商业许可而明确不可发布。

## 本地前置条件

- Apple Silicon Mac；
- Xcode 26.x（Swift 6 严格并发），最低部署目标 macOS 15；
- 根目录锁定的 Rust 1.97.0、rustfmt、clippy 与 aarch64-apple-darwin target；
- GNU Make 与 Python 3.11+。

make bootstrap 只检查并报告版本，从不安装或下载。普通 Xcode build 禁止自动解析远程 package，并且没有下载 build phase 或网络 entitlement。

~~~bash
make bootstrap
xcodebuild -list -workspace NativeXiangqi.xcworkspace
cargo metadata --locked --format-version 1
scripts/validate-manifests.sh
make verify-release-policy
scripts/check-no-build-downloads.sh
make build
~~~

## 使用方式

1. 先阅读 AGENTS.md、tasks/INDEX.md 与当前任务卡。
2. 严格按 T000 → T010 → … → T090，每次只执行一张任务卡。
3. 引擎、NNUE、许可证或发布策略更新必须使用独立任务/PR，不得与功能开发混合。
4. 发布前运行 make release-gate，并验证对应源码、资产哈希、规则标签、签名/公证和许可证。

## v1 明确不做

在线对战、账号、聊天、云同步、远程计算、插件商店、任意第三方引擎加载、iOS/Windows/Linux/Web、跨平台 UI、自研顶级搜索引擎、XQF 写出、照片识别、主题市场和多个并行重型引擎。

## 最重要的工程原则

规则裁决独立于 Pikafish。Rust 维护唯一规范棋局、合法着与重复判罚状态；Swift 只持有可丢弃快照。引擎可以停止、崩溃或缺失，但打开、落子、分支、注释、撤销、自动保存和恢复必须始终可靠。商业与商店发布门默认不可绕过。
