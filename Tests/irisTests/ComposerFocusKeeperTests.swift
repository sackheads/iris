import Testing
import AppKit
@testable import IrisKit

/// A stand-in for the chat window: a "sidebar" table, a "transcript" table, a text field and the
/// stand-in composer text view, in one offscreen window, with the keeper built over seams for "is the
/// window key" and "is the app active" (an unshown window is neither).
@MainActor
private final class Rig {
    final class Flags: @unchecked Sendable { var windowKey = true; var appActive = true }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: true)
    let sidebar = NSTableView()
    let transcript = NSTableView()
    let field = NSTextField(frame: NSRect(x: 0, y: 360, width: 200, height: 24))
    // A plain NSTextView, not KeyCatchingTextView: that class registers itself in the process-global
    // `ComposerFocus` when it joins a window, which would leak this rig into every other suite
    // (AGENTS.md Invariant 7). The keeper takes its composer through an injected closure.
    let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
    let composerScroll = NSScrollView(frame: NSRect(x: 220, y: 0, width: 300, height: 40))
    let flags = Flags()
    let center = NotificationCenter()
    let keeper: ComposerFocusKeeper

    init() {
        let flags = flags
        let composer = composer
        keeper = ComposerFocusKeeper(center: center,
                                     isWindowKey: { _ in flags.windowKey },
                                     isAppActive: { flags.appActive },
                                     composer: { composer },
                                     monitorsEvents: false)
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = content
        for (table, frame) in [(sidebar, NSRect(x: 0, y: 40, width: 200, height: 300)),
                               (transcript, NSRect(x: 220, y: 40, width: 360, height: 300))] {
            table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
            let scroll = NSScrollView(frame: frame)
            scroll.documentView = table
            content.addSubview(scroll)
        }
        content.addSubview(field)
        composer.isEditable = true
        composerScroll.documentView = composer
        content.addSubview(composerScroll)
    }

    func hold(_ responder: NSResponder) { _ = window.makeFirstResponder(responder) }
    var holdsComposer: Bool { window.firstResponder === composer }
}

/// Main-queue work scheduled by the keeper runs at the next turn; poll for it, bounded.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = TestClock.deadline(5)
    while TestClock.now() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A grace period for "nothing happens": one fixed pause, not a bound on anything.
@MainActor
private func settle() async { try? await Task.sleep(for: .milliseconds(100)) }

@Suite("ComposerFocusPolicy", .timeLimit(.minutes(1)))
struct ComposerFocusPolicyTests {
    private func reclaim(_ holder: FocusHolder, clicked: Bool = false, key: Bool = true, active: Bool = true,
                         sheet: Bool = false, usable: Bool = true) -> Bool {
        ComposerFocusPolicy.shouldReclaim(holder: holder, userHasClickedSinceKey: clicked, windowIsKey: key,
                                          appIsActive: active, hasSheetOrModal: sheet, composerUsable: usable)
    }

    @Test("only a holder nobody chose is reclaimed, and only while the person has not clicked")
    func reclaimTable() {
        #expect(reclaim(.other))
        #expect(!reclaim(.composer))
        #expect(!reclaim(.otherTextInput))
        #expect(!reclaim(.transcript))
        #expect(!reclaim(.other, clicked: true))
        #expect(!reclaim(.other, key: false))
        #expect(!reclaim(.other, active: false))
        #expect(!reclaim(.other, sheet: true))
        #expect(!reclaim(.other, usable: false))
    }

    @Test("a printable key is a typed character; a chord, a bare space, a control or an arrow is not")
    func typedCharacter() {
        #expect(ComposerFocusPolicy.isTypedCharacter(characters: "a", modifiers: []))
        #expect(ComposerFocusPolicy.isTypedCharacter(characters: "A", modifiers: .shift))
        #expect(ComposerFocusPolicy.isTypedCharacter(characters: "é", modifiers: .option))
        #expect(!ComposerFocusPolicy.isTypedCharacter(characters: "a", modifiers: .command))
        #expect(!ComposerFocusPolicy.isTypedCharacter(characters: "a", modifiers: .control))
        #expect(!ComposerFocusPolicy.isTypedCharacter(characters: " ", modifiers: []))
        #expect(!ComposerFocusPolicy.isTypedCharacter(characters: "\r", modifiers: []))
        #expect(!ComposerFocusPolicy.isTypedCharacter(characters: "\t", modifiers: []))
        #expect(!ComposerFocusPolicy.isTypedCharacter(characters: "\u{7F}", modifiers: []))
        #expect(!ComposerFocusPolicy.isTypedCharacter(characters: "\u{1B}", modifiers: []))
        #expect(!ComposerFocusPolicy.isTypedCharacter(characters: "\u{F700}", modifiers: []))   // up arrow
        #expect(!ComposerFocusPolicy.isTypedCharacter(characters: "\u{F704}", modifiers: []))   // F1
        #expect(!ComposerFocusPolicy.isTypedCharacter(characters: "", modifiers: []))
        #expect(!ComposerFocusPolicy.isTypedCharacter(characters: nil, modifiers: []))
    }

