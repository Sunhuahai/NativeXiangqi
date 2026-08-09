# 08. 测试与质量保证

## 1. Rust rules

Fixtures：

- 每棋子边界/阻挡；
- 炮无架、一架、多架；
- 蹩马腿、塞象眼、不过河、九宫；
- 飞将；
- self-check；
- 应将：移动将、吃子、挡将；
- 将死、困毙；
- perft fixed FEN；
- randomized legal games；
- apply/undo/hash；
- variation edits；
- FEN/UCCI round trips；
- malformed input/limits。

## 2. WXF adjudication

Corpus 覆盖：

- long check；
- mutual check；
- long chase；
- protected/unprotected target；
- alternating targets；
- exchange/idle/escape；
- cycle boundary variants；
- legal alternatives；
- ambiguous/unsupported；
- old profile compatibility。

每例有预期 outcome 和 explanation labels。判例需人工评审；不能只让代码生成 expected。

## 3. Swift

- geometry red/black；
- UCI chunking/unknown/malformed/overflow；
- state machine/generation/cancel/deadline；
- option discovery；
- score/mate perspective；
- document migration/error mapping/Undo；
- cache key/profile invalidation；
- UI throttle fake clock；
- release policy negative tests。

## 4. Fake engine

场景：

- normal handshake；
- missing/extra options；
- slow `uciok`/`readyok`；
- partial flood；
- malformed/long/invalid UTF-8；
- no bestmove；
- ignore stop；
- crash；
- stderr flood；
- illegal bestmove；
- late bestmove from old generation。

## 5. Real engine

- manifest source/helper/NNUE；
- handshake；
- fixed FEN short search；
- bestmove Rust validation；
- score perspective；
- stop/shutdown；
- archive sandbox launch；
- Hash/thread preset resource tests。

普通 `make test` 不依赖真实 engine。

## 6. UI

- new/play/capture/check/mate/save/reopen；
- branch/comment/undo；
- FEN/UCCI；
- board flip canonical consistency；
- engine missing/corrupt/crash；
- base rule badge；
- WXF explanation；
- keyboard/VoiceOver/Reduce Motion；
- autosave independent of engine。

## 7. Fuzzing

- `.xqgame` bytes/JSON；
- FEN/UCCI；
- UCI output line；
- FFI pointer/length/enum；
- cache payload。

要求资源有界、旧状态不变、typed error。

## 8. Release quality

`make test`: format、lint、Rust/Swift、fake engine、policy negative tests，无网络。`make release-gate`: real engine、source rebuild、memory/thermal、sign/notarize、license、accessibility、rule label。

禁止用 sleep 修竞态。
