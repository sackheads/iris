import SwiftUI
import AppKit

/// An NSTextView-backed chat composer. Replaces the SwiftUI TextField so the true
/// caret is available for emoji shortcode handling. Preserves Enter = send and
/// Shift+Enter = newline.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var emoji: EmojiTokenModel
    var slash: SlashCommandModel
    var onEscape: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }
    var focusTrigger: Binding<Bool> = .constant(false)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = KeyCatchingTextView()
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator
        tv.string = text
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.applyComposerSubstitutionPolicy()

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        context.coordinator.textView = tv
        context.coordinator.measureHeight(tv)
        context.coordinator.connectModel()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        let textChanged = (tv.string != text)
        if textChanged {
            tv.string = text
            let len = (text as NSString).length
            tv.setSelectedRange(NSRange(location: len, length: 0))
        }
        // Only re-measure on a real content/width change. Measuring on every update pass
        // (including the ones our own height write triggers) is an AttributeGraph cycle.
        context.coordinator.measureHeight(tv, force: textChanged)

        if focusTrigger.wrappedValue, let window = tv.window, window.isVisible {
            window.makeFirstResponder(tv)
            focusTrigger.wrappedValue = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?
        var isEditing = false
        private var lastHeight: CGFloat = 0
        private var lastWidth: CGFloat = 0

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isEditing, let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            handleTextChange(tv)
            measureHeight(tv, force: true)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isEditing, let tv = notification.object as? NSTextView else { return }
            handleSelectionChange(tv)
        }

        /// Measure the laid-out text height and report it to SwiftUI (async to avoid
        /// mutating view state mid-update). Skips until the view has a real width,
        /// otherwise text wraps to zero width and reports a bogus height.
        ///
        /// Measures only when `force` (a real text change) or the width changed (a resize).
        /// A pure height re-render — which is exactly what reporting a new height triggers —
        /// leaves both unchanged, so it no-ops. That's what breaks the AttributeGraph cycle:
        /// height writes no longer feed back into another measure.
        func measureHeight(_ tv: NSTextView, force: Bool = false) {
            guard tv.bounds.width > 0, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let widthChanged = abs(tv.bounds.width - lastWidth) > 0.5
            guard force || widthChanged else { return }
            lastWidth = tv.bounds.width
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            guard abs(h - lastHeight) > 0.5 else { return }
            lastHeight = h
            let report = parent.onHeightChange
            DispatchQueue.main.async { report(h) }
        }

        func connectModel() {
            parent.emoji.performReplace = { [weak self] glyph, range in
                self?.replace(range: range, with: glyph)
            }
            parent.slash.onCommit = { [weak self] item in
                // Slash commands occupy the whole input (they only match at string start),
                // so the completion replaces the entire field.
                let inserted = item.command + (item.command.contains(" ") ? "" : " ")
                self?.replaceAll(with: inserted)
            }
        }

        func handleTextChange(_ tv: NSTextView) {
            let caret = tv.selectedRange().location
            let ns = tv.string as NSString
            if let (glyph, range) = EmojiTokenizer.completedReplacement(
                in: ns, caret: caret, catalog: .shared, defaultTone: parent.emoji.defaultTone) {
                replace(range: range, with: glyph)   // afterProgrammaticEdit refreshes both popups
                parent.emoji.clear()
                return
            }
            parent.emoji.update(text: ns, caret: caret)
            parent.slash.update(text: tv.string)
        }

        func handleSelectionChange(_ tv: NSTextView) {
            parent.emoji.update(text: tv.string as NSString, caret: tv.selectedRange().location)
            parent.slash.update(text: tv.string)
        }

        /// Replace a UTF-16 range with a string; place the caret after it.
        func replace(range: NSRange, with str: String) {
            guard let tv = textView, tv.shouldChangeText(in: range, replacementString: str) else { return }
            isEditing = true
            tv.textStorage?.replaceCharacters(in: range, with: str)
            tv.didChangeText()
            let newCaret = range.location + (str as NSString).length
            tv.setSelectedRange(NSRange(location: newCaret, length: 0))
            parent.text = tv.string
            isEditing = false
            afterProgrammaticEdit(tv)
            measureHeight(tv, force: true)
        }

        func afterProgrammaticEdit(_ tv: NSTextView) {
            parent.emoji.update(text: tv.string as NSString, caret: tv.selectedRange().location)
            parent.slash.update(text: tv.string)
        }

        /// Replace the entire field contents (used by slash-command completion).
        func replaceAll(with str: String) {
            let len = (textView?.string as NSString?)?.length ?? 0
            replace(range: NSRange(location: 0, length: len), with: str)
        }
    }
}

extension NSTextView {
    /// Disables macOS's automatic text substitutions so the composer's text reaches the
    /// model byte for byte (#295). Left on, the system turns `--` into an em dash and
    /// straight quotes into curly ones, silently mangling shell commands, code, and JSON
    /// the user typed or pasted — `run_command` then fails on an option the user never
    /// wrote. Extracted so a test can assert each flag without standing up the composer's
    /// full NSViewRepresentable.
    func applyComposerSubstitutionPolicy() {
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
    }
}

/// NSTextView that routes Return / arrows / Tab / Escape through the coordinator.
final class KeyCatchingTextView: NSTextView {
    weak var coordinator: ComposerTextView.Coordinator?

    override func keyDown(with event: NSEvent) {
        guard let coordinator else { super.keyDown(with: event); return }
        let flags = event.modifierFlags
        switch event.keyCode {
        case 36, 76: // Return / Enter
            if flags.contains(.shift) {
                super.keyDown(with: event)              // Shift+Enter → newline
            } else if flags.contains(.option) || flags.contains(.control) {
                insertNewline(nil)                      // Option/Ctrl+Enter → newline (from PR #24)
            } else if coordinator.handleNavKey(.enter) {
                return                                   // popup consumed it (emoji commit)
            } else {
                coordinator.parent.onSubmit()
            }
        case 48: // Tab
            if !coordinator.handleNavKey(.tab) { super.keyDown(with: event) }
        case 125: // Down arrow
            if !coordinator.handleNavKey(.down) { super.keyDown(with: event) }
        case 126: // Up arrow
            if !coordinator.handleNavKey(.up) { super.keyDown(with: event) }
        case 53: // Escape
            // Popup open → dismiss it. Otherwise hand Escape to the app-level action
            // (clear message selection / interrupt) instead of letting NSTextView eat it.
            if !coordinator.handleNavKey(.escape) { coordinator.parent.onEscape() }
        default:
            super.keyDown(with: event)
        }
    }
}

extension ComposerTextView.Coordinator {
    enum NavKey { case up, down, tab, enter, escape }

    func handleNavKey(_ key: NavKey) -> Bool {
        // The two popups are mutually exclusive; route to whichever is showing.
        let target: (any PopupNav)? = parent.emoji.isShowing ? parent.emoji
                                    : (parent.slash.isShowing ? parent.slash : nil)
        guard let target else { return false }
        switch key {
        case .up:     target.moveSelection(-1)
        case .down:   target.moveSelection(1)
        case .tab, .enter: target.commitSelected()
        case .escape: target.clear()
        }
        return true
    }
}
