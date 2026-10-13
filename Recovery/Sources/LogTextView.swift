import AppKit
import SwiftUI

// Native text layout avoids building a large SwiftUI Text inside a ScrollView.
struct LogTextView: NSViewRepresentable {
  let text: String
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 474, height: 200))
    view.isEditable = false
    view.isSelectable = true
    view.isRichText = false
    view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    view.textColor = .textColor
    view.drawsBackground = false
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.containerSize = NSSize(width: 474, height: CGFloat.greatestFiniteMagnitude)
    scroll.documentView = view
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
    let atEnd = view.string.isEmpty || scroll.contentView.bounds.maxY >= view.bounds.maxY - 24
    let selection = view.selectedRange()
    view.string = text
    if atEnd {
      view.scrollRangeToVisible(NSRange(location: view.string.utf16.count, length: 0))
    } else {
      let count = view.string.utf16.count
      let start = min(selection.location, count)
      view.setSelectedRange(NSRange(location: start, length: min(selection.length, count - start)))
    }
  }
}
