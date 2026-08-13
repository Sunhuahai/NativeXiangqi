import AppKit
import PikafishKit
import XiangqiCoreBinary
import XiangqiUI

@MainActor
final class NativeXiangqiDocumentWindowController: NSWindowController, XiangqiBoardViewDelegate,
  NSUserInterfaceValidations
{
  private weak var nativeDocument: NativeXiangqiDocument?
  private let variationController: VariationOutlineViewController
  private let boardController: XiangqiBoardContainerViewController
  private let analysisController: AnalysisViewController

  init(document: NativeXiangqiDocument) {
    nativeDocument = document
    variationController = VariationOutlineViewController(document: document)
    boardController = XiangqiBoardContainerViewController()
    analysisController = AnalysisViewController(document: document)

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
    window.delegate = self
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
    isInteractionActive: Bool,
    analysisPresentation: NativeXiangqiAnalysisPresentation
  ) {
    boardController.boardView.setPresentation(boardPresentation)
    boardController.setStatus(statusText)
    boardController.boardView.acceptsBoardInput = !isInteractionActive
    analysisController.render(analysisPresentation)
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
private final class AnalysisViewController: NSViewController, NSTableViewDataSource,
  NSTableViewDelegate
{
  private weak var nativeDocument: NativeXiangqiDocument?
  private let ruleModeLabel = NSTextField(labelWithString: NativeXiangqiDocument.baseRuleModeTitle)
  private let statusLabel = NSTextField(wrappingLabelWithString: "引擎分析未启动。")
  private let toggleButton = NSButton(
    title: NativeXiangqiLocalized.startAnalysis, target: nil, action: nil)
  private let retryButton = NSButton(
    title: NativeXiangqiLocalized.retryAnalysis, target: nil, action: nil)
  private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let perspectivePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let aiPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let tableView = NSTableView()
  private var currentRows: [NativeXiangqiCandidateRow] = []
  private let adjudicationLabel = NSTextField(wrappingLabelWithString: "")
  private let adjudicationButton = NSButton(
    title: NativeXiangqiLocalized.copyAdjudication, target: nil, action: nil)
  private var currentAdjudicationText: String?

  init(document: NativeXiangqiDocument) {
    nativeDocument = document
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override func loadView() {
    toggleButton.target = self
    toggleButton.action = #selector(toggleAnalysis(_:))
    retryButton.target = self
    retryButton.action = #selector(retryAnalysis(_:))
    retryButton.isHidden = true
    presetPopup.addItems(withTitles: [
      NativeXiangqiLocalized.presetLight, NativeXiangqiLocalized.presetStandard,
      NativeXiangqiLocalized.presetDeep,
    ])
    presetPopup.selectItem(at: 1)
    presetPopup.target = self
    presetPopup.action = #selector(presetChanged(_:))
    perspectivePopup.addItems(withTitles: [
      NativeXiangqiLocalized.perspectiveRed, NativeXiangqiLocalized.perspectiveSideToMove,
    ])
    perspectivePopup.selectItem(at: 0)
    perspectivePopup.target = self
    perspectivePopup.action = #selector(perspectiveChanged(_:))
    aiPopup.addItems(withTitles: [
      NativeXiangqiLocalized.aiOff, NativeXiangqiLocalized.aiRed, NativeXiangqiLocalized.aiBlack,
    ])
    aiPopup.selectItem(at: 0)
    aiPopup.target = self
    aiPopup.action = #selector(aiChanged(_:))

    let ruleRow = NSStackView(views: [ruleModeLabel])
    ruleRow.orientation = .horizontal
    let controlsRow = NSStackView(views: [toggleButton, retryButton])
    controlsRow.orientation = .horizontal
    controlsRow.spacing = 8
    let settingsRow = NSStackView(views: [
      labeledPopup(title: NativeXiangqiLocalized.presetLabel, popup: presetPopup),
      labeledPopup(title: NativeXiangqiLocalized.perspectiveLabel, popup: perspectivePopup),
      labeledPopup(title: NativeXiangqiLocalized.aiLabel, popup: aiPopup),
    ])
    settingsRow.orientation = .horizontal
    settingsRow.spacing = 12

    let rankColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rank"))
    rankColumn.title = "#"
    rankColumn.width = 30
    let moveColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("move"))
    moveColumn.title = "着法"
    moveColumn.width = 52
    let scoreColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("score"))
    scoreColumn.title = "分数"
    scoreColumn.width = 70
    let depthColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("depth"))
    depthColumn.title = "深度"
    depthColumn.width = 44
    let nodesColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("nodes"))
    nodesColumn.title = "节点"
    nodesColumn.width = 72
    let npsColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("nps"))
    npsColumn.title = "NPS"
    npsColumn.width = 72
    let pvColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pv"))
    pvColumn.title = "PV"
    pvColumn.width = 180
    for column in [
      rankColumn, moveColumn, scoreColumn, depthColumn, nodesColumn, npsColumn, pvColumn,
    ] {
      tableView.addTableColumn(column)
    }
    tableView.headerView = NSTableHeaderView()
    tableView.dataSource = self
    tableView.delegate = self
    tableView.rowSizeStyle = .small
    tableView.usesAlternatingRowBackgroundColors = true
    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true

    let stack = NSStackView(views: [
      ruleRow, controlsRow, settingsRow, scrollView, statusLabel, adjudicationLabel,
      adjudicationButton,
    ])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    adjudicationButton.target = self
    adjudicationButton.action = #selector(copyAdjudication(_:))
    adjudicationButton.isHidden = true
    adjudicationLabel.textColor = .secondaryLabelColor
    adjudicationLabel.maximumNumberOfLines = 8
    adjudicationLabel.isHidden = true
    ruleModeLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.maximumNumberOfLines = 3
    for popup in [presetPopup, perspectivePopup, aiPopup] {
      popup.translatesAutoresizingMaskIntoConstraints = false
    }
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
      scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
      scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
    ])
    view = container
  }

  private func labeledPopup(title: String, popup: NSPopUpButton) -> NSStackView {
    let label = NSTextField(labelWithString: title)
    label.textColor = .secondaryLabelColor
    label.font = .systemFont(ofSize: 11)
    let stack = NSStackView(views: [label, popup])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    return stack
  }

  func render(_ presentation: NativeXiangqiAnalysisPresentation) {
    ruleModeLabel.stringValue = presentation.baseRuleModeTitle
    currentRows = presentation.candidateRows
    tableView.reloadData()
    refreshAdjudication()
    let (title, enabled) = stateText(presentation)
    statusLabel.stringValue = title
    toggleButton.title =
      presentation.state == .searching || presentation.state == .starting
      ? "暂停分析" : "开始分析"
    toggleButton.isEnabled = enabled
    retryButton.isHidden =
      presentation.state != .failed(reason: "placeholder")
      && !isFailed(presentation.state)
  }

  private func isFailed(_ state: NativeXiangqiAnalysisState) -> Bool {
    if case .failed = state {
      return true
    }
    return false
  }

  private func stateText(_ presentation: NativeXiangqiAnalysisPresentation) -> (String, Bool) {
    switch presentation.state {
    case .idle:
      return (NativeXiangqiLocalized.statusIdle + presentation.baseRuleModeTitle, true)
    case .starting:
      return (NativeXiangqiLocalized.statusStarting, false)
    case .searching:
      return (NativeXiangqiLocalized.statusSearching + presentation.baseRuleModeTitle, false)
    case .cacheHit:
      return (NativeXiangqiLocalized.statusCacheHit + presentation.baseRuleModeTitle, true)
    case .finished:
      return (NativeXiangqiLocalized.statusFinished + presentation.baseRuleModeTitle, true)
    case .stopped:
      return (NativeXiangqiLocalized.statusStopped + presentation.baseRuleModeTitle, true)
    case .failed(let reason):
      return ("\(reason) 可使用“重试”。", true)
    case .engineUnavailable:
      return (NativeXiangqiLocalized.statusEngineUnavailable, false)
    }
  }

  // MARK: Actions

  @objc private func toggleAnalysis(_ sender: Any?) {
    nativeDocument?.toggleAnalysis()
  }

  @objc private func retryAnalysis(_ sender: Any?) {
    nativeDocument?.retryAnalysis()
  }

  @objc private func presetChanged(_ sender: Any?) {
    let presets: [PikafishResourcePreset] = [.light, .standard, .deep]
    let index = presetPopup.indexOfSelectedItem
    guard presets.indices.contains(index) else {
      return
    }
    nativeDocument?.selectAnalysisPreset(presets[index])
  }

  @objc private func perspectiveChanged(_ sender: Any?) {
    switch perspectivePopup.indexOfSelectedItem {
    case 1:
      nativeDocument?.selectAnalysisPerspective(.sideToMove)
    default:
      nativeDocument?.selectAnalysisPerspective(.red)
    }
  }

  @objc private func aiChanged(_ sender: Any?) {
    switch aiPopup.indexOfSelectedItem {
    case 1:
      nativeDocument?.selectAISide(.red)
    case 2:
      nativeDocument?.selectAISide(.black)
    default:
      nativeDocument?.selectAISide(nil)
    }
  }

  private func refreshAdjudication() {
    guard let document = nativeDocument else {
      return
    }
    Task { @MainActor [weak self, weak document] in
      guard let self, let document else {
        return
      }
      let text = await document.adjudicationText()
      guard let text else {
        self.adjudicationLabel.isHidden = true
        self.adjudicationButton.isHidden = true
        self.currentAdjudicationText = nil
        return
      }
      self.currentAdjudicationText = text
      self.adjudicationLabel.stringValue = text
      self.adjudicationLabel.isHidden = false
      self.adjudicationButton.isHidden = false
    }
  }

  @objc private func copyAdjudication(_ sender: Any?) {
    guard let text = currentAdjudicationText else {
      return
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  // MARK: Table

  func numberOfRows(in tableView: NSTableView) -> Int {
    currentRows.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard let column = tableColumn, currentRows.indices.contains(row) else {
      return nil
    }
    let row = currentRows[row]
    let identifier = column.identifier.rawValue
    let text: String
    switch identifier {
    case "rank":
      text = "\(row.rank)"
    case "move":
      text = row.move
    case "score":
      text = scoreText(row.evaluation)
    case "depth":
      text = row.depth.map { "\($0)" } ?? "—"
    case "nodes":
      text = row.nodes.map { "\($0)" } ?? "—"
    case "nps":
      text = row.nps.map { "\($0)" } ?? "—"
    case "pv":
      text = row.pv.joined(separator: " ")
    default:
      text = ""
    }
    let cell = NSTextField(labelWithString: text)
    cell.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    cell.lineBreakMode = .byTruncatingTail
    return cell
  }

  private func scoreText(_ evaluation: PikafishDisplayedEvaluation?) -> String {
    guard let evaluation else {
      return "—"
    }
    let value: String
    if let cp = evaluation.centipawnsFromRedPerspective {
      value = cp > 0 ? "+\(cp)" : "\(cp)"
    } else if let matePly = evaluation.matePly {
      let direction: String
      if let redMates = evaluation.redMates {
        direction = redMates ? "红杀" : "黑杀"
      } else {
        direction = evaluation.sideToMove == .red ? "红杀" : "黑杀"
      }
      value = "\(direction)\(matePly)"
    } else {
      value = "—"
    }
    if let bound = evaluation.bound {
      return "\(value)\(bound == .lowerbound ? "≥" : bound == .upperbound ? "≤" : "")"
    }
    return value
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

extension NativeXiangqiDocumentWindowController: NSWindowDelegate {
  func windowDidMiniaturize(_ notification: Notification) {
    nativeDocument?.noteAnalysisWindowVisibility(false)
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    nativeDocument?.noteAnalysisWindowVisibility(true)
  }

  func windowDidChangeOcclusionState(_ notification: Notification) {
    let visible = window?.occlusionState.contains(.visible) == true
    nativeDocument?.noteAnalysisWindowVisibility(visible)
  }
}
