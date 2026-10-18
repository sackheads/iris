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

    @Test("in the VM the prompt says the mounts are the user's real Mac, and never that it is isolated")
    func vmPromptIsTruthful() async throws {
        let text = try await prompt(inSandbox: true)
        #expect(text.contains("EXECUTION CONTEXT"))
        #expect(!text.localizedCaseInsensitiveContains("isolated"))
        #expect(text.contains("Mounted from the user's real Mac"))
        #expect(text.contains("read-write unless"))
        #expect(text.contains("disposable, network-capable Linux VM"), "the phrase #606's tests key on")
        #expect(text.contains("Library/LaunchAgents/"))
        #expect(text.contains(".git/hooks/"))
        #expect(!text.contains("other dotfiles"), "an open-ended list escalates routine project edits")
    }

    @Test("in the VM the prompt names the mounted workspace, so a VM-only dotfile can be told from a host one")
    func vmPromptNamesTheMount() async throws {
        let text = try await prompt(inSandbox: true, workspace: "/Users/me/src/p")
        #expect(text.contains("the workspace /Users/me/src/p (the working directory)"))
        #expect(text.contains("thrown away with it"))
        // Every listed file carries the mount, and the VM's own ~ is named as /root and routine
        // (work's A/B: a bare `.bashrc` escalated the VM's own ~/.bashrc on both models).
        for file in VibecopService.hostRunFiles {
            #expect(text.contains("/Users/me/src/p/" + file), "\(file)")
        }
        #expect(!text.contains(" .bashrc"), "a bare name reads as the VM's own ~")
        #expect(text.contains("which is /root"))
        #expect(text.contains("editing ~/.bashrc or any other\nfile under the VM's ~ is routine"))
    }

    @Test("with no workspace known, the list is still placed under a mounted folder")
    func vmPromptWithoutWorkspace() async throws {
        let text = try await prompt(inSandbox: true)
        #expect(text.contains("<mounted folder>/.bashrc"))
        #expect(text.contains("any paths a job grants"))
    }

    @Test("on the host the VM paragraph is absent")
    func hostPromptHasNoVMParagraph() async throws {
        #expect(try await !prompt(inSandbox: false).contains("EXECUTION CONTEXT"))
    }
}
