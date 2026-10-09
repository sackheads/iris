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
        // The build's own home name (`~/.iris-dev` here) is Iris's home too, so a path the dev
        // agent copied out of its prompt lands in the home this process actually uses.
        let own = "~/" + BuildIdentity.current.homeDirectoryName
        #expect(IrisEngine.expandTilde(own) == root)
        #expect(IrisEngine.expandTilde(own + "/memory/USER.md") == root + "/memory/USER.md")
        #expect(IrisEngine.expandTilde("~/.iris-devx") == NSHomeDirectory() + "/.iris-devx")
        #expect(IrisEngine.expandTilde("~/.irisrc") == NSHomeDirectory() + "/.irisrc")
    }

    @Test("rewrites a sentence-final ~/.iris period, but not a suffix that starts with one")
    func rewriteSentenceFinalPeriod() {
        #expect(devHome.agentFacing("stored in ~/.iris.") == "stored in ~/.iris-dev.")
        #expect(devHome.agentFacing("stored in ~/.iris. Next sentence.") == "stored in ~/.iris-dev. Next sentence.")
        #expect(devHome.agentFacing("backup at ~/.iris.bak") == "backup at ~/.iris.bak")
    }

    @Test("isUnderIrisDir agrees with expandTilde")
    func underIrisDir() {
        #expect(IrisPaths.default.isUnderIrisDir("~/.iris/memory/USER.md"))
        #expect(IrisPaths.default.isUnderIrisDir("~/" + BuildIdentity.current.homeDirectoryName + "/x"))
        #expect(!IrisPaths.default.isUnderIrisDir("~/.iris-devx"))
        #expect(!IrisPaths.default.isUnderIrisDir("~/.irisrc"))
    }

    @Test("tool descriptions name the identity's home")
    func toolDescriptions() async {
        let tools = await ToolExecutor.shared.getTools(workspaceToolsEnabled: false)
        let skillTool = tools.first { $0.name == "create_skill" }
        #expect(skillTool?.description.contains(IrisPaths.standard.displayRoot + "/memory/skills") == true)
        #expect(skillTool?.description.contains("~/.iris/") == false)
    }
}
