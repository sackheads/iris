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
                                     composer: { _ in composer },
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

    /// The middle of a view, in window coordinates, where a click would land.
    func point(in view: NSView) -> NSPoint {
        let frame = view.convert(view.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.midY)
    }
    var onComposer: NSPoint { point(in: composerScroll) }
    var onSidebar: NSPoint { point(in: sidebar.enclosingScrollView!) }

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
        ComposerFocusPolicy.shouldReclaim(holder: holder, userHasChosenSinceKey: clicked, windowIsKey: key,
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

    @Test("a click ON the composer never switches reclaiming off: a steal-back after it is undone")
    func composerClickKeepsReclaimingOn() async {
        let rig = Rig()
        rig.keeper.attach(rig.window)
        defer { rig.keeper.detach() }
        #expect(await eventually { rig.holdsComposer })

        rig.keeper.noteUserClick(in: rig.window, at: rig.onComposer)
        #expect(!rig.keeper.userHasChosenSinceKey)
        rig.hold(rig.sidebar)   // the list taking focus back a moment after the click, say
        #expect(await eventually { rig.holdsComposer })
    }

    @Test("a click OUTSIDE the composer switches reclaiming off, and a later composer click switches it back on")
    func outsideClickDisarmsComposerClickRearms() async {
        let rig = Rig()
        rig.keeper.attach(rig.window)
        defer { rig.keeper.detach() }
        #expect(await eventually { rig.holdsComposer })

        rig.keeper.noteUserClick(in: rig.window, at: rig.onSidebar)
        #expect(rig.keeper.userHasChosenSinceKey)
        rig.hold(rig.sidebar)
        await settle()
        #expect(rig.window.firstResponder === rig.sidebar, "the person chose the sidebar; it is not fought")

        rig.keeper.noteUserClick(in: rig.window, at: rig.onComposer)
        #expect(!rig.keeper.userHasChosenSinceKey)
        // The click chose the composer: it takes focus even though the sidebar held it, with no
        // other trigger, and a steal-back afterwards is undone too.
        #expect(await eventually { rig.holdsComposer })
        rig.hold(rig.sidebar)
        #expect(await eventually { rig.holdsComposer })
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
        #expect(!rig.keeper.userHasChosenSinceKey)
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

    @Test("Tab away from a non-composer holder is a choice the keeper does not undo; Tab inside the composer is not")
    func tabAwayIsAChoice() async {
        let rig = Rig()
        rig.keeper.attach(rig.window)
        defer { rig.keeper.detach() }
        #expect(await eventually { rig.holdsComposer })

        rig.keeper.noteKeyboardNavigation(keyCode: 48, in: rig.window)   // Tab in the composer
        #expect(!rig.keeper.userHasChosenSinceKey)
        rig.keeper.noteKeyboardNavigation(keyCode: 36, in: rig.window)   // Return is no navigation
        #expect(!rig.keeper.userHasChosenSinceKey)

        rig.hold(rig.sidebar)   // full keyboard access moved focus here
        rig.keeper.noteKeyboardNavigation(keyCode: 48, in: nil)           // some other window's key
        #expect(!rig.keeper.userHasChosenSinceKey)
        rig.keeper.noteKeyboardNavigation(keyCode: 48, in: rig.window)
        #expect(rig.keeper.userHasChosenSinceKey)
        await settle()
        #expect(rig.window.firstResponder === rig.sidebar, "a keyboard choice is not undone")
    }

    @Test("Control-Tab leaves a text view, so it is a choice even from the composer; plain Tab there is not")
    func controlTabFromTheComposerIsAChoice() async {
        let rig = Rig()
        rig.keeper.attach(rig.window)
        defer { rig.keeper.detach() }
        #expect(await eventually { rig.holdsComposer })

        rig.keeper.noteKeyboardNavigation(keyCode: 48, modifiers: [], in: rig.window)
        rig.keeper.noteKeyboardNavigation(keyCode: 48, modifiers: .shift, in: rig.window)
        #expect(!rig.keeper.userHasChosenSinceKey, "Tab and Shift-Tab insert or do nothing in the composer")
        rig.keeper.noteKeyboardNavigation(keyCode: 36, modifiers: .control, in: rig.window)
        #expect(!rig.keeper.userHasChosenSinceKey, "Control-Return is not navigation")
        rig.keeper.noteKeyboardNavigation(keyCode: 48, modifiers: .control, in: rig.window)
        #expect(rig.keeper.userHasChosenSinceKey)
    }

    @Test("a window with no composer is searched once, not on every event, and a composer joining resets that")
    func emptySearchIsRemembered() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scroll.documentView = table
        window.contentView?.addSubview(scroll)
        let keeper = ComposerFocusKeeper(center: NotificationCenter(), isWindowKey: { _ in true },
                                         isAppActive: { true }, monitorsEvents: false)
        keeper.attach(window)
        defer { keeper.detach() }
        for _ in 0..<5 { keeper.reclaimIfNeeded(.responderChanged) }
        keeper.noteUserClick(in: window, at: NSPoint(x: 5, y: 5))
        keeper.noteKeyboardNavigation(keyCode: 48, in: window)
        #expect(keeper.composerSearches == 1)

        // A composer arrives (a plain text view stands in for it): remembered, found without a walk.
        let composer = NSTextView(frame: NSRect(x: 0, y: 120, width: 200, height: 40))
        window.contentView?.addSubview(composer)
        keeper.composerDidAttach(composer)
        _ = window.makeFirstResponder(table)
        // The earlier click had no composer to land on, so it counted as a choice; a click on the
        // composer now clears that and the composer takes focus.
        let frame = composer.convert(composer.bounds, to: nil)
        keeper.noteUserClick(in: window, at: NSPoint(x: frame.midX, y: frame.midY))
        #expect(await eventually { window.firstResponder === composer })
        #expect(keeper.composerSearches == 1, "the attached composer is used as reported, no new walk")
    }

    @Test("exactly maxReclaimsPerCycle reclaims happen, the next one gives up, and it gives up only once")
    func boundIsExact() {
        let rig = Rig()
        rig.flags.windowKey = false   // nothing reacts while the rig is set up
        rig.keeper.attach(rig.window)
        defer { rig.keeper.detach() }
        rig.flags.windowKey = true
        // No awaits below: the KVO-deferred reclaims queue up and run after the assertions.
        for taken in 1...ComposerFocusKeeper.maxReclaimsPerCycle {
            rig.hold(rig.sidebar)
            rig.keeper.reclaimIfNeeded(.responderChanged)
            #expect(rig.holdsComposer, "reclaim \(taken) of \(ComposerFocusKeeper.maxReclaimsPerCycle) happens")
        }
        #expect(rig.keeper.reclaimsThisCycle == ComposerFocusKeeper.maxReclaimsPerCycle)
        rig.hold(rig.sidebar)
        rig.keeper.reclaimIfNeeded(.responderChanged)
        #expect(rig.window.firstResponder === rig.sidebar, "the next one gives up")
        #expect(rig.keeper.reclaimsThisCycle == ComposerFocusKeeper.maxReclaimsPerCycle + 1)
        rig.keeper.reclaimIfNeeded(.responderChanged)
        #expect(rig.keeper.reclaimsThisCycle == ComposerFocusKeeper.maxReclaimsPerCycle + 1, "gave up once, not again")
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

@MainActor
@Suite("ComposerFocusKeepers", .timeLimit(.minutes(1)))
struct ComposerFocusKeepersTests {
    private func windowWithComposer() -> (NSWindow, NSTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView?.addSubview(composer)
        return (window, composer)
    }

    private func registry() -> ComposerFocusKeepers {
        ComposerFocusKeepers(makeKeeper: {
            ComposerFocusKeeper(center: NotificationCenter(), isWindowKey: { _ in false }, isAppActive: { false },
                                monitorsEvents: false)
        })
    }

    @Test("each chat window gets its own keeper, once, and a second attach changes nothing")
    func oneKeeperPerWindow() {
        let reg = registry()
        let (a, _) = windowWithComposer()
        let (b, _) = windowWithComposer()
        reg.attach(a)
        let first = reg.keeper(for: a)
        reg.attach(a)
        #expect(reg.count == 1)
        #expect(reg.keeper(for: a) === first, "a second attach keeps the keeper it already made")
        reg.attach(b)
        #expect(reg.count == 2)
        #expect(reg.keeper(for: a) !== reg.keeper(for: b))
        reg.attach(nil)
        #expect(reg.count == 2)
        reg.keeper(for: a)?.detach()
        reg.keeper(for: b)?.detach()
    }

    @Test("a window's close drops its keeper and leaves the other window's alone")
    func closeDropsOnlyThatKeeper() {
        let center = NotificationCenter()
        let reg = ComposerFocusKeepers(makeKeeper: {
            ComposerFocusKeeper(center: center, isWindowKey: { _ in false }, isAppActive: { false }, monitorsEvents: false)
        })
        let (a, _) = windowWithComposer()
        let (b, _) = windowWithComposer()
        reg.attach(a)
        reg.attach(b)
        center.post(name: NSWindow.willCloseNotification, object: a)
        // The observer runs on the main queue.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(reg.keeper(for: a) == nil)
        #expect(reg.keeper(for: b) != nil)
        reg.keeper(for: b)?.detach()
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
        #expect(try source("StatusItem.swift").contains("ComposerFocusKeepers.shared.attach(window)"))
        #expect(try source("ComposerTextView.swift").contains("ComposerFocusKeepers.shared.composerDidAttach(self)"))
        #expect(try source("TranscriptFocusAnchor.swift").contains("ComposerFocusKeepers.shared.transcriptTookFocus(table)"))
    }
}
