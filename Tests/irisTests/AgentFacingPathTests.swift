import Foundation
import Testing
@testable import iris

@Suite("Agent-facing iris paths")
struct AgentFacingPathTests {
    let devHome = IrisPaths(root: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".iris-dev"))

    @Test("displayRoot abbreviates the home directory")
    func display() {
        #expect(devHome.displayRoot == "~/.iris-dev")
        #expect(IrisPaths(root: URL(fileURLWithPath: "/tmp/x/home")).displayRoot == "/tmp/x/home")
    }

    @Test("rewrites ~/.iris but not longer names")
    func rewrite() {
        let text = "see ~/.iris/memory/USER.md and (~/.iris) and `~/.iris`; leave ~/.iris-dev and ~/.irisrc"
        #expect(devHome.agentFacing(text)
                == "see ~/.iris-dev/memory/USER.md and (~/.iris-dev) and `~/.iris-dev`; leave ~/.iris-dev and ~/.irisrc")
    }

    @Test("release home rewrites to itself")
    func identityForRelease() {
        let text = "~/.iris/memory/skills/<name>/SKILL.md"
        #expect(IrisPaths.release.agentFacing(text) == text)
    }

    @Test("expandTilde sends ~/.iris to this process's home, not the real one")
    func expandTildeReroutes() {
        let root = IrisPaths.default.root.path
        #expect(IrisEngine.expandTilde("~/.iris") == root)
        #expect(IrisEngine.expandTilde("~/.iris/memory/USER.md") == root + "/memory/USER.md")
        #expect(IrisEngine.expandTilde("~/.iris-dev/x") == NSHomeDirectory() + "/.iris-dev/x")
        #expect(IrisEngine.expandTilde("~/.irisrc") == NSHomeDirectory() + "/.irisrc")
    }

    @Test("isUnderIrisDir agrees with expandTilde")
    func underIrisDir() {
        #expect(IrisPaths.default.isUnderIrisDir("~/.iris/memory/USER.md"))
    }

    @Test("tool descriptions name the identity's home")
    func toolDescriptions() async {
        let tools = await ToolExecutor.shared.getTools(workspaceToolsEnabled: false)
        let skillTool = tools.first { $0.name == "create_skill" }
        #expect(skillTool?.description.contains(IrisPaths.standard.displayRoot + "/memory/skills") == true)
        #expect(skillTool?.description.contains("~/.iris/") == false)
    }
}