    @Test("a typed key is redirected only from a holder nobody chose")
    func redirectTable() {
        func redirect(_ holder: FocusHolder, chars: String = "a", mods: NSEvent.ModifierFlags = [],
                      key: Bool = true, sheet: Bool = false, usable: Bool = true) -> Bool {
            ComposerFocusPolicy.shouldRedirectKey(holder: holder, characters: chars, modifiers: mods,
                                                  windowIsKey: key, hasSheetOrModal: sheet, composerUsable: usable)
        }
        #expect(redirect(.other))
        #expect(!redirect(.composer))
        #expect(!redirect(.otherTextInput))
        #expect(!redirect(.transcript))
        #expect(!redirect(.other, chars: " "))
        #expect(!redirect(.other, mods: .command))
        #expect(!redirect(.other, key: false))
        #expect(!redirect(.other, sheet: true))
        #expect(!redirect(.other, usable: false))
    }
}

@MainActor
@Suite("ComposerFocusKeeper", .timeLimit(.minutes(1)))
struct ComposerFocusKeeperTests {
    @Test("a restored conversation: the sidebar holds focus at launch and the composer takes it back")
    func reclaimsFromSidebarAtLaunch() async {
        let rig = Rig()
        rig.hold(rig.sidebar)
        #expect(!rig.holdsComposer)
        rig.keeper.attach(rig.window)
        defer { rig.keeper.detach() }
        #expect(await eventually { rig.holdsComposer })
    }

    @Test("once the person has clicked in the window, nothing is taken from them")
    func respectsAClick() async {
        let rig = Rig()
        rig.hold(rig.sidebar)
        rig.keeper.attach(rig.window)
        defer { rig.keeper.detach() }
        rig.keeper.noteUserClick(in: rig.window)
        await settle()
        #expect(rig.window.firstResponder === rig.sidebar)
        rig.keeper.reclaimIfNeeded(.responderChanged)
        #expect(rig.window.firstResponder === rig.sidebar)
    }

