import AppKit

/// What holds the main window's first responder, as far as composer focus is concerned. Plain
/// data, so the policy below is decided and tested without a window.
enum FocusHolder: Equatable, Sendable {
    /// The composer's own text view (or its scroll view).
    case composer
    /// Some other text input, a field editor or another `NSTextView`: someone is typing there.
    case otherTextInput
    /// The transcript table, taken by a click on it (`TranscriptFocusAnchor`, #703): a deliberate
    /// choice that survives an app switch, so Cmd-C still copies what the person selected.
    case transcript
    /// Anything else: the sidebar list, the window itself, a content view, nothing. Nobody chose
    /// these on purpose, as far as this code can tell.
    case other
}

/// When the composer takes first responder back (#1055). Pure.
///
/// The composer is the default place to type, but nothing in the app puts it there except the
/// New Conversation button. A restored conversation, or a window that comes back to the front,
/// was left with whatever SwiftUI or AppKit happened to focus (the sidebar's selected row, shown
/// bright blue), and every keystroke then beeped. Two rules close that:
/// - **reclaim**: until the person clicks anywhere in the window, the composer takes focus back
///   from a holder nobody chose;
/// - **redirect**: a printable key typed while such a holder has focus moves focus to the composer
///   and types there, whatever the cause was.
enum ComposerFocusPolicy {
    enum Reason: String, Sendable {
        case windowBecameKey, appBecameActive, composerAttached, responderChanged, typedKey, clickedComposer, gaveUp
    }

    static func shouldReclaim(holder: FocusHolder, userHasClickedSinceKey: Bool, windowIsKey: Bool,
                              appIsActive: Bool, hasSheetOrModal: Bool, composerUsable: Bool) -> Bool {
        guard windowIsKey, appIsActive, !hasSheetOrModal, composerUsable, !userHasClickedSinceKey else { return false }
        return holder == .other
    }

    /// A key that means "type this": printable, not a command or control chord, and not a bare
    /// space, which a focused control or the transcript uses to activate or page.
    static func isTypedCharacter(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !modifiers.contains(.command), !modifiers.contains(.control),
              let scalar = characters?.unicodeScalars.first else { return false }
        if scalar == " " { return false }
        if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return false }
        // Arrow and function keys arrive as private-use characters.
        if (0xF700...0xF8FF).contains(scalar.value) { return false }
        return true
    }

    static func shouldRedirectKey(holder: FocusHolder, characters: String?, modifiers: NSEvent.ModifierFlags,
                                  windowIsKey: Bool, hasSheetOrModal: Bool, composerUsable: Bool) -> Bool {
        guard windowIsKey, !hasSheetOrModal, composerUsable, holder == .other else { return false }
        return isTypedCharacter(characters: characters, modifiers: modifiers)
    }
}

/// Watches the main chat window and keeps the composer where typing lands (#1055). One per app;
/// `MainWindow.track` attaches it, and the composer tells it when it joins the window.
///
/// It reclaims on the window becoming key, the app becoming active, the composer joining the
/// window, and any later change of first responder, all until the person's first click in the
/// window. It also redirects a typed key from a holder nobody chose (see `ComposerFocusPolicy`).
/// Both are recorded in `DiagnosticEventRing` so a morning's attended pass can read what it did.
@MainActor
final class ComposerFocusKeeper {
    static let shared = ComposerFocusKeeper()

    private weak var window: NSWindow?
    private weak var deliberateTranscriptTable: NSView?
    private(set) var userHasClickedSinceKey = false
    /// How many times the composer has been put back since the window last became key or the app
    /// last became active. Bounded: if something keeps taking focus away again (SwiftUI restoring
    /// its own choice, say), reclaiming forever would be a fight with no end, so it stops and says so.
    private(set) var reclaimsThisCycle = 0
    static let maxReclaimsPerCycle = 8

    private let center: NotificationCenter
    private let isWindowKey: @MainActor (NSWindow) -> Bool
    private let isAppActive: @MainActor () -> Bool
    private let composerProvider: @MainActor () -> NSTextView?
    private let monitorsEvents: Bool

