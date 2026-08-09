import AppKit
import XiangqiUI

@MainActor
final class NativeXiangqiDocumentWindowController: NSWindowController, XiangqiBoardViewDelegate,
  NSUserInterfaceValidations
{
  private weak var nativeDocument: NativeXiangqiDocument?
  private let variationController: VariationOutlineViewController
  private let boardController: XiangqiBoardContainerViewController
  private let analysisController: AnalysisPlaceholderViewController

  init(document: NativeXiangqiDocument) {
    nativeDocument = document
    variationController = VariationOutlineViewController(document: document)
    boardController = XiangqiBoardContainerViewController()
    analysisController = AnalysisPlaceholderViewController()

    let splitController = NSSplitViewController()
    let variationItem = NSSplitViewItem(sidebarWithViewController: variationController)
    variationItem.minimumThickness = 180
    variationItem.maximumThickness = 340
    splitController.addSplitViewItem(variationItem)

    let boardItem = NSSplitViewItem(viewController: boardController)
    boardItem.minimumThickness = 440
    splitController.addSplitViewItem(boardItem)

    let analysisItem = NSSplitViewItem(inspectorWithViewController: analysisController)
    analysisItem.minimumThickness = 230
    analysisItem.maximumThickness = 360
    splitController.addSplitViewItem(analysisItem)

    let toolbar = Self.makeToolbar()
    let window = NSWindow(contentViewController: splitController)
    window.setContentSize(NSSize(width: 1_180, height: 760))
    window.minSize = NSSize(width: 860, height: 560)
    window.title = "NativeXiangqi — \(NativeXiangqiDocument.baseRuleModeTitle)"
    window.toolbar = toolbar
    window.isReleasedWhenClosed = false
    super.init(window: window)
    toolbar.delegate = self
    boardController.boardView.delegate = self
    window.initialFirstResponder = boardController.boardView
    window.makeFirstResponder(boardController.boardView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  func render(
    boardPresentation: XiangqiBoardPresentation,
    statusText: String,
    outlineRoot: Any?,
    currentNodeID: UInt32?,
    isInteractionActive: Bool
  ) {
    boardController.boardView.setPresentation(boardPresentation)
    boardController.setStatus(statusText)
    boardController.boardView.acceptsBoardInput = !isInteractionActive
    analysisController.setCandidates(
      boardPresentation.fakeCandidates, ruleModeTitle: NativeXiangqiDocument.baseRuleModeTitle)
    variationController.reload(currentNodeID: currentNodeID)
    window?.toolbar?.validateVisibleItems()
  }

  func boardView(_ boardView: XiangqiBoardView, didRequestSquare square: UInt8) {
    nativeDocument?.requestSquare(square)
  }

  func boardViewDidRequestCancel(_ boardView: XiangqiBoardView) {
    nativeDocument?.cancelSelection()
  }

  func boardView(
    _ boardView: XiangqiBoardView, didRequestNavigation navigation: XiangqiBoardNavigation
  ) {
    switch navigation {
    case .previous:
      nativeDocument?.requestHistoryPrevious()
    case .next:
      nativeDocument?.requestHistoryNext()
    case .first:
      nativeDocument?.requestNavigateToStart()
    case .last:
      nativeDocument?.requestNavigateToLastDisplayedNode()
    }
  }

  @objc func undoMove(_ sender: Any?) {
    nativeDocument?.performNativeUndo()
  }

  @objc func redoMove(_ sender: Any?) {
    nativeDocument?.performNativeRedo()
  }

  @objc func navigatePrevious(_ sender: Any?) {
    nativeDocument?.requestHistoryPrevious()
  }

  @objc func navigateNext(_ sender: Any?) {
    nativeDocument?.requestHistoryNext()
  }

  @objc func flipBoard(_ sender: Any?) {
    nativeDocument?.flipBoard()
  }

  @objc func editCurrentAnnotation(_ sender: Any?) {
    guard let nativeDocument, let window else {
      return
    }
    Task { @MainActor [weak nativeDocument, weak window] in
      guard let nativeDocument, let window else {
        return
      }
      do {
        let current = try await nativeDocument.currentAnnotation()
        let field = NSTextField(string: current)
        field.placeholderString = "当前变例节点注释（最多 64 KiB）"
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        let alert = NSAlert()
        alert.messageText = "编辑当前节点注释"
        alert.informativeText = "注释由 Rust 绑定到当前变例节点；保存后可通过原生撤销恢复。"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in
          guard response == .alertFirstButtonReturn else {
            return
          }
          nativeDocument.setCurrentAnnotation(field.stringValue)
        }
      } catch {
        nativeDocument.presentRecoverableError(error)
      }
    }
  }

  func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    guard let action = item.action else {
      return true
    }
    switch action {
    case #selector(undoMove(_:)):
      return nativeDocument?.canUndoMove == true
    case #selector(redoMove(_:)):
      return nativeDocument?.canRedoMove == true
    case #selector(navigatePrevious(_:)):
      return nativeDocument?.canNavigatePrevious == true
    case #selector(navigateNext(_:)):
      return nativeDocument?.canNavigateNext == true
    case #selector(flipBoard(_:)):
      return nativeDocument?.isInteractionActive == false
    case #selector(editCurrentAnnotation(_:)):
      return nativeDocument?.isInteractionActive == false
    default:
      return true
    }
  }

  private static func makeToolbar() -> NSToolbar {
    let toolbar = NSToolbar(identifier: "NativeXiangqiDocumentToolbar")
    toolbar.displayMode = .iconAndLabel
    toolbar.allowsUserCustomization = false
    toolbar.autosavesConfiguration = false
    return toolbar
  }
}

