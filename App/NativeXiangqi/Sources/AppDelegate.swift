import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let titleLabel = NSTextField(labelWithString: "NativeXiangqi")
    titleLabel.alignment = .center
    titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)

    let statusLabel = NSTextField(
      wrappingLabelWithString: "Community development shell — engine-independent and offline"
    )
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
}
