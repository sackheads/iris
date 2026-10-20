import SwiftUI
import AppKit

/// Gives the transcript's table keyboard focus when the person clicks inside it (#703). The table
/// never took first responder from the composer on a row click: the row went grey (selected, not
/// key), Cmd-C went to the composer, which had nothing selected, and beeped. Only a click moves
/// focus here, never a selection change, so nothing the app does on its own (an append, a
/// conversation switch, a prune) can pull focus out of the composer while someone types.
///
/// Placed as the transcript List's background, so its frame is the List's. The table is found by
/// that frame, not by position in the view tree: SwiftUI doesn't nest a background inside the
/// List's own AppKit views, and the sidebar is a table too.
struct TranscriptFocusAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ nsView: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            // On the mouse-up, and after AppKit has handled it: a row's button, link or menu has
            // finished its own click by then, and the event itself always goes on unchanged.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                if let self, event.window === self.window {
                    let point = event.locationInWindow
                    DispatchQueue.main.async { self.focusTable(clickedAt: point) }
                }
                return event
            }
        }

        func focusTable(clickedAt point: NSPoint) {
            guard let window, let root = window.contentView,
                  convert(bounds, to: nil).contains(point),
                  let table = Self.table(containing: point, in: root),
                  window.firstResponder !== table else { return }
            // A control inside the transcript that took focus for itself (a text field in a row)
            // keeps it; only focus held outside it, the composer's, moves.
            if let current = window.firstResponder as? NSView, let scroll = table.enclosingScrollView,
               current.isDescendant(of: scroll) { return }
            window.makeFirstResponder(table)
        }

        /// The table whose scroll view's frame, in window coordinates, contains `point`.
        static func table(containing point: NSPoint, in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, let scroll = table.enclosingScrollView,
               scroll.convert(scroll.bounds, to: nil).contains(point) {
                return table
            }
            for sub in view.subviews {
                if let found = table(containing: point, in: sub) { return found }
            }
            return nil
        }
    }
}
