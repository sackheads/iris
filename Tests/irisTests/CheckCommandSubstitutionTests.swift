import Testing
import AppKit
import SwiftUI
@testable import IrisKit

/// #397: the goal contract's check command is a shell command the grader runs, so nothing may
/// rewrite it as it is typed. The real `CriterionRow`, hosted off screen and focused, so the
/// editor read is the one AppKit hands the field when the user types into it.
@MainActor
@Suite("Check command field keeps what is typed (#397)")
struct CheckCommandSubstitutionTests {
    @Test("the check field's editor applies no smart dashes, smart quotes or autocorrection")
    func checkFieldSubstitutesNothing() throws {
        struct Host: View {
            @State var criterion = Criterion(text: "tests pass", kind: .executable, check: "")
            var body: some View {
                CriterionRow(criterion: $criterion, milestones: [], selectedMilestoneTitle: nil,
                             onMilestoneChange: { _ in }, onAddMilestone: { _ in })
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: Host())
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        host.layoutSubtreeIfNeeded()
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let field = try #require(all(host).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "Check command (e.g. swift test)" })
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(!editor.isAutomaticDashSubstitutionEnabled, "-- must not become an em dash")
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled, "straight quotes must stay straight")
        // Only a guard where the Mac's own NSAutomaticSpellingCorrectionEnabled is on (the default):
        // with it off, the field editor never corrects and this passes without the modifier.
        // Forcing it on here would mean writing the process-global defaults (invariant 7).
        #expect(!editor.isAutomaticSpellingCorrectionEnabled, "a flag must not be autocorrected")
    }
}
