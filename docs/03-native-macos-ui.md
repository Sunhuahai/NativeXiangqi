# 03. macOS 原生 UI 设计

## 1. AppKit 组成

- `NSDocument`：`.xqgame` 读写、autosave、version recovery。
- `NSWindowController`。
- `NSSplitViewController`：变化树 / 棋盘 / 分析器。
- `NSOutlineView`：变化与注释节点。
- `XiangqiBoardView: NSView`：棋盘、棋子、输入、虚拟 accessibility。
- `NSTableView`：候选/PV/engine stats。
- `NSViewController`：规则/判罚解释。
- `NSToolbar`、菜单、上下文菜单、command validation。
- `UndoManager`。

SwiftUI 只可用于低频 Settings，不复制棋局状态。

## 2. 棋盘绘制

绘制顺序：

1. 背景；
2. 横竖线、九宫斜线、楚河汉界、坐标；
3. 棋子；
4. 选中、合法目标、最后一手、将军、键盘焦点；
5. 引擎候选编号与 PV preview；
6. 临时交互。

Core Graphics 默认。棋子可使用程序绘制圆形、轮廓与文字/glyph；字体与 glyph run 缓存。禁止每格/每子 view/layer。翻转显示由 geometry transform 完成，不修改 Rust 坐标。

## 3. Geometry

```swift
struct XiangqiBoardGeometry: Sendable, Equatable {
    let bounds: CGRect
    let backingScale: CGFloat
    let isFlippedForBlack: Bool

    func point(for square: XiangqiSquare) -> CGPoint
    func square(near point: CGPoint, tolerance: CGFloat) -> XiangqiSquare?
    func invalidationRect(for square: XiangqiSquare) -> CGRect
}
```

测试覆盖窗口缩放、Retina/1x、红/黑视角、边缘 tolerance 和坐标 label。

## 4. 输入

- 单击己方棋子选中，再单击合法目标。
- 可选拖动，但不是唯一方式。
- 方向键移动焦点，Return/Space 选中/落子。
- 左/右浏览前后手；修饰键用于格点导航模式。
- Esc 取消选择/PV preview。
- Control-click 显示注释、复制 FEN、分析等原生命令。
- 所有落子最终经 Rust apply。

## 5. 状态呈现

- 将军使用轮廓、图标和 VoiceOver 提示，不仅靠颜色。
- 将死/困毙显示明确结果。
- WXF 未完成时显示“基础规则模式”。
- 已完成 profile 的重复判罚提供“为何判定”的结构化面板，列出循环范围和责任。
- ambiguous 保持中性，不自动结束棋局。
- 引擎 score 显示当前视角并允许切换红方固定视角。

## 6. 文档命令

- Cmd+N/O/S/Shift+Cmd+S。
- Cmd+Z/Shift+Cmd+Z。
- 左/右前后手；Cmd+左/右首末。
- 空格开始/暂停分析（非文本焦点）。
- 菜单：复制/粘贴 FEN、导出 UCCI 主线、翻转棋盘、规则说明。
- partial analysis 不改变 change count。

## 7. 辅助功能

棋盘为 group，90 格/棋子使用虚拟元素。描述：

- 坐标与显示方向；
- 棋子名称、红/黑、空格；
- 当前选中、可走、目标是否吃子；
- 将军/受攻击相关状态；
- 候选排名、优势变化、PV；
- 判罚状态。

分析表、图和判罚说明均有文本替代。支持 keyboard-only、Reduce Motion、高对比度。

## 8. 动画

短落子/吃子反馈可选，遵守 Reduce Motion。快速跳转不逐手动画。engine info 更新不排队动画。动画不能延迟规则提交、保存、停止或退出。
