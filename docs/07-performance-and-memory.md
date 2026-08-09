# 07. 性能与内存预算

## 1. 原则

轻量包括 idle RSS、active App+helper、Hash、CPU/thermal、cache growth、helper shutdown reclaim、文档跳转和系统压力。使用 Instruments/xctrace 与脚本测量。

## 2. 初始预算

工程门，不是已实现结果：

| 场景 | 目标 | 硬门 |
|---|---:|---:|
| 空白窗口 App RSS | ≤ 80 MiB | ≤ 140 MiB |
| 大棋谱、无引擎 App RSS | ≤ 120 MiB | ≤ 200 MiB |
| standard App+Pikafish（M1 8GB） | ≤ 320 MiB | ≤ 512 MiB |
| helper 停止 10 秒后 | helper 消失，App 接近无引擎 | 无僵尸/持续增长 |
| UI engine update | 5 Hz | ≤ 10 Hz |
| idle CPU | 接近 0% | 无周期轮询 |

## 3. App 策略

- Rust arena/固定 90-square；Swift 只取当前快照和可见 node summaries。
- outline lazy children。
- 棋盘不使用 per-square views/layers。
- trend 只存 scalars，不存每手长 PV。
- protocol log line+byte bounded。
- adjudication explanations 按需生成，不缓存整局冗余对象。
- SQLite 查询/内存 cache 受限。

## 4. Pikafish 策略

- 8GB 默认 Hash 32 MiB，16GB+ 可 64 MiB；具体经基准。
- 1–2 threads 默认。
- Ponder off。
- PV/MultiPV/line length bounded。
- hidden/minimized/low power/memory pressure 时停止持续分析。
- idle timeout/last document close 后退出。

## 5. 内存压力

1. stop deep/continuous search；
2. drop long PV/chart/diagnostics；
3. clear App LRU；
4. future searches downgrade Hash/thread preset；
5. terminate helper；
6. preserve canonical document。

回调中不做同步慢 I/O。

## 6. 基准

- cold/warm start、新建；
- 1k/10k node document；
- 1,000 次导航；
- 10,000 move/undo；
- perft；
- 100 cancel/100 final；
- 100 `ucinewgame`；
- 500 lifecycle/switch stress；
- crash recovery；
- memory pressure；
- 30 min analysis RSS slope/thermal；
- archive first launch/NNUE load；
- rule adjudication corpus runtime。

报告 median/p95/peak、hardware、macOS、commit、manifest、Hash/threads。