    private var observers: [NSObjectProtocol] = []
    private var responderObservation: NSKeyValueObservation?
    private var eventMonitor: Any?

    init(center: NotificationCenter = .default,
         isWindowKey: @escaping @MainActor (NSWindow) -> Bool = { $0.isKeyWindow },
         isAppActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
         composer: @escaping @MainActor () -> NSTextView? = { ComposerFocus.current },
         monitorsEvents: Bool = true) {
        self.center = center
        self.isWindowKey = isWindowKey
        self.isAppActive = isAppActive
        self.composerProvider = composer
        self.monitorsEvents = monitorsEvents
    }

    func attach(_ window: NSWindow?) {
        guard let window, window !== self.window else { return }
        detach()
        self.window = window
        userHasClickedSinceKey = false
        reclaimsThisCycle = 0
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowBecameKey() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appBecameActive() }
            },
        ]
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            // Deferred: the change that fired this is still in flight, and a reclaim from inside
            // it would race AppKit's own.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.reclaimIfNeeded(.responderChanged) } }
        }
        if monitorsEvents {
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    switch event.type {
                    case .keyDown: self?.handleKeyDown(event)
                    default: self?.noteUserClick(in: event.window)
                    }
                }
                return event
            }
        }
        // The window may already be key by the time the chat view reaches it.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.reclaimIfNeeded(.windowBecameKey) } }
    }

    func detach() {
        for observer in observers { center.removeObserver(observer) }
        observers = []
        responderObservation = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        window = nil
    }

    /// The composer joined a window: if it is ours, and nobody has chosen a focus yet, take it.
    func composerDidAttach() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.reclaimIfNeeded(.composerAttached) } }
    }

    /// A click in the transcript took the table's focus on purpose (`TranscriptFocusAnchor`).
    func transcriptTookFocus(_ table: NSView) { deliberateTranscriptTable = table }

    func noteUserClick(in clickedWindow: NSWindow?) {
        if clickedWindow != nil, clickedWindow === window { userHasClickedSinceKey = true }
    }

    private func windowBecameKey() {
        userHasClickedSinceKey = false
        reclaimsThisCycle = 0
        DispatchQueue.main.async { MainActor.assumeIsolated { self.reclaimIfNeeded(.windowBecameKey) } }
    }

    private func appBecameActive() {
        userHasClickedSinceKey = false
        reclaimsThisCycle = 0
        DispatchQueue.main.async { MainActor.assumeIsolated { self.reclaimIfNeeded(.appBecameActive) } }
    }

    // MARK: - The two rules

    func reclaimIfNeeded(_ reason: ComposerFocusPolicy.Reason) {
        guard let window, let composer = usableComposer(in: window) else { return }
        let holder = classify(window.firstResponder, composer: composer, in: window)
        defer { if holder != .composer { trace("reclaim(\(reason.rawValue))", window: window, composer: composer, holder: holder) } }
        guard ComposerFocusPolicy.shouldReclaim(
            holder: holder, userHasClickedSinceKey: userHasClickedSinceKey, windowIsKey: isWindowKey(window),
            appIsActive: isAppActive(), hasSheetOrModal: hasSheetOrModal(window), composerUsable: true) else { return }
        guard reclaimsThisCycle < Self.maxReclaimsPerCycle else {
            if reclaimsThisCycle == Self.maxReclaimsPerCycle {
                reclaimsThisCycle += 1
                DiagnosticEventRing.shared.record(.composerFocusReclaim(reason: ComposerFocusPolicy.Reason.gaveUp.rawValue, tookFocus: false))
            }
            return
        }
        reclaimsThisCycle += 1
        let took = window.makeFirstResponder(composer)
        DiagnosticEventRing.shared.record(.composerFocusReclaim(reason: reason.rawValue, tookFocus: took))
        trace("reclaimed(\(reason.rawValue))", window: window, composer: composer, holder: holder, took: took)
    }

    /// Returns whether the key was redirected. The event itself always continues to normal
    /// dispatch, which now reaches the composer.
    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        redirectTypedKey(characters: event.characters, modifiers: event.modifierFlags, in: event.window)
    }

    /// `handleKeyDown` without the `NSEvent`, which a unit test cannot address to an unshown window.
    @discardableResult
    func redirectTypedKey(characters: String?, modifiers: NSEvent.ModifierFlags, in eventWindow: NSWindow?) -> Bool {
        guard let window, eventWindow === window, let composer = usableComposer(in: window) else { return false }
        let holder = classify(window.firstResponder, composer: composer, in: window)
        if holder != .composer, ComposerFocusPolicy.isTypedCharacter(characters: characters, modifiers: modifiers) {
            trace("typedKey", window: window, composer: composer, holder: holder)
        }
        guard ComposerFocusPolicy.shouldRedirectKey(
            holder: holder, characters: characters, modifiers: modifiers,
            windowIsKey: isWindowKey(window), hasSheetOrModal: hasSheetOrModal(window), composerUsable: true) else { return false }
        let took = window.makeFirstResponder(composer)
        DiagnosticEventRing.shared.record(.composerFocusReclaim(reason: ComposerFocusPolicy.Reason.typedKey.rawValue, tookFocus: took))
        return took
    }

    // MARK: - Dev-build trace

    /// A dev build writes what the keeper saw and did to stderr, one line each, so an attended
    /// pass launched from a terminal can read why a keystroke beeped (who held focus, and why the
    /// composer did or did not take it). Release builds write nothing. Class names only: never a
    /// title, a string value or any text the person typed.
    private func trace(_ what: String, window: NSWindow, composer: NSTextView, holder: FocusHolder, took: Bool? = nil) {
        guard BuildIdentity.current == .dev else { return }
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let outcome = took.map { $0 ? " took=yes" : " took=no" } ?? ""
        FileHandle.standardError.write(Data(
            "[FOCUS] \(what) holder=\(holder) responder=\(responder) key=\(isWindowKey(window)) active=\(isAppActive()) clicked=\(userHasClickedSinceKey) cycle=\(reclaimsThisCycle) \(Self.paint(of: composer))\(outcome)\n".utf8))
    }

    /// What the composer's glyphs would be drawn with: its resolved appearance name and the
    /// foreground colour of its typing attributes, resolved against that appearance. #1052's
    /// logs have the appearance name; the paint colour is the part nobody has captured. The
    /// colour only, never the text.
    private static func paint(of composer: NSTextView) -> String {
        var rgb = "none"
        composer.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let colour = (composer.typingAttributes[.foregroundColor] as? NSColor)?.usingColorSpace(.deviceRGB) {
                rgb = String(format: "%.2f,%.2f,%.2f", colour.redComponent, colour.greenComponent, colour.blueComponent)
            }
        }
        return "appearance=\(composer.effectiveAppearance.name.rawValue) typingFG=\(rgb)"
    }

    // MARK: - Reading the window

    private func usableComposer(in window: NSWindow) -> NSTextView? {
        guard let composer = composerProvider(), composer.window === window,
              composer.isEditable, !composer.isHiddenOrHasHiddenAncestor else { return nil }
        return composer
    }

    private func hasSheetOrModal(_ window: NSWindow) -> Bool {
        window.attachedSheet != nil || NSApp.modalWindow != nil
    }

    func classify(_ responder: NSResponder?, composer: NSTextView, in window: NSWindow) -> FocusHolder {
        guard let responder, responder !== window else { return .other }
        if responder === composer { return .composer }
        if let view = responder as? NSView {
            if let scroll = composer.enclosingScrollView, view === scroll || view.isDescendant(of: scroll) { return .composer }
            if let table = deliberateTranscriptTable, view === table || view.isDescendant(of: table) { return .transcript }
        }
        if responder is NSText { return .otherTextInput }
        return .other
    }
}
