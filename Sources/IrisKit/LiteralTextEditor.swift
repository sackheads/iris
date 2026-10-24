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
    /// False for one logical line (#565, a shell command): Return is swallowed rather than adding
    /// a line break the grader would then ask about on every run. A pasted break still arrives.
    var allowsReturn = true

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, allowsReturn: allowsReturn) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = font
        tv.string = text
        tv.applyComposerSubstitutionPolicy()
        // Nor a space added or dropped around a pasted word, inside a JSON string value too.
        tv.smartInsertDeleteEnabled = false
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
        let allowsReturn: Bool
        init(text: Binding<String>, allowsReturn: Bool = true) {
            self.text = text
            self.allowsReturn = allowsReturn
        }

        /// Every command that inserts a break: Return, Option-Return and Control-Return (#753 review).
        static let lineBreakCommands: Set<Selector> = [
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
            #selector(NSResponder.insertLineBreak(_:)),
        ]

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            !allowsReturn && Self.lineBreakCommands.contains(selector)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}
