import Testing
import Foundation
@testable import IrisKit

/// #611: Vibecop's in-VM context is the truth. The VM is disposable, but the workspace and any
/// granted paths are the user's own folders, mounted read-write, so a write there is a host write.
/// The engine is task-scoped and every call passes `vibecopEnabled: true` (Invariant 7).
@Suite("Vibecop's in-VM context does not claim isolation from the host (#611)")
struct VibecopVMContextTests {
    private final class Recorder: AuxiliaryInferenceEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var last = ""
        var prompt: String { lock.withLock { last } }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            lock.withLock { last = prompt }
            return #"{"decision":"ESCALATE","reason":"x"}"#
        }
    }

    private func prompt(inSandbox: Bool, workspace: String? = nil) async throws -> String {
        let engine = Recorder()
        _ = try await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": engine]) {
            try await VibecopService.shared.evaluateAction(toolName: "run_command", details: "make", workspace: workspace,
                                                           inSandbox: inSandbox, vibecopEnabled: true)
        }
        return engine.prompt
    }

    @Test("in the VM the prompt says the mounts are the user's real folders, and never that it is isolated")
    func vmPromptIsTruthful() async throws {
        let text = try await prompt(inSandbox: true)
        #expect(text.contains("EXECUTION CONTEXT"))
        #expect(!text.localizedCaseInsensitiveContains("isolated"))
        #expect(text.contains("the user's real Mac folders"))
        #expect(text.contains("read-write unless marked"))
        #expect(text.contains("Library/LaunchAgents/"))
        #expect(text.contains(".git/hooks/"))
        #expect(!text.contains("other dotfiles"), "an open-ended list escalates routine project edits")
    }

    @Test("in the VM the prompt names the mounted workspace, so a VM-only dotfile can be told from a host one")
    func vmPromptNamesTheMount() async throws {
        let text = try await prompt(inSandbox: true, workspace: "/Users/me/src/p")
        #expect(text.contains("the workspace /Users/me/src/p (the working directory)"))
        #expect(text.contains("thrown away with it"))
    }

    @Test("on the host the VM paragraph is absent")
    func hostPromptHasNoVMParagraph() async throws {
        #expect(try await !prompt(inSandbox: false).contains("EXECUTION CONTEXT"))
    }
}
