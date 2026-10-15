import AppKit
import SwiftUI

@main struct Check {
  static func findText(_ view: NSView) -> NSTextView? {
    if let text = view as? NSTextView { return text }
    for child in view.subviews { if let found = findText(child) { return found } }
    return nil
  }
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let payload = String(repeating: "0123456789abcdef log line\n", count: 2500)
    precondition(payload.utf8.count < 65536)
    let host = NSHostingView(rootView: LogTextView(text: payload))
    host.frame = NSRect(x: 0, y: 0, width: 474, height: 200)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    host.layoutSubtreeIfNeeded()
    guard let text = findText(host), let container = text.textContainer,
      let manager = text.layoutManager
    else { fatalError("native log view not created") }
    let started = Date()
    manager.ensureLayout(for: container)
    let bounds = manager.usedRect(for: container)
    precondition(text.string == payload && text.isSelectable && !text.isEditable)
    precondition(bounds.height > 200 && bounds.width > 0 && bounds.width <= 474)
    print(
      "PASS native selectable log viewer: \(payload.utf8.count) bytes, layout \(bounds.width)x\(bounds.height), layout check \(Date().timeIntervalSince(started))s"
    )
    window.orderOut(nil)
  }
}
