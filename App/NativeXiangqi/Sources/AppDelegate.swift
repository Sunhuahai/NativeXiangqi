import AppKit
import PikafishKit
import XiangqiDocumentKit
import os

private let applicationLogger = Logger(subsystem: "org.nativexiangqi.app", category: "startup")

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let recentDocumentsMenu = NSMenu(title: "打开最近使用")
  private let localVersionsMenu = NSMenu(title: "还原本地历史版本")
  private let localVersionCatalog = NativeXiangqiLocalVersionCatalog()
  private var localVersionDescriptors: [NativeXiangqiLocalVersionDescriptor] = []
  private var localVersionsSourceURL: URL?
  private var localVersionsRefreshTask: Task<Void, Never>?
  private var analysisCoordinator: NativeXiangqiAnalysisCoordinator?
  private var analysisCache: AnalysisCache?
  private var memoryPressureSource: DispatchSourceMemoryPressure?
  private var lowPowerObserver: NSObjectProtocol?

  func applicationDidFinishLaunching(_ notification: Notification) {
    installMainMenu()
    installAnalysisInfrastructure()
    newInMemoryDocument(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Bounded, best-effort helper reclaim. Document operations never wait on
    // this path.
    let coordinator = analysisCoordinator
    Task {
      await coordinator?.shutdown()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  @objc private func newInMemoryDocument(_ sender: Any?) {
    do {
      _ = try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
      applicationLogger.info("Created an in-memory local Xiangqi document")
    } catch {
      presentApplicationError(error)
    }
  }

  @objc private func newDocumentFromFEN(_ sender: Any?) {
    promptForText(
      title: "从 FEN 新建棋局",
      message: "FEN 会先由 Rust 严格验证；失败不会创建可编辑棋局。",
      placeholder: "初始 FEN"
    ) { [weak self] fen in
      guard let self else {
        return
      }
      Task { @MainActor in
        do {
          try await NativeXiangqiDocument.validateInitialFEN(fen)
          let document = NativeXiangqiDocument.newDocument(initialFEN: fen)
          NSDocumentController.shared.addDocument(document)
          document.makeWindowControllers()
          document.showWindows()
        } catch {
          self.presentApplicationError(error)
        }
      }
    }
  }

  @objc private func replaceInitialFEN(_ sender: Any?) {
    guard let document = activeDocument else {
      return
    }
    confirm(
      title: "替换初始局面？",
      message: "这会在验证成功后移除当前变例和注释。此操作可保存，但不能从现有变例撤销。"
    ) { [weak self, weak document] in
      guard let self, let document else {
        return
      }
      self.promptForText(
        title: "替换初始 FEN",
        message: "输入经过 Rust 的严格 FEN 验证后才会替换当前记录。",
        placeholder: "新的初始 FEN"
      ) { fen in
        document.replaceInitialPosition(withFEN: fen)
      }
    }
  }

  @objc private func exportInitialFEN(_ sender: Any?) {
    exportFEN(.initial)
  }

  @objc private func exportCurrentFEN(_ sender: Any?) {
    exportFEN(.current)
  }

  @objc private func importUCCIMainline(_ sender: Any?) {
    guard let document = activeDocument else {
      return
    }
    confirm(
      title: "导入并替换 UCCI 主线？",
      message: "这会在验证成功后替换当前变例和注释；错误会保留现有记录并报告失败手数。"
    ) { [weak self, weak document] in
      guard let self, let document else {
        return
      }
      self.promptForText(
        title: "导入 UCCI 主线",
        message: "使用空白分隔的 UCCI/ICCS 着法；完整主线会先在 Rust 候选中事务验证。",
        placeholder: "例如：b2b3 b7b6"
      ) { mainline in
        document.replaceRecord(withUCCIMainline: mainline)
      }
    }
  }

  @objc private func exportUCCIMainline(_ sender: Any?) {
    guard let document = activeDocument else {
      return
    }
    Task { @MainActor [weak document] in
      guard let document else {
        return
      }
      do {
        try copyToPasteboard(await document.exportUCCIMainline(), document: document)
      } catch {
        document.presentRecoverableError(error)
      }
    }
  }

  private var activeDocument: NativeXiangqiDocument? {
    NSDocumentController.shared.currentDocument as? NativeXiangqiDocument
  }

  // MARK: - Analysis infrastructure (T060)

  private func installAnalysisInfrastructure() {
    Task { @MainActor in
      let verifier = NativeXiangqiEngineAssetVerifier()
      let assets = await verifier.verify()
      let cacheDirectory: URL
      if let base = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first {
        cacheDirectory = base.appendingPathComponent("org.nativexiangqi.app", isDirectory: true)
      } else {
        cacheDirectory = FileManager.default.temporaryDirectory
      }
      let cache = try? AnalysisCache(
        configuration: AnalysisCacheConfiguration(directory: cacheDirectory))
      self.analysisCache = cache
      let coordinator = NativeXiangqiAnalysisCoordinator(
        configuration: NativeXiangqiAnalysisCoordinator.Configuration(
          totalPhysicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
          activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount
        ),
        assets: assets,
        cache: cache
      )
      self.analysisCoordinator = coordinator
      NativeXiangqiDocument.sharedAnalysisCoordinator = coordinator
      for document in NSDocumentController.shared.documents {
        if let document = document as? NativeXiangqiDocument {
          document.configureAnalysisService(coordinator)
        }
      }
      self.installLifecycleObservers(coordinator: coordinator)
    }
  }

  private func installLifecycleObservers(coordinator: NativeXiangqiAnalysisCoordinator) {
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical], queue: .main)
    source.setEventHandler { [weak coordinator] in
      guard let coordinator else {
        return
      }
      Task {
        await coordinator.noteMemoryPressure()
      }
    }
    source.resume()
    memoryPressureSource = source

    lowPowerObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
      object: nil,
      queue: .main
    ) { [weak coordinator] _ in
      guard let coordinator else {
        return
      }
      Task {
        await coordinator.noteLowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)
      }
    }
  }

  private func presentApplicationError(_ error: Error) {
    let alert = NSAlert(error: error)
    alert.runModal()
  }

  @objc private func restoreSavedDocument(_ sender: Any?) {
    guard let document = activeDocument else {
      return
    }
    confirm(
      title: "还原到已保存版本？",
      message: "这会替换当前棋谱，并丢弃尚未保存的走棋、变例和注释。"
    ) { [weak document] in
      guard let document else {
        return
      }
      _ = document.restoreSavedDocument(discardingUnsavedChanges: true)
    }
  }

  @objc private func restoreLocalVersion(_ sender: NSMenuItem) {
    guard let descriptor = sender.representedObject as? NativeXiangqiLocalVersionDescriptor,
      let document = activeDocument
    else {
      return
    }
    confirm(
      title: "还原本地历史版本？",
      message: "这会替换当前棋谱，并把所选历史版本安全写回当前文件。"
    ) { [weak document] in
      guard let document else {
        return
      }
      _ = document.restoreLocalVersion(descriptor, discardingUnsavedChanges: true)
    }
  }

  @objc private func openRecentDocument(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else {
      return
    }
    NSDocumentController.shared.openDocument(withContentsOf: url, display: true) {
      [weak self] _, _, error in
      guard let error else {
        return
      }
      self?.presentApplicationError(error)
    }
  }

  private func exportFEN(_ scope: NativeXiangqiFENExportScope) {
    guard let document = activeDocument else {
      return
    }
    Task { @MainActor [weak document] in
      guard let document else {
        return
      }
      do {
        try copyToPasteboard(await document.exportFEN(scope), document: document)
      } catch {
        document.presentRecoverableError(error)
      }
    }
  }

  private func copyToPasteboard(_ text: String, document: NativeXiangqiDocument) throws {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      throw NativeXiangqiDocumentReadinessError.unavailable
    }
    let alert = NSAlert()
    alert.messageText = "已复制到剪贴板"
    alert.informativeText = "导出不会修改棋谱或文档状态。"
    alert.addButton(withTitle: "好")
    if let window = document.windowControllers.first?.window {
      alert.beginSheetModal(for: window)
    }
  }

  private func promptForText(
    title: String,
    message: String,
    placeholder: String,
    completion: @escaping (String) -> Void
  ) {
    let field = NSTextField(string: "")
    field.placeholderString = placeholder
    field.frame = NSRect(x: 0, y: 0, width: 460, height: 24)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.accessoryView = field
    alert.addButton(withTitle: "继续")
    alert.addButton(withTitle: "取消")
    present(alert) { response in
      guard response == .alertFirstButtonReturn else {
        return
      }
      completion(field.stringValue)
    }
  }

  private func confirm(title: String, message: String, completion: @escaping () -> Void) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "继续")
    alert.addButton(withTitle: "取消")
    present(alert) { response in
      guard response == .alertFirstButtonReturn else {
        return
      }
      completion()
    }
  }

  private func present(
    _ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void
  ) {
    if let window = activeDocument?.windowControllers.first?.window {
      alert.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(alert.runModal())
    }
  }

  private func installMainMenu() {
    let mainMenu = NSMenu(title: "NativeXiangqi")
    mainMenu.addItem(applicationMenu())
    mainMenu.addItem(fileMenu())
    mainMenu.addItem(editMenu())
    mainMenu.addItem(gameMenu())
    NSApplication.shared.mainMenu = mainMenu
  }

  private func applicationMenu() -> NSMenuItem {
    let item = NSMenuItem(title: "NativeXiangqi", action: nil, keyEquivalent: "")
    let menu = NSMenu(title: "NativeXiangqi")
    menu.addItem(
      withTitle: "退出 NativeXiangqi",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    item.submenu = menu
    return item
  }

  private func fileMenu() -> NSMenuItem {
    let item = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
    let menu = NSMenu(title: "文件")
    let newItem = NSMenuItem(
      title: "新建棋局", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
    newItem.target = NSDocumentController.shared
    menu.addItem(newItem)
    let openItem = NSMenuItem(
      title: "打开…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
    openItem.target = NSDocumentController.shared
    menu.addItem(openItem)
    let recentItem = NSMenuItem(title: "打开最近使用", action: nil, keyEquivalent: "")
    recentDocumentsMenu.delegate = self
    let recentMenu = recentDocumentsMenu
    let clearRecentItem = NSMenuItem(
      title: "清除最近使用", action: #selector(NSDocumentController.clearRecentDocuments(_:)),
      keyEquivalent: "")
    clearRecentItem.target = NSDocumentController.shared
    recentMenu.addItem(clearRecentItem)
    recentItem.submenu = recentMenu
    menu.addItem(recentItem)
    menu.addItem(.separator())
    let saveItem = NSMenuItem(
      title: "保存", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
    saveItem.keyEquivalentModifierMask = [.command]
    menu.addItem(saveItem)
    let saveAsItem = NSMenuItem(
      title: "另存为…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "s")
    saveAsItem.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(saveAsItem)
    let revertItem = NSMenuItem(
      title: "还原到已保存版本", action: #selector(restoreSavedDocument(_:)), keyEquivalent: "")
    revertItem.target = self
    menu.addItem(revertItem)
    let versionsItem = NSMenuItem(title: "还原本地历史版本", action: nil, keyEquivalent: "")
    localVersionsMenu.delegate = self
    versionsItem.submenu = localVersionsMenu
    menu.addItem(versionsItem)
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "从 FEN 新建…", action: #selector(newDocumentFromFEN(_:)), keyEquivalent: "")
    menu.addItem(
      withTitle: "替换初始 FEN…", action: #selector(replaceInitialFEN(_:)), keyEquivalent: "")
    menu.addItem(
      withTitle: "复制初始 FEN", action: #selector(exportInitialFEN(_:)), keyEquivalent: "")
    menu.addItem(
      withTitle: "复制当前 FEN", action: #selector(exportCurrentFEN(_:)), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "导入并替换 UCCI 主线…", action: #selector(importUCCIMainline(_:)), keyEquivalent: "")
    menu.addItem(
      withTitle: "复制当前 UCCI 主线", action: #selector(exportUCCIMainline(_:)), keyEquivalent: "")
    item.submenu = menu
    return item
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    if menu === recentDocumentsMenu {
      rebuildRecentDocumentsMenu(menu)
    } else if menu === localVersionsMenu {
      rebuildLocalVersionsMenu(menu)
    }
  }

  private func rebuildRecentDocumentsMenu(_ menu: NSMenu) {
    menu.removeAllItems()
    var addedRecent = false
    for url in NSDocumentController.shared.recentDocumentURLs.lazy.prefix(20) {
      addedRecent = true
      let item = NSMenuItem(
        title: url.lastPathComponent, action: #selector(openRecentDocument(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = url
      menu.addItem(item)
    }
    if addedRecent {
      menu.addItem(.separator())
    }
    let clear = NSMenuItem(
      title: "清除最近使用",
      action: #selector(NSDocumentController.clearRecentDocuments(_:)),
      keyEquivalent: ""
    )
    clear.target = NSDocumentController.shared
    menu.addItem(clear)
  }

  private func rebuildLocalVersionsMenu(_ menu: NSMenu) {
    menu.removeAllItems()
    guard let url = activeDocument?.fileURL else {
      invalidateLocalVersionsCache()
      let unavailable = NSMenuItem(title: "请先保存棋谱", action: nil, keyEquivalent: "")
      unavailable.isEnabled = false
      menu.addItem(unavailable)
      return
    }
    if localVersionsSourceURL != url {
      refreshLocalVersions(for: url)
    }
    guard localVersionsSourceURL == url,
      !(localVersionsRefreshTask != nil && localVersionDescriptors.isEmpty)
    else {
      let loading = NSMenuItem(title: "正在读取本地历史版本…", action: nil, keyEquivalent: "")
      loading.isEnabled = false
      menu.addItem(loading)
      return
    }
    for descriptor in localVersionDescriptors {
      let item = NSMenuItem(
        title: descriptor.title, action: #selector(restoreLocalVersion(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = descriptor
      menu.addItem(item)
    }
    if localVersionDescriptors.isEmpty {
      let unavailable = NSMenuItem(title: "没有可用的本地历史版本", action: nil, keyEquivalent: "")
      unavailable.isEnabled = false
      menu.addItem(unavailable)
    }
  }

  private func refreshLocalVersions(for url: URL) {
    guard localVersionsSourceURL != url else {
      return
    }
    localVersionsRefreshTask?.cancel()
    localVersionsSourceURL = url
    localVersionDescriptors.removeAll(keepingCapacity: false)
    let catalog = localVersionCatalog
    localVersionsRefreshTask = Task { @MainActor [weak self, catalog] in
      let descriptors = await catalog.descriptors(for: url)
      guard !Task.isCancelled,
        let self,
        self.localVersionsSourceURL == url,
        self.activeDocument?.fileURL == url
      else {
        return
      }
      self.localVersionDescriptors = descriptors
      self.localVersionsRefreshTask = nil
      self.localVersionsMenu.update()
    }
  }

  private func invalidateLocalVersionsCache() {
    localVersionsRefreshTask?.cancel()
    localVersionsRefreshTask = nil
    localVersionsSourceURL = nil
    localVersionDescriptors.removeAll(keepingCapacity: false)
  }

  private func editMenu() -> NSMenuItem {
    let item = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
    let menu = NSMenu(title: "编辑")
    let undoItem = NSMenuItem(
      title: "撤销走棋", action: NSSelectorFromString("undoMove:"), keyEquivalent: "z")
    undoItem.keyEquivalentModifierMask = [.command]
    menu.addItem(undoItem)
    let redoItem = NSMenuItem(
      title: "重做走棋", action: NSSelectorFromString("redoMove:"), keyEquivalent: "z")
    redoItem.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(redoItem)
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "编辑当前节点注释…", action: NSSelectorFromString("editCurrentAnnotation:"),
      keyEquivalent: "")
    item.submenu = menu
    return item
  }

  private func gameMenu() -> NSMenuItem {
    let item = NSMenuItem(title: "对局", action: nil, keyEquivalent: "")
    let menu = NSMenu(title: "对局")
    menu.addItem(
      withTitle: "上一步", action: NSSelectorFromString("navigatePrevious:"), keyEquivalent: "[")
    menu.addItem(
      withTitle: "下一步", action: NSSelectorFromString("navigateNext:"), keyEquivalent: "]")
    menu.addItem(.separator())
    menu.addItem(withTitle: "翻转棋盘", action: NSSelectorFromString("flipBoard:"), keyEquivalent: "f")
    item.submenu = menu
    return item
  }
}
