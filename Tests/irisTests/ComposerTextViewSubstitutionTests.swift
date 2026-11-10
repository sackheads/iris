import Testing
import AppKit
import SwiftUI
@testable import IrisKit

/// #295: macOS's smart substitutions (`--` -> em dash, straight quotes -> curly) silently
/// mangle shell commands, code, and JSON typed or pasted into the composer. The user's text
/// must reach the model byte for byte, so the composer's NSTextView must have every automatic
/// substitution turned off. Builds a real NSTextView and runs the same configuration function
/// `ComposerTextView.makeNSView` calls, rather than asserting on hardcoded booleans, so a
/// regression that flips one flag back on in the production code is caught here too.
/// On the main actor: `NSTextView.init` registers with a shared AppKit dictionary, and building
/// several at once on pool threads crashed the test process (SIGSEGV in
/// `NSServicesMenuHandler registerServicesMenuSendTypes`, seen during #401).
@MainActor
@Suite("ComposerTextView substitution policy")
struct ComposerTextViewSubstitutionTests {
    @Test("disables automatic dash substitution")
    func dashSubstitutionDisabled() {
        let tv = NSTextView()
        tv.isAutomaticDashSubstitutionEnabled = true // mutation check: flip on, then apply
        tv.applyComposerSubstitutionPolicy()
        #expect(tv.isAutomaticDashSubstitutionEnabled == false)
    }

    @Test("disables automatic quote substitution")
    func quoteSubstitutionDisabled() {
        let tv = NSTextView()
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.applyComposerSubstitutionPolicy()
        #expect(tv.isAutomaticQuoteSubstitutionEnabled == false)
    }

    @Test("disables automatic text replacement")
    func textReplacementDisabled() {
        let tv = NSTextView()
        tv.isAutomaticTextReplacementEnabled = true
        tv.applyComposerSubstitutionPolicy()
        #expect(tv.isAutomaticTextReplacementEnabled == false)
    }

    @Test("disables automatic spelling correction")
    func spellingCorrectionDisabled() {
        let tv = NSTextView()
        tv.isAutomaticSpellingCorrectionEnabled = true
        tv.applyComposerSubstitutionPolicy()
        #expect(tv.isAutomaticSpellingCorrectionEnabled == false)
    }

    @Test("all four flags land off together, independent of starting state")
    func allFlagsOffRegardlessOfStartingState() {
        // SwiftUI's NSViewRepresentable.Context has no public initializer, so this can't
        // drive ComposerTextView.makeNSView directly. This exercises the same extracted
        // function makeNSView calls, starting from AppKit's real defaults rather than a
        // hand-set "true", so the test doesn't depend on assuming what NSTextView() defaults to.
        let tv = NSTextView()
        tv.applyComposerSubstitutionPolicy()
        #expect(tv.isAutomaticDashSubstitutionEnabled == false)
        #expect(tv.isAutomaticQuoteSubstitutionEnabled == false)
        #expect(tv.isAutomaticTextReplacementEnabled == false)
        #expect(tv.isAutomaticSpellingCorrectionEnabled == false)
    }

    /// #1050: pins the fix, not just that some color got set. `.labelColor` is the adaptive
    /// color the composer is supposed to already be resolving to by default — asserting the
    /// exact color (not merely "not nil", which a wrong fixed color like `.black` would also
    /// satisfy) is what a mutant swapping in a non-adaptive color should fail.
    @Test("sets textColor and insertionPointColor to the adaptive label color")
    func textColorPolicySetsAdaptiveLabelColor() {
        let tv = NSTextView()
        tv.textColor = .black // mutation check: start from the regressed value, then apply
        tv.applyComposerTextColorPolicy()
        #expect(tv.textColor == .labelColor)
        #expect(tv.insertionPointColor == .labelColor)
    }

