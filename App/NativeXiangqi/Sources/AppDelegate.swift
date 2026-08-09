import AppKit
import XiangqiDocumentKit
import os

private let applicationLogger = Logger(subsystem: "org.nativexiangqi.app", category: "startup")

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    installMainMenu()
    newInMemoryDocument(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  @objc private func newInMemoryDocument(_ sender: Any?) {
    let document = NativeXiangqiDocument()
    NSDocumentController.shared.addDocument(document)
    document.makeWindowControllers()
    document.showWindows()
    applicationLogger.info("Created an in-memory local Xiangqi document")
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
      title: "新建本地棋局", action: #selector(newInMemoryDocument(_:)), keyEquivalent: "n")
    newItem.target = self
    menu.addItem(newItem)
    let saveItem = NSMenuItem(title: "保存（T040 前不可用）", action: nil, keyEquivalent: "s")
    saveItem.isEnabled = false
    menu.addItem(saveItem)
    item.submenu = menu
    return item
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
