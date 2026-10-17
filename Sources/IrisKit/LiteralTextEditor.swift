import SwiftUI
import AppKit

/// A multi-line editor for text a machine parses, kept byte for byte (#566). SwiftUI's
/// `TextEditor` applies the Mac's own substitutions, so a pasted or typed JSON snippet came back
/// with curly quotes and em dashes and failed to parse. This one is a plain `NSTextView` under the
/// composer's substitution policy (#295). It is not `ComposerTextView`: that one sends on Return
/// and turns `:name:` into an emoji, both wrong for JSON.
struct LiteralTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                                             weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = font
        tv.string = text
        tv.applyComposerSubstitutionPolicy()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}
