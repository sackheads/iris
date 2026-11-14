import Testing
import SwiftUI
import AppKit
@testable import IrisKit

/// #933 review finding 1: the stash shortcut must match the letter S, not the physical key code
/// (layout-dependent — Dvorak's S-position key types "o") nor a bare "contains Command" (which
/// also matched Cmd-Shift-S, Cmd-Option-S, Cmd-Control-S).
@MainActor
@Suite("Composer stash shortcut (#933)")
struct ComposerStashShortcutTests {
    private func keyEvent(characters: String, flags: NSEvent.ModifierFlags, keyCode: UInt16 = 1) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    @Test("Cmd-S (the letter) is the stash shortcut")
    func cmdSIsTheShortcut() {
        #expect(keyEvent(characters: "s", flags: .command).isStashShortcut)
    }

    @Test("Cmd-Shift-S, Cmd-Option-S and Cmd-Control-S are not the stash shortcut",
          arguments: [NSEvent.ModifierFlags([.command, .shift]), [.command, .option], [.command, .control]])
    func extraModifiersAreNotTheShortcut(_ flags: NSEvent.ModifierFlags) {
        #expect(keyEvent(characters: "s", flags: flags).isStashShortcut == false)
    }

    @Test("a bare S with no modifier is not the stash shortcut")
    func bareSIsNotTheShortcut() {
        #expect(keyEvent(characters: "s", flags: []).isStashShortcut == false)
    }

    @Test("the physical key at the US S position typing a different letter (Dvorak's \"o\") is not the stash shortcut")
    func layoutDependentKeyCodeIsNotEnough() {
        // Same keyCode (1) the pre-fix code matched on alone; a Dvorak layout reports "o" here,
        // not "s". Matching the letter, not the code, correctly refuses this.
        #expect(keyEvent(characters: "o", flags: .command, keyCode: 1).isStashShortcut == false)
    }

    @Test("KeyCatchingTextView routes Cmd-S to onStash, and nothing else to it")
    func keyCatchingTextViewRoutesStash() {
        var stashCount = 0
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })
        let composer = ComposerTextView(text: binding, onSubmit: {}, emoji: EmojiTokenModel(),
                                        slash: SlashCommandModel(), onStash: { stashCount += 1 })
        let coordinator = composer.makeCoordinator()
        let tv = KeyCatchingTextView()
        tv.coordinator = coordinator

        tv.keyDown(with: keyEvent(characters: "s", flags: .command))
        #expect(stashCount == 1)
        tv.keyDown(with: keyEvent(characters: "S", flags: [.command, .shift]))
        #expect(stashCount == 1, "Cmd-Shift-S must not stash")
        tv.keyDown(with: keyEvent(characters: "s", flags: []))
        #expect(stashCount == 1, "a bare S must not stash")
    }

    /// #1055: a click that also reactivates the window is AppKit's "activating click" — consumed
    /// for activation only and never delivered as a real `mouseDown` unless the view opts in via
    /// `acceptsFirstMouse`. Default is `false` on a bare `NSTextView`; the composer must opt in so
    /// clicking back into Iris after switching away hands it the keystroke, not a beep.
    @Test("the composer's text view accepts the first click after reactivation")
    func acceptsFirstMouseAfterReactivation() {
        let tv = KeyCatchingTextView()
        #expect(tv.acceptsFirstMouse(for: nil))
    }

    @Test("Cmd-Return and Cmd-Enter match isQueueSubmitShortcut, and other modifiers do not (#1064)")
    func queueSubmitShortcutMatching() {
        #expect(keyEvent(characters: "\r", flags: .command, keyCode: 36).isQueueSubmitShortcut)
        #expect(keyEvent(characters: "\u{03}", flags: [.command, .numericPad], keyCode: 76).isQueueSubmitShortcut)
        #expect(keyEvent(characters: "\r", flags: [], keyCode: 36).isQueueSubmitShortcut == false)
        #expect(keyEvent(characters: "\r", flags: [.command, .shift], keyCode: 36).isQueueSubmitShortcut == false)
        #expect(keyEvent(characters: "\r", flags: [.command, .option], keyCode: 36).isQueueSubmitShortcut == false)
        #expect(keyEvent(characters: "\r", flags: [.command, .control], keyCode: 36).isQueueSubmitShortcut == false)
    }

    @Test("KeyCatchingTextView routes Return to onSubmit and Cmd-Return to onQueueSubmit (#1064)")
    func keyCatchingTextViewRoutesQueueSubmit() {
        var submitCount = 0
        var queueSubmitCount = 0
        var text = "hello"
        let binding = Binding(get: { text }, set: { text = $0 })
        let composer = ComposerTextView(text: binding,
                                        onSubmit: { submitCount += 1 },
                                        onQueueSubmit: { queueSubmitCount += 1 },
                                        emoji: EmojiTokenModel(),
                                        slash: SlashCommandModel())
        let coordinator = composer.makeCoordinator()
        let tv = KeyCatchingTextView()
        tv.coordinator = coordinator

        tv.keyDown(with: keyEvent(characters: "\r", flags: [], keyCode: 36))
        #expect(submitCount == 1)
        #expect(queueSubmitCount == 0)

        tv.keyDown(with: keyEvent(characters: "\r", flags: .command, keyCode: 36))
        #expect(submitCount == 1)
        #expect(queueSubmitCount == 1)

        tv.keyDown(with: keyEvent(characters: "\u{03}", flags: [.command, .numericPad], keyCode: 76))
        #expect(submitCount == 1)
        #expect(queueSubmitCount == 2)
    }
}
