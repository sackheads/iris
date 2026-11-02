import Testing
import Foundation
@testable import IrisKit

/// #248: "session" means a peer conversation to the model (`list_sessions`, "a subagent is not a
/// session"). Three strings the model reads used it for something else: a row in the app's strip
/// (which holds subagents), and a sandbox container's lifetime. They say what they mean now.
@Suite("Agent-facing wording of 'session' (#248)")
struct SessionWordingTests {
    private var skill: String { ShippedSkills.bundledText("sandbox-usage-SKILL") }

    @Test("the reset notice, the subagent stop reason and the sandbox skill do not call a container or a strip row a session")
    func noContradictingMeaning() {
        #expect(!skill.isEmpty, "the bundled skill loaded")
        let strings = [("resetNotice", SandboxSessionManager.resetNotice),
                       ("rowStoppedReason", SubagentManager.rowStoppedReason),
                       ("sandbox-usage skill", skill)]
        for (name, text) in strings {
            for banned in ["session strip", "session's container", "within the session", "idle session"] {
                #expect(!text.contains(banned), "\(name) says \"\(banned)\"")
            }
        }
    }

    @Test("the sandbox skill quotes the start of the notice that run_command appends")
    func skillQuotesTheNotice() {
        let head = String(SandboxSessionManager.resetNotice.prefix { $0 != ";" })
        #expect(head.hasPrefix("[sandbox]"))
        #expect(skill.contains(head), "the skill quotes: \(head)")
    }
}