    @Test("a click in some other window does not count as a choice here")
    func otherWindowClickIgnored() async {
        let rig = Rig()
        rig.hold(rig.sidebar)
        rig.keeper.attach(rig.window)
        defer { rig.keeper.detach() }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50),
                             styleMask: [.titled], backing: .buffered, defer: true)
        rig.keeper.noteUserClick(in: other)
        rig.keeper.noteUserClick(in: nil)
        #expect(!rig.keeper.userHasClickedSinceKey)
        #expect(await eventually { rig.holdsComposer })
    }

    @Test("becoming key again re-arms the reclaim: a click earlier does not last across a deactivation")
    func keyAgainReArms() async {
        let rig = Rig()
        rig.keeper.attach(rig.window)
        defer { rig.keeper.detach() }
        rig.keeper.noteUserClick(in: rig.window)
        rig.hold(rig.sidebar)
        await settle()
        #expect(rig.window.firstResponder === rig.sidebar)
        rig.center.post(name: NSWindow.didBecomeKeyNotification, object: rig.window)
        #expect(await eventually { rig.holdsComposer })
    }

    @Test("the app becoming active re-arms it too")
    func appActiveReArms() async {
        let rig = Rig()
        rig.keeper.attach(rig.window)
        defer { rig.keeper.detach() }
        rig.keeper.noteUserClick(in: rig.window)
        rig.hold(rig.sidebar)
        await settle()
        #expect(rig.window.firstResponder === rig.sidebar)
        rig.center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(await eventually { rig.holdsComposer })
    }

    @Test("something moving focus away afterwards, before any click, is undone")
    func undoesALateFocusMove() async {
        let rig = Rig()
        rig.keeper.attach(rig.window)
        defer { rig.keeper.detach() }
        #expect(await eventually { rig.holdsComposer })
        rig.hold(rig.sidebar)   // SwiftUI restoring the sidebar's focus, say
        #expect(await eventually { rig.holdsComposer })
    }

    @Test("if something keeps taking focus back, the keeper stops after a bound instead of fighting for good")
    func givesUpAfterABound() async {
        let rig = Rig()
        rig.keeper.attach(rig.window)
        defer { rig.keeper.detach() }
        #expect(await eventually { rig.holdsComposer })
        for _ in 0..<(ComposerFocusKeeper.maxReclaimsPerCycle * 3) {
            rig.hold(rig.sidebar)
            rig.keeper.reclaimIfNeeded(.responderChanged)
        }
        rig.hold(rig.sidebar)
        await settle()
        #expect(rig.window.firstResponder === rig.sidebar, "past the bound it stays out of the way")
        #expect(rig.keeper.reclaimsThisCycle > ComposerFocusKeeper.maxReclaimsPerCycle)
        // A fresh key-window cycle starts over.
        rig.center.post(name: NSWindow.didBecomeKeyNotification, object: rig.window)
        #expect(await eventually { rig.holdsComposer })
    }

    @Test("a field someone is typing in, and a transcript they clicked, are left alone")
    func leavesChosenHoldersAlone() async {
        let rig = Rig()
        rig.keeper.attach(rig.window)
        defer { rig.keeper.detach() }
        #expect(await eventually { rig.holdsComposer })

        rig.hold(rig.field)   // makes the field editor, an NSText, first responder
        #expect(rig.window.firstResponder is NSText)
        rig.keeper.reclaimIfNeeded(.responderChanged)
        await settle()
        #expect(rig.window.firstResponder is NSText && !rig.holdsComposer)

        rig.keeper.transcriptTookFocus(rig.transcript)
        rig.hold(rig.transcript)
        rig.keeper.reclaimIfNeeded(.appBecameActive)
        await settle()
        #expect(rig.window.firstResponder === rig.transcript)
    }

    @Test("not while the window is not key, the app is not active, or the composer is unusable")
    func staysOutWhenItShould() async {
        let rig = Rig()
        rig.hold(rig.sidebar)
        rig.flags.windowKey = false
        rig.keeper.attach(rig.window)
        defer { rig.keeper.detach() }
        await settle()
        #expect(rig.window.firstResponder === rig.sidebar)

        rig.flags.windowKey = true
        rig.flags.appActive = false
        rig.keeper.reclaimIfNeeded(.appBecameActive)
        #expect(rig.window.firstResponder === rig.sidebar)

        rig.flags.appActive = true
        rig.composer.isEditable = false
        rig.keeper.reclaimIfNeeded(.appBecameActive)
        #expect(rig.window.firstResponder === rig.sidebar)

        rig.composer.isEditable = true
        rig.composerScroll.isHidden = true
        rig.keeper.reclaimIfNeeded(.appBecameActive)
        #expect(rig.window.firstResponder === rig.sidebar)

        rig.composerScroll.isHidden = false
        rig.keeper.reclaimIfNeeded(.appBecameActive)
        #expect(rig.holdsComposer)
    }

    @Test("a letter typed while the sidebar has focus goes to the composer; chords, spaces and typing fields do not")
    func redirectsTypedKeys() async {
        let rig = Rig()
        rig.keeper.attach(rig.window)
        defer { rig.keeper.detach() }
        rig.keeper.noteUserClick(in: rig.window)   // the person chose the sidebar, so reclaim is off
        rig.hold(rig.sidebar)
        await settle()
        #expect(rig.window.firstResponder === rig.sidebar)

        #expect(!rig.keeper.redirectTypedKey(characters: "a", modifiers: .command, in: rig.window))
        #expect(!rig.keeper.redirectTypedKey(characters: " ", modifiers: [], in: rig.window))
        #expect(!rig.keeper.redirectTypedKey(characters: "a", modifiers: [], in: nil))
        #expect(rig.window.firstResponder === rig.sidebar)

        #expect(rig.keeper.redirectTypedKey(characters: "a", modifiers: [], in: rig.window))
        #expect(rig.holdsComposer)
        // Already there: nothing to do.
        #expect(!rig.keeper.redirectTypedKey(characters: "b", modifiers: [], in: rig.window))

        rig.hold(rig.field)
        #expect(!rig.keeper.redirectTypedKey(characters: "c", modifiers: [], in: rig.window))
        #expect(!rig.holdsComposer)
    }
}

/// Call-site wiring, in the repo's source-scan style: nothing else would notice one of these
/// lines being deleted, and the keeper does nothing until they run.
@Suite("ComposerFocusKeeper wiring")
struct ComposerFocusKeeperWiringTests {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/IrisKit/\(name)"), encoding: .utf8)
    }

    @Test("MainWindow.track attaches the keeper, the composer reports joining a window, the transcript reports its focus")
    func callSitesExist() throws {
        #expect(try source("StatusItem.swift").contains("ComposerFocusKeeper.shared.attach(window)"))
        #expect(try source("ComposerTextView.swift").contains("ComposerFocusKeeper.shared.composerDidAttach()"))
        #expect(try source("TranscriptFocusAnchor.swift").contains("ComposerFocusKeeper.shared.transcriptTookFocus(table)"))
    }
}
