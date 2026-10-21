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
    @Test("the check field's editor applies no smart dashes, smart quotes, autocorrection or text replacement (#565)")
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
        // The check command is a text view of its own now (#565), not a field AppKit edits with its
        // shared field editor; the one in the row that isn't a field's editor.
        let editor = try #require(all(host).compactMap { $0 as? NSTextView }.first { !$0.isFieldEditor })
        #expect(window.makeFirstResponder(editor))
        #expect(!editor.isAutomaticDashSubstitutionEnabled, "-- must not become an em dash")
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled, "straight quotes must stay straight")
        #expect(!editor.isAutomaticSpellingCorrectionEnabled, "a flag must not be autocorrected")
        #expect(!editor.isAutomaticTextReplacementEnabled, "a Text Replacements entry must not expand in a command")
        // Return adds nothing: a line break would make the grader ask on every run.
        editor.string = "swift test"
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(editor.string == "swift test")
    }
}
