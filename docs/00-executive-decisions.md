# 00. 执行摘要与不可逆决策

## 目标

开发一款独立的 macOS 原生中国象棋应用 `NativeXiangqi`。它首先是一款可靠的本地棋谱与规则工具，其次才是引擎前端：即使 Pikafish 或 NNUE 不存在、不可用或崩溃，用户仍能新建、打开、落子、分支、注释、撤销、保存和恢复棋局。

技术目标与发布目标必须分开。Pikafish 提供高水平搜索，但本地 Rust 规则内核负责合法着和规则判罚。分发上采用保守、可审计、默认关闭风险模式的 Community 路线。

## 决策

### D1：单产品、单仓库

本仓库只实现中国象棋。不得预先加入通用棋类平台、其他棋类规则或第二套 App target。抽象只在本项目内至少两个真实使用点出现后提取。

### D2：Apple Silicon-only v1

只构建 `arm64-apple-macos`，最低 macOS 15。加入 Intel 必须新 ADR、独立构建和实机测试，不默认制作 Universal Binary。

### D3：AppKit-first

主窗口、文档、菜单、工具栏、分栏、列表、拖放、撤销与辅助功能使用 AppKit。棋盘是定制 `NSView`，用 Core Graphics 绘制。SwiftUI 仅限设置等低频界面且不能复制文档状态。

### D4：Rust 是规则与判罚内核

Rust 实现：

- 90 格规范局面、紧凑变化树、稳定节点 ID、命令与精确 undo；
- 所有棋子基础走法、蹩马腿、塞象眼、炮架、九宫、过河、飞将；
- 将军、将死、困毙和走后不暴露己方将帅；
- FEN/UCCI；
- 重复事件记录、循环检测与经评审的 WXF 长将/长捉判罚；
- 窄 C ABI。

Rust 不实现顶级 alpha-beta/NNUE 搜索，也不实现 macOS UI。

### D5：Pikafish 进程隔离

Pikafish 作为 App Bundle 内签名 helper 运行，通过 UCI 协议通信。主 App 不链接其 C++ 代码。每个 bestmove 由 Rust 再验证；引擎分数和 PV 不能决定规则责任。

### D6：版本化原生棋谱

v1 使用 `.xqgame` 保存完整变化树、注释、规则 profile 和扩展。FEN 与 UCCI 用于交换，不承载完整分支文档。XQF 不作为 v1 阻断功能，写出明确不做。

### D7：发布默认 fail-closed

首发基线：

- 免费、开源 Community 版；
- Developer ID 签名、公证、站外分发；
- 完整 GPL、AUTHORS、修改、构建脚本、对应源码与 NNUE 许可；
- commercial/paid/Mac App Store 默认在脚本和 scheme 层关闭。

解锁必须有书面权重许可或通过棋力门的替代资产、GPL/商店分发审查和 accepted ADR。不得用普通环境变量绕过。

### D8：规则版本显式

WXF 规则按精确版本/快照实现。循环检测与责任分类分离，结果可解释。未通过判例评审前，界面标记“基础规则模式”。旧文档不会被新规则静默重解释。

### D9：无运行时网络

v1 不申请网络 entitlement，不下载引擎、NNUE 或可执行文件。发行资产由 manifest 与 SHA-256 锁定。

## v1 不做

- 在线匹配、观战、聊天、账号、云同步；
- 远程计算、引擎训练；
- 任意第三方引擎加载或插件系统；
- iOS、Windows、Linux、Web、跨平台 UI；
- 自研顶级搜索引擎；
- XQF 写出、棋盘 OCR、主题商店；
- 多个并行重型引擎；
- 未过 WXF 判例门却宣称完整赛事判罚；
- 未过许可证门的商业或商店发布。

## 成功标准

- 无引擎时完整编辑和保存棋局。
- Rust 是唯一规范合法性与判罚状态，Swift 无第二套规则。
- 所有引擎输出、请求、日志、缓存与解析均有上限。
- App idle 接近零 CPU，无周期轮询。
- helper 崩溃、取消、切局和内存压力不留下僵尸。
- 规则结果可解释、版本化、可用 fixture 复现。
- 发布 artifact 能对应到精确 source、patch、build 与 NNUE 许可。
- 风险发布模式默认不可绕过。
