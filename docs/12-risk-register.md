# 12. 风险登记表

| ID | 风险 | 影响 | 缓解 | 阻断任务 |
|---|---|---|---|---|
| X1 | Pikafish tag/build target 在 Apple Silicon 不稳定 | helper 无法发布 | pinned commit、`make help`、archive smoke | T000/T050 |
| X2 | NNUE 禁止未授权商业使用 | 商业/商店风险 | Community fail-closed、书面许可/替代 | T000/T090 |
| X3 | GPL/商店关系未审查 | 下架/合规风险 | 对应源码、站外免费、legal ADR | T090 |
| X4 | Swift/Rust 双规则 | 不同步/丢档 | Rust 唯一状态、Swift snapshot | T020/T030 |
| X5 | engine 被当 legality oracle | 非法着/错判 | Rust revalidation | T050/T060 |
| X6 | WXF 长将长捉误判 | 错误胜负 | 独立 event/cycle/classifier + reviewed corpus | T070 |
| X7 | ambiguous 被强判 | 不可信 | explicit unsupported | T070 |
| X8 | UCI 输出/请求无界 | OOM/freeze | line/bytes/PV/pending 上限 | T050 |
| X9 | helper sandbox archive 失败 | 发布无分析 | early archive signing test | T050 |
| X10 | source archive 不对应 binary | GPL 违约 | rebuild verification + hashes | T050/T090 |
| X11 | FFI ownership | crash/leak | narrow ABI/sanitizer/100k tests | T010/T020 |
| X12 | document migration 覆盖原文件 | data loss | temp decode/validate/atomic install | T040 |
| X13 | Hash/threads/ponder 过大 | memory/thermal | conservative presets/no ponder | T060/T090 |
| X14 | release flag 可绕过 | 未授权分发 | schema+script+CI negative tests | T000/T090 |
| X15 | XQF scope creep/parser risk | delay/security | v1 non-goal, separate future task | T040 |
| X16 | cancellation by sleep | race/zombie | actor state machine/fake clock | T050 |
| X17 | score perspective error | misleading UI | typed perspective fixtures | T060 |

每个报告更新相关风险；新增高影响风险先登记。
