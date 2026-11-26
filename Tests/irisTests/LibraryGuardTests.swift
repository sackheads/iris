import Testing
import Foundation
@testable import IrisKit

/// #1397: a registered external library's reads are judged on-device (`local`, the default), by the configured
/// cloud canary (`cloud`), or with no tier 3 (`none`). The roots live in a protected `config/` file set from
/// Settings only, and a file that doesn't decode sends every guarded tool result to `local`.
@Suite("a library's reads are judged as its guard mode says: local, cloud or none (#1397)", .serialized, .timeLimit(.minutes(1)))
struct LibraryGuardTests {
    private final class CountingCanary: AuxiliaryInferenceEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            lock.withLock { count += 1 }
            return "SAFE"
        }
    }

    private struct PassingTier2: CoreMLModelProtocol {
        func evaluate(text: String) async throws -> Double { 0 }
        func tokenCount(_ text: String) -> Int { max(1, text.utf8.count / 4) }
    }

    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1397-\(UUID().uuidString)")
    private var storeFile: URL { dir.appendingPathComponent("library-guard.json") }

    private func makeDir(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup() { try? FileManager.default.removeItem(at: dir) }

    private func withSettings<T>(_ body: (ConfigManager) async throws -> T) async rethrows -> T {
        let name = "iris-1397-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        return try await body(ConfigManager(store: store))
    }

    /// One guarded read of `text` as a library in `mode`, under scoped tiers and a health box of its own.
    private func judge(_ mode: LibraryGuardMode, engines: [String: AuxiliaryInferenceEngine],
                       settings: ConfigManager, unreadableFile: Bool = false,
                       text: String = "a note \(UUID().uuidString)") async -> String {
        let health = await MainActor.run { GuardTierHealth() }
        return await GuardTierHealth.$scoped.withValue(health) {
            await CoreMLEvaluator.$scopedModel.withValue(.init(PassingTier2())) {
                await AuxiliaryModelManager.$scopedEngines.withValue(engines) {
                    await InjectionGuard.sanitizeUntrustedDisplay(text, contextTag: "tool_output_read_file", maxTier: .tier3_canary,
                                                                  protectionEnabled: true, library: mode,
                                                                  libraryFileUnreadable: unreadableFile, settings: settings).text
                }
            }
        }
    }

    // MARK: - The store

    @Test("a path takes the deepest root it is under, and a path under none is no library read")
    func deepestRootWins() throws {
        defer { cleanup() }
        let outer = try makeDir("vault"), inner = try makeDir("vault/work")
        let store = LibraryGuardStore(file: storeFile)
        store.set(root: outer.path, mode: .none)
        store.set(root: inner.path, mode: .cloud)
        #expect(store.mode(for: outer.appendingPathComponent("a.md").path) == LibraryGuardMode.none)
        #expect(store.mode(for: inner.appendingPathComponent("b.md").path) == .cloud)
        #expect(store.mode(for: dir.appendingPathComponent("vaultish/c.md").path) == nil, "a sibling sharing a prefix is not under it")
        store.remove(root: inner.path)
        #expect(store.mode(for: inner.appendingPathComponent("b.md").path) == LibraryGuardMode.none)
    }

    @Test("a symlink or .. can't put a path under a root it isn't really in, nor out of one it is in")
    func resolvedPaths() throws {
        defer { cleanup() }
        let vault = try makeDir("vault"), outside = try makeDir("outside")
        let link = dir.appendingPathComponent("link-to-outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let inVault = vault.appendingPathComponent("link-in-vault")
        try FileManager.default.createSymbolicLink(at: inVault, withDestinationURL: outside)
        let store = LibraryGuardStore(file: storeFile)
        store.set(root: vault.path, mode: .none)
        #expect(store.mode(for: vault.path + "/../outside/x.md") == nil, "`..` leaves the root")
        #expect(store.mode(for: inVault.appendingPathComponent("x.md").path) == nil, "a link in the vault to elsewhere is elsewhere")
        let vaultLink = dir.appendingPathComponent("link-to-vault")
        try FileManager.default.createSymbolicLink(at: vaultLink, withDestinationURL: vault)
        #expect(store.mode(for: vaultLink.appendingPathComponent("x.md").path) == LibraryGuardMode.none, "a link to the vault is the vault")
        _ = link
    }

    @Test("missing file: no library reads, the global settings as before #1397")
    func missingFileIsGlobal() {
        defer { cleanup() }
        let store = LibraryGuardStore(file: storeFile)
        #expect(store.readMode(nil) == nil)
        #expect(store.readMode(dir.appendingPathComponent("x.md").path) == nil)
        #expect(!store.isUnreadable)
    }

    @Test("a file that doesn't decode sends every guarded tool result to local, a read_file's or not",
          arguments: ["{garbled", "[{\"root\":\"/tmp\",\"mode\":\"always\"}]", "{}"])
    func garbledFileIsLocal(_ bytes: String) throws {
        defer { cleanup() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: storeFile)
        let store = LibraryGuardStore(file: storeFile)
        #expect(store.isUnreadable)
        #expect(store.readMode(nil) == .local, "a run_command's output too")
        #expect(store.readMode("/anywhere/x.md") == .local)
    }

    @Test("a valid file: each root's mode, and nil outside every root")
    func validFileIsPerRoot() throws {
        defer { cleanup() }
        let vault = try makeDir("vault")
        let store = LibraryGuardStore(file: storeFile)
        store.set(root: vault.path, mode: .cloud)
        #expect(!store.isUnreadable)
        #expect(store.readMode(vault.appendingPathComponent("x.md").path) == .cloud)
        #expect(store.readMode(dir.appendingPathComponent("elsewhere.md").path) == nil)
        #expect(store.readMode(nil) == nil, "a tool with no path is no library read")
    }

    // MARK: - Fingerprints and the verdict key

    @Test("each mode is its own fingerprint and verdict key; none has no tier 3")
    func modesAreKeyedApart() async {
        await withSettings { settings in
            settings.promptGuardEngine = AuxiliaryEngineType.llamaCPP.rawValue
            let global = InjectionGuard.currentConfigFingerprint(protectionEnabled: true, settings: settings)
            let local = InjectionGuard.libraryFingerprint(.local, protectionEnabled: true, settings: settings)
            let cloud = InjectionGuard.libraryFingerprint(.cloud, protectionEnabled: true, settings: settings)
            #expect(InjectionGuard.libraryFingerprint(.none, protectionEnabled: true, settings: settings) == nil)
            #expect(local?.promptGuardEngine == "llama_cpp" && local?.canaryRole == "canary" && local?.onDeviceOnly == true)
            #expect(cloud?.promptGuardEngine == "cloud" && cloud?.canaryRole == InjectionGuard.libraryCloudRole)
            func key(_ f: InjectionGuard.GuardConfigFingerprint?) -> String? {
                f.map { InjectionGuard.cacheKey(clean: "t", source: "s", maxTier: .tier3_canary, fingerprint: $0) }
            }
            let keys = [key(global), key(local), key(cloud)]
            #expect(Set(keys.compactMap { $0 }).count == 3, "a verdict under one mode is never served to another")
        }
    }

    @Test("with the global engine on cloud, local is llama.cpp's gemma under its own role")
    func localBesideCloud() async {
        await withSettings { settings in
            settings.promptGuardEngine = AuxiliaryEngineType.cloud.rawValue
            let local = InjectionGuard.libraryFingerprint(.local, protectionEnabled: true, settings: settings)
            #expect(local?.promptGuardEngine == "llama_cpp" && local?.promptGuardModel == ConfigManager.defaultLocalModel)
            #expect(local?.canaryRole == InjectionGuard.libraryLocalRole && local?.onDeviceOnly == true)
            #expect(local?.tier3CloudModel == "")
            let cloud = InjectionGuard.libraryFingerprint(.cloud, protectionEnabled: true, settings: settings)
            #expect(cloud == InjectionGuard.currentConfigFingerprint(protectionEnabled: true, settings: settings),
                    "cloud beside a cloud global engine is that engine")
        }
    }

    // MARK: - Which canary judges

    @Test("none runs no tier 3, and the read is still wrapped as outside text")
    func noneSkipsTier3() async {
        await withSettings { settings in
            let canary = CountingCanary()
            let text = await judge(.none, engines: ["canary": canary], settings: settings)
            #expect(canary.calls == 0)
            #expect(text.contains("<untrusted_context"))
        }
    }

    @Test("cloud beside a local global engine asks the cloud canary, never the local one")
    func cloudUsesItsOwnRole() async {
        await withSettings { settings in
            settings.promptGuardEngine = AuxiliaryEngineType.llamaCPP.rawValue
            let local = CountingCanary(), cloud = CountingCanary()
            let text = await judge(.cloud, engines: ["canary": local, InjectionGuard.libraryCloudRole: cloud], settings: settings)
            #expect(cloud.calls == 1 && local.calls == 0)
            #expect(!text.contains("CONTENT BLOCKED"))
        }
    }

    @Test("local beside a cloud global engine never calls the cloud canary (planner's #1397 row)")
    func localNeverCallsCloud() async {
        await withSettings { settings in
            settings.promptGuardEngine = AuxiliaryEngineType.cloud.rawValue
            let cloud = CountingCanary(), local = CountingCanary()
            let text = await judge(.local, engines: ["canary": cloud, InjectionGuard.libraryLocalRole: local], settings: settings)
            #expect(cloud.calls == 0 && local.calls == 1)
            #expect(!text.contains("CONTENT BLOCKED"))
        }
    }

    @Test("local with no on-device canary blocks and names why, rather than skipping tier 3",
          arguments: [AuxiliaryEngineType.cloud.rawValue, AuxiliaryEngineType.llamaCPP.rawValue])
    func localWithoutCanaryBlocks(_ globalEngine: String) async {
        await withSettings { settings in
            settings.promptGuardEngine = globalEngine
            let cloud = CountingCanary()
            // No on-device engine scoped and no gemma in the test home's models: nothing on-device can judge.
            let engines: [String: AuxiliaryInferenceEngine] = globalEngine == "cloud" ? ["canary": cloud] : [:]
            let text = await judge(.local, engines: engines, settings: settings)
            #expect(text.contains("on-device checks only"), "\(text)")
            #expect(text.contains("isn't downloaded"), "the cause is named: \(text)")
            #expect(cloud.calls == 0)
        }
    }

    @Test("local never sends to a cloud engine left on the global role by a switch without a relaunch (dev-2's #1403 review)")
    func localRefusesACachedCloudEngine() async {
        await withSettings { settings in
            settings.promptGuardEngine = AuxiliaryEngineType.ollama.rawValue
            let sends = CountingCanary()
            var cloud = CloudAuxiliaryEngine.make(role: "canary", config: settings)
            cloud.send = { _, _ in
                _ = try await sends.generate(prompt: "", jsonSchema: nil)
                return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "SAFE")]))], usageMetadata: nil)
            }
            cloud.sendFresh = nil
            // `getEngine` keeps the first engine a role loaded; this stands in for the cloud one loaded before the switch.
            let text = await judge(.local, engines: ["canary": cloud], settings: settings)
            #expect(sends.calls == 0, "the note went to the cloud")
            #expect(text.contains("on-device checks only") && text.contains("relaunch"), "\(text)")
        }
    }

    @Test("with the library list unreadable, a block names the file, not a library (dev-3's #1403 review)")
    func unreadableFileBlockSaysSo() async {
        await withSettings { settings in
            settings.promptGuardEngine = AuxiliaryEngineType.cloud.rawValue
            let text = await judge(.local, engines: [:], settings: settings, unreadableFile: true)
            #expect(text.contains("library-guard.json") && !text.contains("this library is set"), "\(text)")
        }
    }

    // MARK: - Who can change the mode

    @Test("the root list is a protected config/ file: write_file to it is a protected write")
    func writeFileIsProtected() {
        let file = LibraryGuardStore.shared.file
        #expect(file.deletingLastPathComponent().standardizedFileURL == IrisPaths.default.configDir.standardizedFileURL)
        #expect(PermissionManager(paths: .default).isProtectedWrite(toolName: "write_file", path: file.path))
    }

    @Test("a host command naming the root list is a person's call, even under YOLO",
          arguments: ["printf '[]' > \(LibraryGuardStore.shared.file.path)",
                      "echo x >> ~/.iris/config/library-guard.json",
                      "cp /tmp/x \(LibraryGuardStore.shared.file.path)",
                      "rm \(LibraryGuardStore.shared.file.path)"])
    func runCommandIsProtected(_ command: String) {
        #expect(PermissionManager(paths: .default).writesPolicyStore(toolName: "run_command", details: command,
                                                                    workspace: nil, inSandbox: false))
    }

    @Test("an edit to EXTERNAL_LIBRARIES.md sets no mode: the model-maintained registry is never read")
    func registryEditSetsNothing() throws {
        defer { cleanup() }
        let vault = try makeDir("vault")
        let registry = IrisPaths.default.libraryDir.appendingPathComponent("EXTERNAL_LIBRARIES.md")
        let before = try? Data(contentsOf: registry)
        defer {
            if let before { try? before.write(to: registry) } else { try? FileManager.default.removeItem(at: registry) }
        }
        try FileManager.default.createDirectory(at: IrisPaths.default.libraryDir, withIntermediateDirectories: true)
        try "### vault\n- path: \(vault.path)\n- guard: none\n".write(to: registry, atomically: true, encoding: .utf8)
        let store = LibraryGuardStore(file: storeFile)
        #expect(store.readMode(vault.appendingPathComponent("x.md").path) == nil)
        store.set(root: vault.path, mode: .local)
        #expect(store.readMode(vault.appendingPathComponent("x.md").path) == .local)
    }
}

