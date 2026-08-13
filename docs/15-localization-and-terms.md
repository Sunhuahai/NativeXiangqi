# 15. 本地化与术语评审（T080）

## 1. 基础设施

- 开发语言：简体中文（zh-Hans，`defaultLocalization`）。
- `XiangqiDocumentKit/Sources/XiangqiDocumentKit/Resources/` 下提供
  `zh-Hans.lproj/Localizable.strings` 与 `en.lproj/Localizable.strings`；
  `NativeXiangqiLocalized` 枚举提供键访问（`Bundle.module` 解析，键永不泄露）。
- 已迁移：分析面板按钮/弹窗/状态文案、判罚复制按钮。
- 未迁移（记录为局限）：菜单、棋盘坐标与文档状态文案仍为直接中文；
  完整迁移列入 T090 前清理，不影响术语正确性。

## 2. 象棋术语表（人工评审记录）

| 中文 | English | 说明 |
|---|---|---|
| 将/帅 | General | 宫/线规则一致 |
| 士/仕 | Advisor | |
| 象/相 | Elephant | 塞象眼 = elephant eye |
| 马 | Horse | 蹩马腿 = horse leg |
| 车 | Rook | 直行 |
| 炮 | Cannon | 需炮架（screen） |
| 兵/卒 | Pawn | 过河 = crossed the river |
| 九宫 | Palace | |
| 将军 | Check | |
| 应将 | Responding to check | |
| 将死 | Checkmate | |
| 困毙 | Stalemate | 按 profile 语义 |
| 长将 | Perpetual check | WXF 判罚：须变着 |
| 长捉 | Perpetual chase | 须变着 |
| 兑 | Exchange | 有根等值 |
| 闲 | Idle / Neutral | |
| 双方不变作和 | Draw by repetition | |
| 须变着 | Must change | 不变判负 |
| 判罚不支持 | Unsupported ruling | 不判胜负 |
| 判罚存疑 | Ambiguous ruling | 证据不足 |

## 3. WXF 判罚术语（对应 docs/14 快照）

- `wxf-2011-basic-v1` 快照的将/捉/兑/闲/须变着/和/不支持/存疑与上表一致；
  判罚面板文案直接复用 Rust 生成的确定性说明，不引入第二套术语。
- 未完成的完整赛事判罚（将>捉>闲优先级表、联合捉子等）在 UI 上一律显示
  “不支持”，绝不暗示完整赛事判罚。

## 4. 评审状态

- 上表由作者按通行中文象棋术语整理并对照 docs/14 判罚语义；
- 发布前由中文母语棋友/规则审核者复核一遍（T090 门的一部分）；
- 术语表是单一事实来源；UI 文案与其不一致即缺陷。