    /// dev-3's #1051 review, finding 1: the two tests above pin the policy function itself on a
    /// bare `NSTextView`, but nothing pinned that `makeNSView` actually calls it — deleting the
    /// call site in production left all six tests green. `NSViewRepresentable.Context` has no
    /// public initializer, so `makeNSView` can't be called directly; hosting the real
    /// `ComposerTextView` value in an `NSHostingView` (same pattern `LiteralTextEditorTests` uses
    /// for `LiteralTextEditor`, #566) drives SwiftUI's own call to `makeNSView` and lets this walk
    /// the real produced view, not a bare substitute.
    @Test("the NSTextView makeNSView actually produces has textColor and insertionPointColor set")
    func makeNSViewProducesATextViewWithTheColorPolicyApplied() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let composer = ComposerTextView(text: .constant(""), onSubmit: {}, emoji: EmojiTokenModel(),
                                        slash: SlashCommandModel())
        let host = NSHostingView(rootView: composer)
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        host.layoutSubtreeIfNeeded()

        func allSubviews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allSubviews) }
        let tv = try #require(allSubviews(host).compactMap { $0 as? NSTextView }.first,
                              "ComposerTextView must still produce an NSTextView")
        #expect(tv.textColor == .labelColor)
        #expect(tv.insertionPointColor == .labelColor)
    }

    /// dev-3's #1051 review, finding 2 (the no-op risk): `.labelColor`, like the default adaptive
    /// `textColor` it replaces, is a dynamic system color that resolves against
    /// `effectiveAppearance` — so if #1050's real cause is something upstream forcing that
    /// resolution to light, setting `.labelColor` explicitly could still resolve black, same as
    /// the default did. This forces the composer's own window to `.darkAqua` and `.aqua` in turn
    /// and reads the RESOLVED color each time, proving `.labelColor` genuinely tracks this
    /// specific view hierarchy's appearance rather than being pinned to one value. It is NOT proof
    /// against the no-op risk in the full app: the real window's chrome (sidebar, toolbar) is what
    /// a broken appearance-resolution context would actually come from, and this test's minimal
    /// hierarchy can't reproduce whatever that is. Brian's dark-window visual is still the only
    /// thing that settles whether #1051 fixes the symptom, not just this one color's mechanics.
    @Test("labelColor genuinely resolves differently under dark vs light appearance, in this view's own hierarchy")
    func labelColorTracksThisWindowsAppearance() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let composer = ComposerTextView(text: .constant(""), onSubmit: {}, emoji: EmojiTokenModel(),
                                        slash: SlashCommandModel())
        let host = NSHostingView(rootView: composer)
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)

        func allSubviews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allSubviews) }
        func brightness(_ appearance: NSAppearance, tv: NSTextView) throws -> CGFloat {
            window.appearance = appearance
            host.layoutSubtreeIfNeeded()
            // A dynamic NSColor resolves against whichever appearance is "current for drawing"
            // (a dynamic/thread-local context), not simply whatever a view's own `.appearance`
            // property holds — reading it outside that context (which `usingColorSpace` alone
            // does) resolves against whatever happened to be current, not this window's. This is
            // itself a live example of the resolution-context hazard #1050/#1052 are about.
            var resolved: NSColor!
            appearance.performAsCurrentDrawingAppearance {
                resolved = tv.textColor!.usingColorSpace(.deviceRGB)!
            }
            return (resolved.redComponent + resolved.greenComponent + resolved.blueComponent) / 3
        }

        host.layoutSubtreeIfNeeded()
        let tv = try #require(allSubviews(host).compactMap { $0 as? NSTextView }.first)
        let darkBrightness = try brightness(try #require(NSAppearance(named: .darkAqua)), tv: tv)
        let lightBrightness = try brightness(try #require(NSAppearance(named: .aqua)), tv: tv)
        #expect(darkBrightness > lightBrightness,
                "labelColor must resolve lighter under dark appearance than light, in this hierarchy: dark=\(darkBrightness) light=\(lightBrightness)")
    }
}
