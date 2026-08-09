import AppKit
import XiangqiCoreBinary
import os

private let applicationLogger = Logger(subsystem: "org.nativexiangqi.app", category: "startup")

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let titleLabel = NSTextField(labelWithString: "NativeXiangqi")
    titleLabel.alignment = .center
    titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)

    let statusLabel = NSTextField(wrappingLabelWithString: startupStatus())
    statusLabel.alignment = .center
    statusLabel.textColor = .secondaryLabelColor

    let stack = NSStackView(views: [titleLabel, statusLabel])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 12

    let contentView = NSView()
    contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 32),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -32),
    ])

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.center()
    window.contentView = contentView
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 560, height: 400)
    window.title = "NativeXiangqi"
    window.makeKeyAndOrderFront(nil)

    self.window = window
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  private func startupStatus() -> String {
    #if DEBUG
      switch XiangqiCoreBinary.validateABIForDebug() {
      case .success:
        return
          "Community development shell — Rust core ABI verified, engine-independent, and offline"
      case .failure(let error):
        applicationLogger.error(
          "Rust core ABI smoke check failed: \(error.diagnosticCode, privacy: .public)")
        return
          "Rust core unavailable — rebuild the local artifact before using core-backed features"
      }
    #else
      return "Community development shell — engine-independent and offline"
    #endif
  }
}
