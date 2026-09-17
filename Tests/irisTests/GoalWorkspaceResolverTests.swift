import Testing
import Foundation
@testable import iris

/// The decision rule for where a contracted goal runs (spec §4). Pure: existence is injected, so
/// none of this touches a real filesystem.
@Suite("Goal workspace resolver (#68)")
struct GoalWorkspaceResolverTests {
    private let root = "/tmp/iris-test-root/workspaces"

    /// Only the paths named here "exist".
    private func exists(_ present: Set<String>) -> (String) -> Bool {
        { present.contains($0) }
    }

    // MARK: Resolution order

    @Test("an existing binding is kept — the slice never second-guesses set_workspace")
    func existingBindingWins() {
        let r = GoalWorkspace.resolve(proposed: "/somewhere/else", objective: "ship it",
                                      existingBinding: "/already/bound", workspacesRoot: root,
                                      directoryExists: exists(["/somewhere/else", "/already/bound"]))
        #expect(r == .keptExisting("/already/bound"))
    }

    @Test("a proposal that exists is bound as-is")
    func existingProposalIsBound() {
        let r = GoalWorkspace.resolve(proposed: "/src/foo", objective: "fix the parser",
                                      existingBinding: nil, workspacesRoot: root,
                                      directoryExists: exists(["/src/foo"]))
        #expect(r == .existing("/src/foo"))
    }

    @Test("a proposal that does not exist falls back to a fresh workspace, not an error")
    func missingProposalFallsBack() {
        let r = GoalWorkspace.resolve(proposed: "/src/nope", objective: "fix the parser",
                                      existingBinding: nil, workspacesRoot: root,
                                      directoryExists: exists([]))
        #expect(r == .created("\(root)/fix-the-parser"))
    }

    @Test("no proposal at all yields a fresh workspace named from the objective")
    func noProposalCreates() {
        let r = GoalWorkspace.resolve(proposed: nil, objective: "Write a hangman game",
                                      existingBinding: nil, workspacesRoot: root,
                                      directoryExists: exists([]))
        #expect(r == .created("\(root)/write-a-hangman-game"))
    }

    @Test("a proposal naming a FILE is treated as non-existent")
    func fileProposalFallsBack() {
        let r = GoalWorkspace.resolve(proposed: "/src/foo.txt", objective: "ship",
                                      existingBinding: nil, workspacesRoot: root,
                                      directoryExists: exists([]))
        #expect(r == .created("\(root)/ship"))
    }

    @Test("a tilde in the proposal is expanded before the existence check")
    func tildeIsExpanded() {
        let home = NSHomeDirectory()
        let r = GoalWorkspace.resolve(proposed: "~/src/foo", objective: "ship",
                                      existingBinding: nil, workspacesRoot: root,
                                      directoryExists: exists(["\(home)/src/foo"]))
        #expect(r == .existing("\(home)/src/foo"))
    }

    @Test("a blank proposal is treated as no proposal")
    func blankProposalIsNoProposal() {
        let r = GoalWorkspace.resolve(proposed: "   ", objective: "ship",
                                      existingBinding: nil, workspacesRoot: root,
                                      directoryExists: exists([]))
        #expect(r == .created("\(root)/ship"))
    }

    // MARK: Collisions

    @Test("a name already in use gets a numeric suffix — goals never share a home")
    func collisionsGetSuffixes() {
        let taken = exists(["\(root)/ship", "\(root)/ship-2"])
        let r = GoalWorkspace.resolve(proposed: nil, objective: "ship", existingBinding: nil,
                                      workspacesRoot: root, directoryExists: taken)
        #expect(r == .created("\(root)/ship-3"))
    }

    // MARK: Slug

    @Test("slug lowercases, collapses punctuation, and trims separators")
    func slugNormalizes() {
        #expect(GoalWorkspace.slug(for: "Write a Hangman Game!") == "write-a-hangman-game")
        #expect(GoalWorkspace.slug(for: "  fix:  the //parser//  ") == "fix-the-parser")
    }

    @Test("slug truncates long objectives without a trailing separator")
    func slugTruncates() {
        let s = GoalWorkspace.slug(for: String(repeating: "abcde ", count: 40))
        #expect(s.count <= 40)
        #expect(!s.hasSuffix("-"))
    }

    @Test("an objective with no usable characters yields 'goal'")
    func slugFallsBack() {
        #expect(GoalWorkspace.slug(for: "🎉🎉🎉") == "goal")
        #expect(GoalWorkspace.slug(for: "") == "goal")
    }

    // MARK: Sensitive paths

    @Test("the Iris tree, home, and dotfile directories are flagged as sensitive")
    func sensitivePathsAreFlagged() {
        let home = "/Users/someone"
        let cwd = "/Users/someone/src/iris"
        #expect(GoalWorkspace.isSensitive(cwd, homeDirectory: home, processCwd: cwd))
        #expect(GoalWorkspace.isSensitive(home, homeDirectory: home, processCwd: cwd))
        #expect(GoalWorkspace.isSensitive("\(home)/.ssh", homeDirectory: home, processCwd: cwd))
    }

    @Test("a symlink pointing at the Iris tree is still flagged")
    func symlinkToIrisTreeIsFlagged() throws {
        // `standardizingPath` resolves ./.. but not symlinks, so a lexical compare misses this —
        // and the warning exists precisely to stop a silent re-run of #68.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let target = tmp.appendingPathComponent("iris-symlink-target-\(UUID().uuidString)")
        let link = tmp.appendingPathComponent("iris-symlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }

        #expect(GoalWorkspace.isSensitive(link.path, homeDirectory: "/Users/someone",
                                          processCwd: target.path),
                "a symlink whose target is the source tree must still warn")
    }

    @Test("resolution terminates even when every candidate name is taken")
    func collisionLoopIsBounded() {
        // The draft panel calls resolve on every keystroke, on the main thread — an unbounded
        // scan here would spin the UI, not just a background loop.
        let r = GoalWorkspace.resolve(proposed: nil, objective: "ship", existingBinding: nil,
                                      workspacesRoot: root, directoryExists: { _ in true })
        guard case .created(let path) = r else {
            Issue.record("expected a created workspace, got \(r)")
            return
        }
        #expect(path.hasPrefix("\(root)/ship-"))
        #expect(path.count > "\(root)/ship-".count, "the fallback must produce a distinct name")
    }

    @Test("an ordinary project directory is not flagged")
    func ordinaryPathIsNotFlagged() {
        let home = "/Users/someone"
        #expect(!GoalWorkspace.isSensitive("\(home)/src/myproject", homeDirectory: home,
                                           processCwd: "\(home)/src/iris"))
        #expect(!GoalWorkspace.isSensitive("\(home)/.iris/workspaces/ship", homeDirectory: home,
                                           processCwd: "\(home)/src/iris"))
    }
}