extension NativeXiangqiDocumentWindowController: NSToolbarDelegate {
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.nxqUndo, .nxqRedo, .flexibleSpace, .navigatePrevious, .navigateNext, .flipBoard]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.nxqUndo, .nxqRedo, .flexibleSpace, .navigatePrevious, .navigateNext, .flipBoard]
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    switch itemIdentifier {
    case .nxqUndo:
      item.label = "撤销"
      item.toolTip = "撤销上一步"
      item.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "撤销")
      item.target = self
      item.action = #selector(undoMove(_:))
    case .nxqRedo:
      item.label = "重做"
      item.toolTip = "重做当前分支"
      item.image = NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "重做")
      item.target = self
      item.action = #selector(redoMove(_:))
    case .navigatePrevious:
      item.label = "上一步"
      item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "上一步")
      item.target = self
      item.action = #selector(navigatePrevious(_:))
    case .navigateNext:
      item.label = "下一步"
      item.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "下一步")
      item.target = self
      item.action = #selector(navigateNext(_:))
    case .flipBoard:
      item.label = "翻转棋盘"
      item.image = NSImage(
        systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "翻转棋盘")
      item.target = self
      item.action = #selector(flipBoard(_:))
    default:
      return nil
    }
    return item
  }
}

extension NSToolbarItem.Identifier {
  fileprivate static let nxqUndo = NSToolbarItem.Identifier("org.nativexiangqi.undo")
  fileprivate static let nxqRedo = NSToolbarItem.Identifier("org.nativexiangqi.redo")
  fileprivate static let navigatePrevious = NSToolbarItem.Identifier(
    "org.nativexiangqi.navigatePrevious")
  fileprivate static let navigateNext = NSToolbarItem.Identifier("org.nativexiangqi.navigateNext")
  fileprivate static let flipBoard = NSToolbarItem.Identifier("org.nativexiangqi.flipBoard")
}

@MainActor
private final class XiangqiBoardContainerViewController: NSViewController {
  let boardView = XiangqiBoardView(frame: .zero)
  private let statusLabel = NSTextField(wrappingLabelWithString: "正在准备本地棋局…")

  override func loadView() {
    let container = NSView()
    boardView.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.alignment = .center
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.maximumNumberOfLines = 2
    container.addSubview(boardView)
    container.addSubview(statusLabel)
    NSLayoutConstraint.activate([
      boardView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      boardView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
      boardView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
      boardView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
      statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
      statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
    ])
    view = container
  }

