# 04. Rust 象棋核心、判罚与 Swift FFI

## 1. Workspace

```text
Rust/
├── Cargo.toml
└── crates/
    ├── xiangqi-core/  # board, moves, tree, hashes, repetition/adjudication
    ├── xiangqi-io/    # FEN, UCCI
    └── xiangqi-ffi/   # only C ABI and unsafe boundary
```

依赖保持少量：`thiserror`、`smallvec`，必要时 `serde/serde_json` 用于版本化文档 payload。大型 move-generation 库、async runtime、ORM 或解析框架需 ADR。

## 2. Board 与走法

使用固定 90-square 表示。类型包括 side、piece kind、square、move。实现：

- general：九宫、飞将；
- advisor：九宫斜一步；
- elephant：田字、塞象眼、不过河；
- horse：日字、蹩马腿；
- rook：直线；
- cannon：不吃无架、吃子恰一架；
- pawn：过河前后方向限制；
- self-check filter。

先生成 pseudo-legal，再验证不能暴露己方将帅；或采用等价可证明方案。所有路径有 fixture。

## 3. 变化树、命令与 undo

arena + stable IDs。undo token 恢复：

- from/to/capture；
- side；
- counters；
- position/repetition hash；
- history length；
- per-ply event state；
- adjudication state；
- variation cursor。

apply + undo 恢复 canonical bytes/hash。失败不部分修改。

## 4. Check/mate/stalemate

提供：

- `is_in_check(side)`；
- legal move count；
- terminal state；
- 困毙语义按 selected profile 明确。

不依赖 Pikafish 判断终局。

## 5. Repetition/WXF 模块

分层：

1. **event extraction**：每 ply 标记 check、capture、attack/chase candidates、exchange、escape、idle 等。
2. **cycle detection**：根据规范 hash/history 找重复区间。
3. **responsibility classification**：按精确 WXF snapshot 解释双方行为。
4. **result**：typed outcome + explanation。

事件模型需要保留合法替代着或其他规则所需证据。T020 只建立基础 history；T070 才启用完整 profile。unsupported 必须显式返回。

## 6. FEN/UCCI

FEN：

- 验证 10 ranks、每行 9 files；
- piece chars、general 数量、side；
- 不接受越界/重复；
- position invariant 校验；
- 长度限制。

UCCI：

- 固定坐标格式；
- parse/write；
- 每步通过 Rust legality；
- 导入主线失败报告准确 ply，不留下半导入状态。

`.xqgame` 的外层版本化 JSON/envelope、元数据和 safe extensions 由
`XiangqiDocumentKit` 保存；规范 core snapshot（initial FEN、profile、flat tree、
selected-child、annotations）通过 Rust restore transaction 逐步重放。这样 Swift
不会拥有独立棋盘/合法性真相，且未知 extension 不必穿过有界 C owned-buffer。

## 7. FFI

opaque handles 与 batch APIs：

- ABI/capabilities；
- create from initial/FEN，以及有界 document restore transaction；
- destroy/clone；
- selectable pieces/legal destinations；
- apply/undo/redo/navigation；
- board snapshot；
- terminal/adjudication summary；
- FEN/UCCI serialize；
- document tree/annotation snapshot batches；
- structured errors；
- buffer release。

禁止 per-square FFI 循环。Swift 明确 close，deinit 仅兜底。

## 8. Hash

position hash 包含 board + side。repetition/adjudication identity 还需规则 profile 与必要 history/event metadata。固定 Zobrist seed，增量与重算对比。

## 9. 构建与测试

- arm64 static/XCFramework；
- LTO、panic abort、strip；
- generated header clean；
- perft fixed corpus；
- 每棋子边界、炮架、马腿、象眼、飞将；
- check escape/block/capture；
- mate/stalemate；
- randomized apply/undo；
- FEN/UCCI round trip；
- 100k FFI lifecycle；
- fuzz pointer/length/text/document payload。