/// #1397 end to end (dev-3's #1403 review): real `read_file` and `run_command` turns through `IrisEngine`, on a
/// `LibraryGuardStore` of their own, so the read site's wiring (`readMode`, the unreadable flag) is what's tested,
/// not only the guard one layer down. The global engine is the default llama.cpp, unprovisioned in the test home.
@MainActor
@Suite("a library's mode reaches the read through the engine (#1397)", .serialized, .timeLimit(.minutes(1)))
struct LibraryGuardEngineTests {
    /// Counts only the prompts that carry `marker`: a turn also has the global canary judge the user profile.
    private final class CountingCanary: AuxiliaryInferenceEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let marker: String
        init(_ marker: String) { self.marker = marker }
        var calls: Int { lock.withLock { count } }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            if prompt.contains(marker) { lock.withLock { count += 1 } }
            return "SAFE"
        }
    }

    private let marker = "NOTE-1397-\(UUID().uuidString)"

    private struct PassingTier2: CoreMLModelProtocol {
        func evaluate(text: String) async throws -> Double { 0 }
        func tokenCount(_ text: String) -> Int { max(1, text.utf8.count / 4) }
    }

    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1397e-\(UUID().uuidString)")
    private var storeFile: URL { dir.appendingPathComponent("library-guard.json") }

    /// One turn running `call`; returns the tool result the model was handed.
    private func run(_ call: FunctionCall, store: LibraryGuardStore, engines: [String: AuxiliaryInferenceEngine]) async throws -> String {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        state.autoApproveTools = true
        let id = state.createNewConversation(isBackground: false, select: true)
        func reply(_ part: Part) -> GeminiResponse {
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
        }
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: [reply(Part(functionCall: call)), reply(Part(text: "done"))]),
                                retryDelays: [], protectionEnabled: true, sessionPeerCount: 0, libraryGuard: store)
        let health = GuardTierHealth()
        await GuardTierHealth.$scoped.withValue(health) {
            await CoreMLEvaluator.$scopedModel.withValue(.init(PassingTier2())) {
                await AuxiliaryModelManager.$scopedEngines.withValue(engines) {
                    await engine.processInput("go", source: "UI", conversationId: id)
                }
            }
        }
        let conversation = try #require(state.conversations.first { $0.id == id })
        return conversation.history.flatMap(\.parts).compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.last ?? ""
    }

    private func note() throws -> URL {
        let vault = dir.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let file = vault.appendingPathComponent("n.md")
        try "a note \(marker)\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func read(_ file: URL) -> FunctionCall { FunctionCall(name: "read_file", args: ["path": .string(file.path)]) }

    @Test("a read_file under a cloud root is judged by the library's cloud canary, not the global one")
    func readFileUsesTheRootsMode() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try note()
        let store = LibraryGuardStore(file: storeFile)
        store.set(root: file.deletingLastPathComponent().path, mode: .cloud)
        let global = CountingCanary(marker), cloud = CountingCanary(marker)
        let result = try await run(read(file), store: store, engines: ["canary": global, InjectionGuard.libraryCloudRole: cloud])
        #expect(cloud.calls == 1 && global.calls == 0, "\(result.prefix(300))")
        #expect(result.contains("<untrusted_context"))
    }

    @Test("the same read outside every root keeps the global canary")
    func readFileOutsideRootsIsGlobal() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try note()
        let global = CountingCanary(marker), cloud = CountingCanary(marker)
        let result = try await run(read(file), store: LibraryGuardStore(file: storeFile),
                                   engines: ["canary": global, InjectionGuard.libraryCloudRole: cloud])
        #expect(global.calls == 1 && cloud.calls == 0, "\(result.prefix(400))")
    }

    @Test("with the list garbled, a run_command result is held to on-device and its block names the file")
    func garbledFileBlocksACommandResult() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{garbled".utf8).write(to: storeFile)
        let call = FunctionCall(name: "run_command", args: ["command": .string("echo library-\(UUID().uuidString)")])
        // No on-device canary: the global llama.cpp model isn't in the test home, and none is scoped.
        let held = try await run(call, store: LibraryGuardStore(file: storeFile), engines: [:])
        #expect(held.contains("library-guard.json"), "\(held.prefix(400))")
        let missing = dir.appendingPathComponent("absent.json")
        let global = try await run(call, store: LibraryGuardStore(file: missing), engines: [:])
        #expect(!global.contains("CONTENT BLOCKED"), "with no file, tier 3 skips as #202 says: \(global.prefix(400))")
    }
}
