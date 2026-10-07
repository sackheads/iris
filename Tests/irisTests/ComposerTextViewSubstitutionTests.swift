import Testing
import AppKit
@testable import iris

/// #295: macOS's smart substitutions (`--` -> em dash, straight quotes -> curly) silently
/// mangle shell commands, code, and JSON typed or pasted into the composer. The user's text
/// must reach the model byte for byte, so the composer's NSTextView must have every automatic
/// substitution turned off. Builds a real NSTextView and runs the same configuration function
/// `ComposerTextView.makeNSView` calls, rather than asserting on hardcoded booleans, so a
/// regression that flips one flag back on in the production code is caught here too.
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
}
