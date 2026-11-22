import Testing
import Foundation
@testable import IrisKit

private struct SafeModel: CoreMLModelProtocol {
    func evaluate(text: String) async throws -> Double { 0.01 }
}

/// #1298: a prompt file (USER.md, a workspace AGENTS.md) that reaches the model differently from the file on disk
/// says so. #1209's note fired only on a stripped role marker, so a file with only `---` fences or `###` headings
/// (the common case) was stripped with no word of it, in any config with no model tier. After #1275 a file a tier
/// judged safe is shown as written (`divergedLines == 0`), so the note now fires exactly when the view still
/// differs: no tier, a tier that cleared only some lines, a role marker. Driven through a real `.main` turn.
@MainActor
@Suite("a prompt file shown differently from the file says so (#1298)", .serialized, .timeLimit(.minutes(2)))
struct PromptViewNoteTests {
    private static let okf = "---\ntype: user\n---\n# About\n### Notes\n- likes terse answers\nEnd"
    private static let agents = "# Rules\n### Build\nrun the tests\nEnd"
    private static let differs = IrisEngine.viewDiffersPromptNote
    private static let marker = IrisEngine.strippedMarkerPromptNote

    private struct Fixture {
        let root: URL
        let engine: IrisEngine
        let client: CapturingLLMClient
        let conversation: UUID
        /// `tiers: nil` = no model tier (the deletion channel); a model = both tiers ran and judged.
        func system(tiers: CoreMLModelProtocol?) async -> String {
            let run = { await engine.processInput("hi", source: "UI", conversationId: conversation) }
            if let tiers {
                await CoreMLEvaluator.$scopedModel.withValue(.init(tiers)) {
                    await AuxiliaryModelManager.$scopedEngines.withValue(["canary": MockInferenceEngine(shouldHijack: false)]) { await run() }
                }
            } else {
                await CoreMLEvaluator.$scopedModel.withValue(.init(nil)) { await run() }
            }
            return client.requests.last?.systemInstruction?.parts.compactMap(\.text).joined(separator: "\n") ?? ""
        }
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    private func fixture(user: String, agents: String, protection: Bool = true, stamp: AccessBinding? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1298-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.memoryDir, withIntermediateDirectories: true)
        try user.write(to: paths.userMd, atomically: true, encoding: .utf8)
        let workspace = root.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try agents.write(to: workspace.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let app = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                           createIfEmpty: false, emitLaunchNotices: false)
        let conversation = app.createNewConversation(select: false)
        if let stamp { app.markGuestSteeredBinding(stamp, for: conversation) }
        app.setWorkspace(for: conversation, path: workspace.path)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, client: client, retryDelays: [], protectionEnabled: protection,
                                sessionPeerCount: 0, memory: MemoryManager(paths: paths))
        return Fixture(root: root, engine: engine, client: client, conversation: conversation)
    }

    private func count(of needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    @Test("with no model tier, a fence-and-heading file gets the differs note, once per file, before the file's text")
    func noTierFencesAreAnnounced() async throws {
        let f = try fixture(user: Self.okf, agents: Self.agents); defer { f.tearDown() }
        let system = await f.system(tiers: nil)
        #expect(system.contains("likes terse answers") && system.contains("run the tests"), "the fixture reached the prompt")
        #expect(count(of: Self.differs, in: system) == 2, "one note for USER.md and one for AGENTS.md")
        #expect(!system.contains(Self.marker), "no role marker was stripped, so not the marker note")
        let note = try #require(system.range(of: Self.differs)), body = try #require(system.range(of: "likes terse answers"))
        #expect(note.lowerBound < body.lowerBound, "the note comes before the content it describes")
        let pointer = "read_file on"
        #expect(count(of: pointer, in: system) == 1, "one pointer: USER.md under the engine's Iris home, for the owner; never the workspace AGENTS.md")
        let agentsNote = try #require(system.range(of: "run the tests"))
        let beforeAgents = String(system[..<agentsNote.lowerBound])
        #expect(beforeAgents.components(separatedBy: Self.differs).count == 3, "both notes precede the AGENTS.md body")
        #expect(!(system[system.range(of: "# Project Workspace Rules")!.lowerBound...].contains(pointer)), "no pointer inside the AGENTS.md section")
    }

    @Test("a non-owner binding that reads USER.md (memoryRead .full) is told the view differs but is NOT pointed at read_file")
    func nonOwnerGetsNoPointer() async throws {
        let f = try fixture(user: Self.okf, agents: Self.agents, stamp: AccessBinding(profile: AccessProfile(memoryRead: .full), principal: .main, isOwner: false))
        defer { f.tearDown() }
        let system = await f.system(tiers: nil)
        #expect(system.contains("# User Profile (USER.md)"), "the non-owner turn does read USER.md into its prompt")
        #expect(count(of: Self.differs, in: system) == 2)
        #expect(!system.contains("read_file on"), "no pointer for a binding with no read_file on the Iris home")
    }

    @Test("protection off (the other no-tier config) is announced the same way")
    func protectionOffIsAnnounced() async throws {
        let f = try fixture(user: Self.okf, agents: Self.agents, protection: false); defer { f.tearDown() }
        let system = await f.system(tiers: nil)
        #expect(count(of: Self.differs, in: system) == 2)
    }

    @Test("when both tiers judged the files safe they reach the model as written, and there is nothing to announce")
    func clearedFilesCarryNoNote() async throws {
        let f = try fixture(user: Self.okf, agents: Self.agents); defer { f.tearDown() }
        let system = await f.system(tiers: SafeModel())
        #expect(system.contains("---\ntype: user\n---\n# About\n### Notes"), "as written")
        #expect(!system.contains(Self.differs) && !system.contains(Self.marker))
    }

    @Test("a plain file with nothing to strip carries no note even with no tier")
    func plainFilesCarryNoNote() async throws {
        let f = try fixture(user: "likes tea\nprefers short answers", agents: "use tabs"); defer { f.tearDown() }
        let system = await f.system(tiers: nil)
        #expect(system.contains("likes tea") && system.contains("use tabs"))
        #expect(!system.contains(Self.differs) && !system.contains(Self.marker))
    }

    @Test("a file with a stripped role marker gets the marker note alone, not the marker note and the differs note")
    func markerNoteWinsOverDiffersNote() async throws {
        let f = try fixture(user: "---\nmodel: gpt-x\n---\nlikes tea", agents: "use tabs"); defer { f.tearDown() }
        let system = await f.system(tiers: nil)
        #expect(count(of: Self.marker, in: system) == 1)
        #expect(!system.contains(Self.differs))
    }

    @Test("the read_file pointer is added only where read_file returns the exact text: the owner, under Iris's own home")
    func pointerOnlyWhereReadFileIsFaithful() {
        let home = IrisPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("iris-1298-home-\(UUID().uuidString)"))
        let inHome = home.userMd.path
        #expect(IrisEngine.userMdReadablePath(isOwner: true, path: inHome, irisPaths: home) == inHome)
        #expect(IrisEngine.userMdReadablePath(isOwner: false, path: inHome, irisPaths: home) == nil, "a non-owner reading USER.md has no read_file on the home")
        #expect(IrisEngine.userMdReadablePath(isOwner: true, path: "/somewhere/else/USER.md", irisPaths: home) == nil, "outside the home read_file is guarded, not raw")

        let with = IrisEngine.notingViewDiffers("body", stripped: 0, diverged: 3, readablePath: inHome)
        #expect(with.hasPrefix(IrisEngine.viewDiffersPromptNote) && with.contains("read_file on \(inHome)") && with.hasSuffix("\nbody"))
        let without = IrisEngine.notingViewDiffers("body", stripped: 0, diverged: 3, readablePath: nil)
        #expect(!without.contains("read_file"))
        #expect(IrisEngine.notingViewDiffers("body", stripped: 0, diverged: 0, readablePath: inHome) == "body", "nothing differs: no note, no pointer")
        #expect(IrisEngine.notingViewDiffers("body", stripped: 2, diverged: 5, readablePath: nil).hasPrefix(IrisEngine.strippedMarkerPromptNote))
    }
}
