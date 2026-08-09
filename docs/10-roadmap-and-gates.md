# 10. 开发路线与发布门

## Phase 0：仓库、许可、引擎来源

T000。

输出 workspace/app shell、toolchain、manifest schema、pinned Pikafish candidate、NNUE license state、fail-closed release policy。

门：commercial/MAS negative tests；source/network 可追踪。

## Phase 1：Rust artifact/FFI

T010。

输出 Cargo、ABI smoke、generated header、static artifact。

门：offline reproducible build、ownership tests。

## Phase 2：基础规则/perft

T020。

输出 90-square rules、check/mate/stalemate、tree/hash/history、FEN/UCCI、FFI。

门：piece fixtures、perft、apply/undo。

## Phase 3：原生窗口/棋盘

T030。

输出 AppKit document shell、custom board、keyboard/VoiceOver、fake/no-engine workflow。

门：idle RSS、no per-square objects、canonical flip。

## Phase 4：原生棋谱

T040。

输出 `.xqgame`、migration、branch/comment、FEN/UCCI panels。

门：round-trip、malformed limits、failure no overwrite。

## Phase 5：Pikafish helper

T050。

输出 pinned build、source archive、signed helper、UCI actor、fake/real smoke。

门：archive sandbox、license/source complete、cancel/crash bounded。

## Phase 6：分析、人机与 cache

T060。

输出 candidate/PV/score、AI play、SQLite、presets/memory pressure。

门：Rust bestmove validation、perspective、Hash/RSS。

## Phase 7：WXF 判罚

T070。

输出 exact snapshot、event model、cycle/responsibility、reviewed corpus、explanation UI。

门：approved fixtures；ambiguous explicit；profile versioned。

## Phase 8：产品加固

T080。

输出 concurrency/accessibility/localization/recovery/performance audit。

门：no data loss、keyboard/VoiceOver、no RSS slope、policy gates intact。

## Phase 9：Community release

T090。

输出 notarized artifact、checksums、exact corresponding source、notices、benchmark/rule/license reports。

门：free Community only；commercial/MAS stay false；source rebuild succeeds。

## Stop conditions

- Swift/Rust 双规则；
- engine 决定 legality/adjudication；
- autosave 等 helper/cache；
- cancellation by sleep；
- perft/regression unresolved；
- ambiguous WXF 被猜测；
- source/network permission unresolved；
- unsafe release flag 可绕过；
- helper archive sandbox 失败；
- memory hard gate 持续失败。
