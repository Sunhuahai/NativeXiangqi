# 01. 产品需求文档

## 1. 定位

`NativeXiangqi` 是本地优先、原生、轻量、可长期保存棋局的 macOS 中国象棋工具。核心体验是：无账户、无常驻服务、键盘高效、规则可靠、Pikafish 可控、发布合规可审计。

## 2. v1 用户流程

用户可以：

1. 新建标准 9×10 棋局或从 FEN 创建。
2. 本地双人对弈。
3. 选棋、查看合法落点、吃子、将军、将死和困毙。
4. 撤销、重做、跳转、创建分支、删除分支和注释。
5. 保存/重开 `.xqgame`。
6. 导入/导出 FEN；导入/导出 UCCI 主线。
7. 翻转棋盘并切换坐标显示，不改变规范坐标。
8. 启动、暂停、停止 Pikafish。
9. 查看候选着、优势分/杀棋、深度、节点、NPS 与 PV。
10. 进行人机对弈，所有引擎着法经 Rust 验证。
11. 查看重复/长将/长捉的结构化判罚说明（仅启用已验证规则 profile）。
12. 在引擎不可用时继续所有文档操作。
13. 通过键盘和 VoiceOver 完成核心流程。

## 3. 功能需求

### 3.1 基础规则

- 将/帅、士、象、马、车、炮、兵/卒。
- 九宫、不过河、塞象眼、蹩马腿、炮架、飞将。
- 走后不暴露己方将帅。
- 将军、应将、将死、困毙。
- 认输、超时。
- 固定 perft corpus 与随机 apply/undo 性质测试。
- 规则 profile 与版本写入文档。

### 3.2 重复、长将和长捉

- 记录每 ply 的 check、chase target、exchange/idle/escape 等事件。
- 循环检测与责任分类分离。
- 结果至少包括：无动作、和棋、红方违规、黑方违规、需变着方、unsupported/ambiguous。
- 解释包含循环手数范围、标签、目标与规则快照。
- 未完成 T070 时显示“基础规则模式”，不伪装完整赛事规则。
- 旧文档保留原 profile，不静默迁移判罚语义。

### 3.3 文档与交换

`.xqgame` v1 包含：

- schema/version；
- stable document ID；
- initial FEN；
- rule profile/version；
- variation tree/current node；
- annotations、metadata；
- forward-compatible extensions。

FEN 严格验证。UCCI 用于主线坐标着法交换。XQF 只在后续独立任务评估安全只读导入；v1 不写出。

### 3.4 Pikafish 分析

- UCI handshake 与动态 option discovery。
- 候选着、分数/杀棋、深度、seldepth、节点、NPS、时间、PV。
- 分数视角明确，UI 统一为红方或当前行棋方视角。
- UI 默认 5 Hz 更新，最高 10 Hz。
- final 结果持久缓存；partial `info` 只用于界面。
- Hash/Threads/Ponder 使用白名单档位；Ponder 默认关闭。
- stop、timeout、crash、NNUE 损坏、非法 bestmove 有恢复路径。
- 人机着法由 Rust 再验证，不偷偷改用第二候选。

### 3.5 时钟

v1 提供绝对用时与 Fischer 增益；额外赛事时间制可后续扩展。时钟修改可撤销，超时结果明确。

## 4. 非功能需求

### 4.1 可靠性

- 每次文档修改可撤销。
- 引擎结果是派生数据，不是保存前提。
- 自动保存不等待 helper/cache。
- 解析/迁移失败不覆盖原文件。
- engine crash 不改变文档 change count。
- rule/adjudication failure 返回 typed state，不猜测。

### 4.2 性能

- 鼠标/键盘选择、落子、跳转保持一帧主线程预算。
- 不为 90 格创建 90 个 view/layer。
- 大变化树有上限、进度和取消。
- idle CPU 接近零。
- Hash、threads、PV、输出、请求和 cache 全部受限。

### 4.3 隐私

- v1 不上传棋局、注释、分析或设备信息。
- 日志/诊断默认不含完整记录。
- 不执行用户指定引擎。
- 不在运行时下载可执行代码。

### 4.4 可访问性

- 棋子/格点可键盘导航和激活。
- VoiceOver 描述坐标、棋子、阵营、选中、合法目标、将军和候选。
- 红黑颜色不是唯一通道；使用文字、轮廓、形状。
- 分析图有文本/表格替代。
- 遵守 Reduce Motion 和高对比度。

### 4.5 分发合规

- Community artifact 免费开源。
- release manifest 指向精确 Pikafish source、patch、binary 与 NNUE。
- commercial/paid/MAS 不能通过普通 build flag 开启。
- source archive 必须能重建 distributed helper。
- 未满足 NNUE 权限不得发布。

## 5. v1 完成定义

用户能离线完成对局、保存/重开、分支注释、FEN/UCCI 交换、稳定本地分析与人机对弈；基础规则由 Rust 保证，WXF profile 在 T070 后按明确快照提供；T090 生成可重建、签名、公证且许可材料完整的 Community artifact。
