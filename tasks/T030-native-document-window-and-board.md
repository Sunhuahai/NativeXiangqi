# T030 — Native document shell and Xiangqi board

## Objective

Build the AppKit document window and custom Xiangqi board using T020 Rust state. Deliver complete new/in-memory local play before the final `.xqgame` format.

## Dependencies

T020 complete.

## Read first

- `AGENTS.md`
- `docs/02-system-architecture.md`
- `docs/03-native-macos-ui.md`
- ADR 0001

## Allowed scope

App, `XiangqiUI`, initial document shell, UI tests, geometry/performance benchmarks.

## Required work

1. Create `NSDocument`, window controller and three-pane split UI.
2. Add variation outline, custom board and analysis placeholder.
3. Implement pure red/black-aware `XiangqiBoardGeometry`.
4. Draw board, river/palace, pieces, labels, last move, selection, legal targets, check and fake bounded candidates.
5. Wire pointer/keyboard selection and moves to Rust.
6. Wire native menus/toolbar/validation, undo/redo, navigation, board flip.
7. Implement virtual accessibility for squares/pieces.
8. Prove no per-square view/layer/task.
9. Display “基础规则模式”.
10. Add temporary minimal autosave smoke only; replace in T040.
11. Record idle RSS/draw/input benchmarks.

## Tests and commands

```bash
make swift-test
make integration-test
make build
make benchmark-ui
```

## Acceptance

User can play legal local game, capture, receive check/mate/stalemate state, branch/navigate/undo, flip without changing canonical coordinates, and operate keyboard/accessibility. Idle baseline documented.

## Non-goals

No final `.xqgame`, FEN panels, real engine, WXF full mode or theme system.

## Required task report

Next task T040; stop.