  func setStatus(_ status: String) {
    statusLabel.stringValue = status
  }
}

@MainActor
private final class AnalysisPlaceholderViewController: NSViewController {
  private let ruleModeLabel = NSTextField(labelWithString: NativeXiangqiDocument.baseRuleModeTitle)
  private let detailLabel = NSTextField(wrappingLabelWithString: "引擎分析尚未集成。本面板只显示有界的本地交互提示。")
  private let candidatesLabel = NSTextField(wrappingLabelWithString: "未选择棋子。")

  override func loadView() {
    let stack = NSStackView(views: [ruleModeLabel, detailLabel, candidatesLabel])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    ruleModeLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    detailLabel.textColor = .secondaryLabelColor
    candidatesLabel.textColor = .secondaryLabelColor
    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
    ])
    view = container
  }

  func setCandidates(_ candidates: [XiangqiBoardCandidate], ruleModeTitle: String) {
    ruleModeLabel.stringValue = ruleModeTitle
    if candidates.isEmpty {
      candidatesLabel.stringValue = "未选择棋子。"
    } else {
      candidatesLabel.stringValue = candidates.map { "\($0.title)\n\($0.detail)" }.joined(
        separator: "\n\n")
    }
  }
}

@MainActor
private final class VariationOutlineViewController: NSViewController, NSOutlineViewDataSource,
  NSOutlineViewDelegate
{
  private weak var nativeDocument: NativeXiangqiDocument?
  private let outlineView = NSOutlineView()
  private let scrollView = NSScrollView()

  init(document: NativeXiangqiDocument) {
    nativeDocument = document
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override func loadView() {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("variation"))
    column.title = "变例"
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column
    outlineView.headerView = nil
    outlineView.delegate = self
    outlineView.dataSource = self
    outlineView.rowSizeStyle = .medium
    outlineView.selectionHighlightStyle = .regular
    scrollView.documentView = outlineView
    scrollView.hasVerticalScroller = true
    view = scrollView
  }

  func reload(currentNodeID: UInt32?) {
    outlineView.reloadData()
    if let root = nativeDocument?.outlineRoot {
      outlineView.expandItem(root)
    }
    if let currentNodeID,
      let entry = nativeDocument?.outlineEntry(for: currentNodeID)
    {
      let row = outlineView.row(forItem: entry)
      if row >= 0 {
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      }
    }
  }

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    children(of: item).count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    children(of: item)[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    !children(of: item).isEmpty
  }

  func outlineView(
    _ outlineView: NSOutlineView,
    viewFor tableColumn: NSTableColumn?,
    item: Any
  ) -> NSView? {
    guard let entry = item as? XiangqiVariationDisplayEntry else {
      return nil
    }
    let identifier = NSUserInterfaceItemIdentifier("variationCell")
    let cell =
      outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
      ?? NSTableCellView()
    cell.identifier = identifier
    let label: NSTextField
    if let existing = cell.textField {
      label = existing
    } else {
      label = NSTextField(labelWithString: "")
      label.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(label)
      cell.textField = label
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
        label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
    }
    label.stringValue = entry.title
    return cell
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    let row = outlineView.selectedRow
    guard row >= 0,
      let entry = outlineView.item(atRow: row) as? XiangqiVariationDisplayEntry,
      entry.nodeID != nativeDocument?.displayedCurrentNodeID
    else {
      return
    }
    nativeDocument?.requestNavigate(to: entry.nodeID)
  }

  private func children(of item: Any?) -> [XiangqiVariationDisplayEntry] {
    guard let nativeDocument else {
      return []
    }
    if item == nil {
      return nativeDocument.outlineRoot.map { [$0] } ?? []
    }
    guard let entry = item as? XiangqiVariationDisplayEntry else {
      return []
    }
    return entry.childNodeIDs.compactMap(nativeDocument.outlineEntry(for:))
  }
}
