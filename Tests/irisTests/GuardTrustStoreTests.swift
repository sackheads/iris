import Testing
import Foundation
@testable import IrisKit

/// #1295 (b'): a library/artifacts file a clean conversation of Iris's wrote reads back raw, like Iris's other
/// first-party files; anything else there is judged. Real `write_file`, `run_command` and `read_file` turns
/// through `executeToolWithHooks`, on a trust list of its own, and a canary that flags the planted marker, so a
/// raw read is told from a judged one by whether the marker survives. The list's own protection (Brian, #1369:
/// "no HMAC, protected file") is pinned by the predicates the approval ladder reads, and a background write.
@MainActor
@Suite("library/artifacts reads are raw only for Iris's own clean writes, by a protected hash list (#1295)",
       .serialized, .timeLimit(.minutes(1)))
struct GuardTrustStoreTests {
    private final class MarkerCanary: AuxiliaryInferenceEngine, @unchecked Sendable {
        let marker: String
        init(_ marker: String) { self.marker = marker }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            prompt.contains(marker) ? "MALICIOUS" : "SAFE"
        }
    }

    private struct PassingTier2: CoreMLModelProtocol {
        func evaluate(text: String) async throws -> Double { 0 }
        func tokenCount(_ text: String) -> Int { max(1, text.utf8.count / 4) }
    }

    private let marker = "PLANTED-1295-\(UUID().uuidString)"
    private let storeFile = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1295-trust-\(UUID().uuidString).json")
    private var paths: IrisPaths { IrisPaths.default }

    private func note(_ folder: URL? = nil) -> URL {
        (folder ?? paths.libraryDir).appendingPathComponent("note-\(UUID().uuidString).md")
    }

    /// One conversation running `calls` in turn, each its own model round; returns each call's result and
    /// whether the conversation ended tainted.
    private func run(_ calls: [FunctionCall], store: GuardTrustStore, tainted: Bool = false, background: Bool = false,
                     autoApprove: Bool = true, hooks: HookManager = HookManager()) async throws -> (results: [String], tainted: Bool) {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        state.autoApproveTools = autoApprove
        let id = state.createNewConversation(isBackground: background, select: !background)
        if tainted { state.markConversationReadUntrusted(id) }
        func reply(_ part: Part) -> GeminiResponse {
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
        }
        let responses = calls.flatMap { [reply(Part(functionCall: $0)), reply(Part(text: "done"))] }
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: responses), retryDelays: [],
                                protectionEnabled: true, sessionPeerCount: 0, guardTrust: store, hooks: hooks)
        await CoreMLEvaluator.$scopedModel.withValue(.init(PassingTier2())) {
            await AuxiliaryModelManager.$scopedEngines.withValue(["canary": MarkerCanary(marker)]) {
                for _ in calls { await engine.processInput("go", source: "UI", conversationId: id) }
            }
        }
        let conversation = try #require(state.conversations.first { $0.id == id })
        let results = conversation.history.flatMap(\.parts).compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }
        return (results, conversation.hasUntrustedToolOutput)
    }

    private func write(_ file: URL, _ text: String) -> FunctionCall {
        FunctionCall(name: "write_file", args: ["path": .string(file.path), "content": .string(text)])
    }
    private func read(_ file: URL) -> FunctionCall { FunctionCall(name: "read_file", args: ["path": .string(file.path)]) }

    /// What a later, clean conversation is handed when it reads `file`.
    private func readBack(_ file: URL, store: GuardTrustStore) async throws -> (result: String, tainted: Bool) {
        let (results, tainted) = try await run([read(file)], store: store)
        return (results.last ?? "", tainted)
    }

    private func store() -> GuardTrustStore { GuardTrustStore(file: storeFile) }

    @Test("a clean conversation's write reads back raw and untainting, in library/ and artifacts/",
          arguments: ["library", "artifacts"])
    func cleanWriteReadsRaw(folder: String) async throws {
        let file = note(folder == "library" ? nil : paths.artifactsDir.appendingPathComponent("p/specs"))
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: storeFile) }
        let trust = store()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wrote = try await run([write(file, "# Plan\n\(marker)\n")], store: trust)
        #expect(wrote.results.first?.contains("Successfully wrote to ") == true, "\(wrote.results)")
        #expect(!wrote.tainted)
        let back = try await readBack(file, store: trust)
        #expect(back.result.contains(marker), "Iris's own clean note was judged: \(back.result.prefix(300))")
        #expect(!back.result.contains("<untrusted_context"))
        #expect(!back.tainted)
    }

    /// dev-3's review: the raw read must also be what the model sees. An AfterTool hook that rewrites the result
    /// after the bytes were hashed is judged, however clean the file is.
    @Test("a clean note whose read result an AfterTool hook rewrites is judged, not passed raw")
    func rewrittenResultIsJudged() async throws {
        let file = note()
        let hookDir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1295-hook-\(UUID().uuidString)")
        defer { [file, storeFile, hookDir].forEach { try? FileManager.default.removeItem(at: $0) } }
        let trust = store()
        try FileManager.default.createDirectory(at: paths.libraryDir, withIntermediateDirectories: true)
        _ = try await run([write(file, "clean note\n")], store: trust)
        try FileManager.default.createDirectory(at: hookDir, withIntermediateDirectories: true)
        let settings = hookDir.appendingPathComponent("settings.json")
        let command = "printf '%s' '{\"result\": \"clean note \(marker)\"}'"
        let config: [String: Any] = ["hooks": ["AfterTool": [["matcher": "read_file", "hooks": [["type": "command", "command": command]]]]]]
        try JSONSerialization.data(withJSONObject: config).write(to: settings)
        var hooks = HookManager()
        hooks.configPathOverride = settings.path
        let (results, tainted) = try await run([read(file)], store: trust, hooks: hooks)
        let result = results.last ?? ""
        #expect(!result.contains(marker), "the rewritten result reached the model raw: \(result.prefix(300))")
        #expect(tainted)
    }

    @Test("the same bytes at another library path read raw too: trust is per content")
    func sameBytesElsewhere() async throws {
        let file = note(), copy = note()
        defer { [file, copy, storeFile].forEach { try? FileManager.default.removeItem(at: $0) } }
        let trust = store()
        try FileManager.default.createDirectory(at: paths.libraryDir, withIntermediateDirectories: true)
        _ = try await run([write(file, "\(marker)\n")], store: trust)
        try FileManager.default.copyItem(at: file, to: copy)
        #expect(try await readBack(copy, store: trust).result.contains(marker))
    }

    @Test("a tainted conversation's write is judged on read")
    func taintedWriteIsJudged() async throws {
        let file = note()
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: storeFile) }
        let trust = store()
        try FileManager.default.createDirectory(at: paths.libraryDir, withIntermediateDirectories: true)
        _ = try await run([write(file, "\(marker)\n")], store: trust, tainted: true)
        let back = try await readBack(file, store: trust)
        #expect(!back.result.contains(marker), "\(back.result.prefix(300))")
        #expect(back.tainted)
    }

    @Test("a run_command write of the same bytes is judged: the store never saw it")
    func shellWriteIsJudged() async throws {
        let file = note()
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: storeFile) }
        let trust = store()
        try FileManager.default.createDirectory(at: paths.libraryDir, withIntermediateDirectories: true)
        let shell = FunctionCall(name: "run_command", args: ["command": .string("printf '%s\\n' '\(marker)' > '\(file.path)'")])
        _ = try await run([shell], store: trust)
        #expect(FileManager.default.fileExists(atPath: file.path), "the shell wrote the note, or this tested nothing")
        let back = try await readBack(file, store: trust)
        #expect(!back.result.contains(marker), "\(back.result.prefix(300))")
        #expect(back.tainted)
    }

    @Test("an outside edit after a clean write is judged")
    func editedAfterwardsIsJudged() async throws {
        let file = note()
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: storeFile) }
        let trust = store()
        try FileManager.default.createDirectory(at: paths.libraryDir, withIntermediateDirectories: true)
        _ = try await run([write(file, "clean text\n")], store: trust)
        try "clean text\n\(marker)\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(!(try await readBack(file, store: trust).result.contains(marker)))
    }

    @Test("a missing or garbled list trusts nothing: a clean write's note is judged")
    func garbledListFailsClosed() async throws {
        let file = note()
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: storeFile) }
        try FileManager.default.createDirectory(at: paths.libraryDir, withIntermediateDirectories: true)
        _ = try await run([write(file, "\(marker)\n")], store: store())
        try "{not json".write(to: storeFile, atomically: true, encoding: .utf8)
        #expect(!(try await readBack(file, store: store()).result.contains(marker)), "garbled")
        try FileManager.default.removeItem(at: storeFile)
        #expect(!(try await readBack(file, store: store()).result.contains(marker)), "missing")
    }

    /// The list as it is on disk: `[sha256: path]`, or nil when there's none or it doesn't decode.
    private func entries() -> [String: String]? {
        (try? Data(contentsOf: storeFile)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    }

    @Test("at launch a deleted note's entry is dropped and a live one's kept, which still reads back raw (#1374)")
    func pruneDropsDeletedKeepsLive() async throws {
        let gone = note(), live = note()
        defer { for f in [gone, live, storeFile] { try? FileManager.default.removeItem(at: f) } }
        try FileManager.default.createDirectory(at: paths.libraryDir, withIntermediateDirectories: true)
        _ = try await run([write(gone, "deleted later\n"), write(live, "# Live\n\(marker)\n")], store: store())
        #expect(entries()?.count == 2, "both clean writes were recorded")
        try FileManager.default.removeItem(at: gone)
        let relaunched = store()
        #expect(relaunched.pruneStale() == 1)
        #expect(entries()?.values.sorted() == [IrisPaths.realPath(live.path)], "\(entries() ?? [:])")
        #expect(relaunched.pruneStale() == 0, "a second launch has nothing to drop")
        let back = try await readBack(live, store: relaunched)
        #expect(back.result.contains(marker) && !back.tainted, "the live note lost its trust: \(back.result.prefix(300))")
    }

    @Test("at launch an edited note's entry is dropped: its file no longer hashes to the key (#1374)")
    func pruneDropsEdited() async throws {
        let file = note()
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: storeFile) }
        try FileManager.default.createDirectory(at: paths.libraryDir, withIntermediateDirectories: true)
        _ = try await run([write(file, "clean text\n")], store: store())
        try "clean text, edited outside\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(store().pruneStale() == 1)
        #expect(entries()?.isEmpty == true)
    }

    @Test("pruning a missing or garbled list writes nothing, so it still trusts nothing (#1374)")
    func pruneLeavesMissingAndGarbledAlone() async throws {
        let file = note()
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: storeFile) }
        #expect(store().pruneStale() == 0)
        #expect(!FileManager.default.fileExists(atPath: storeFile.path), "no list was created")
        try FileManager.default.createDirectory(at: paths.libraryDir, withIntermediateDirectories: true)
        _ = try await run([write(file, "\(marker)\n")], store: store())
        let garbled = Data("{not json".utf8)
        try garbled.write(to: storeFile)
        #expect(store().pruneStale() == 0)
        #expect((try? Data(contentsOf: storeFile)) == garbled, "the garbled list was left as it was")
        #expect(!(try await readBack(file, store: store()).result.contains(marker)), "and it still trusts nothing")
    }

    @Test("the list lives where the protection applies: a protected write, and a policy-store write for a shell")
    func listIsProtected() throws {
        let list = paths.configDir.appendingPathComponent("guard-trust.json").path
        let permissions = PermissionManager(paths: paths)
        #expect(permissions.isProtectedWrite(toolName: "write_file", path: list),
                "write_file to it asks a person (attended, YOLO too) and is refused unattended")
        for command in ["printf '{}' > \(list)", "echo x >> ~/.iris/config/guard-trust.json", "cp /tmp/x \(list)"] {
            #expect(permissions.writesPolicyStore(toolName: "run_command", details: command, workspace: nil, inSandbox: false),
                    "\(command) is a person's call, even under YOLO")
        }
    }

    @Test("an unattended (background) turn's write to the list is refused, and the list is unchanged")
    func backgroundWriteToListIsRefused() async throws {
        let list = paths.configDir.appendingPathComponent("guard-trust.json")
        let before = try? Data(contentsOf: list)
        let forged = "{\"\(GuardTrustStore.sha256(Data("x".utf8)))\":\"/x\"}"
        let (results, _) = try await run([write(list, forged)], store: store(), tainted: true, background: true, autoApprove: false)
        #expect(results.last?.contains("Successfully wrote") == false, "\(results)")
        #expect((try? Data(contentsOf: list)) == before, "the list was not written")
    }

    @Test("a clean write outside library/ and artifacts/ records nothing: the store vouches only for those")
    func otherFoldersAreNotRecorded() async throws {
        let file = paths.root.appendingPathComponent("elsewhere-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: storeFile) }
        _ = try await run([write(file, "\(marker)\n")], store: store())
        #expect(!FileManager.default.fileExists(atPath: storeFile.path))
        #expect(!GuardTrustStore.covers(file.path))
    }
}
