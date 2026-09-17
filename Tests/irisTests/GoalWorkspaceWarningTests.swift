import Testing
import Foundation
@testable import iris

/// The warning shown beside the workspace row before the user approves (spec §5). Text lives out
/// of the view so it is testable without a SwiftUI harness.
@Suite("Goal workspace warning (#68)")
struct GoalWorkspaceWarningTests {
    private let home = "/Users/someone"
    private let cwd = "/Users/someone/src/iris"

    @Test("the Iris source tree is called out by name — it is the literal complaint in #68")
    func irisTreeWarns() {
        let text = GoalWorkspace.warningText(for: cwd, homeDirectory: home, processCwd: cwd)
        #expect(text != nil)
        #expect(text?.contains("Iris") == true)
    }

    @Test("the home directory warns")
    func homeWarns() {
        #expect(GoalWorkspace.warningText(for: home, homeDirectory: home, processCwd: cwd) != nil)
    }

    @Test("a dotfile directory warns")
    func dotfileWarns() {
        #expect(GoalWorkspace.warningText(for: "\(home)/.ssh", homeDirectory: home, processCwd: cwd) != nil)
    }

    @Test("an ordinary directory and a fresh iris workspace are quiet")
    func ordinaryIsQuiet() {
        #expect(GoalWorkspace.warningText(for: "\(home)/src/proj", homeDirectory: home, processCwd: cwd) == nil)
        // Its last component is `ship`, not a dotfile — otherwise every goal Iris creates would
        // warn about itself.
        #expect(GoalWorkspace.warningText(for: "\(home)/.iris/workspaces/ship",
                                          homeDirectory: home, processCwd: cwd) == nil)
    }
}
