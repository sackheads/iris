import Testing
import AppKit
import SwiftUI
@testable import IrisKit

/// #566: the plugin wizard's `mcpServers` snippet is JSON the wizard parses, so nothing may rewrite
/// it as it is typed. The real wizard, hosted off screen on its snippet step, so the editor read is
/// the one a person types into. Assertions read the editor's own flags. They catch a missing
/// policy only where the Mac's own substitution defaults are on (macOS's default): a fresh
/// `NSTextView` takes its flags from them, and writing them here would be process-global (inv. 7).
@MainActor
@Suite("Literal text editor (#566)")
struct LiteralTextEditorTests {
    private func host<V: View>(_ view: V) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        return all(view).compactMap { $0 as? NSTextView }
    }

    @Test("the snippet editor applies no smart dashes, smart quotes, text replacement or autocorrection")
    func snippetEditorSubstitutesNothing() throws {
        let (window, root) = host(PluginInstallWizardView(source: .snippet, onComplete: {}))
        let editor = try #require(textViews(in: root).first, "the snippet step shows an editor")
        #expect(window.makeFirstResponder(editor))
        #expect(!editor.isAutomaticDashSubstitutionEnabled, "-- must not become an em dash")
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled, "JSON's quotes must stay straight")
        #expect(!editor.isAutomaticTextReplacementEnabled, "a user's text replacement must not fire")
        #expect(!editor.isAutomaticSpellingCorrectionEnabled, "a key must not be autocorrected")
        #expect(!editor.isRichText, "a paste keeps no formatting")
        #expect(!editor.smartInsertDeleteEnabled, "a paste gains or loses no space around a word")
    }

    @Test("what is typed reaches the binding as typed, and a new value reaches the editor")
    func bindingRoundTrip() throws {
        final class Box { var text = "" }
        let box = Box()
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        let (window, root) = host(LiteralTextEditor(text: binding))
        let editor = try #require(textViews(in: root).first)
        #expect(window.makeFirstResponder(editor))
        let typed = #"{"mcpServers": {"x": {"args": ["--flag"]}}}"#
        editor.insertText(typed, replacementRange: NSRange(location: 0, length: 0))
        #expect(box.text == typed)
    }
}
