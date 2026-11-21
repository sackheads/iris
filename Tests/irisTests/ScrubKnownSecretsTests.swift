import Testing
import Foundation
@testable import IrisKit

/// #1220 (#974 Task 14 follow-up): the scrub's known-secret set covers the secrets that live in their own
/// Keychain items: the GitHub token, MCP header secrets, plugin secrets, the A2A seed and the MCP
/// provider's guest tokens. Each is put in its item, read the way its owner reads it, and then removed by
/// the two real boundaries (a non-owner turn's tool result through `engine.processInput`, and a message
/// delivered to a guest session through `deliverPeerMessage`) from a set built by `ConfigManager`, never
/// handed in. An owner control sits beside each.
@MainActor
@Suite("The scrub covers the secrets held outside the main Keychain item (#1220)", .serialized, .timeLimit(.minutes(2)))
struct ScrubKnownSecretsTests {
    private struct Shape {
        let name: String
        /// Puts a secret in the item and reads it the way the item's own owner does; returns the value.
        let hold: (KeychainManager) throws -> String
    }

    private static let shapes: [Shape] = [
        Shape(name: "GitHub token") { keychain in
            let token = "github_pat_11AAAAAAA0abcdefghijklmnop"
            keychain.updateSecrets(service: KeychainManager.githubService) { $0["token"] = token }
            #expect(GitHubProxyClient.token(keychain: keychain) == token)
            return token
        },
        Shape(name: "MCP header secret") { keychain in
            let value = "mcp-header-secret-7f3a9c21d4e8"
            keychain.updateSecrets(service: KeychainManager.mcpFileService) { $0["LINEAR_API_KEY"] = value }
            // `MCPManager`'s default `fileSecrets` closure is exactly this read.
            #expect(keychain.secrets(service: KeychainManager.mcpFileService)["LINEAR_API_KEY"] == value)
            return value
        },
        Shape(name: "plugin secret") { keychain in
            let value = "plugin-bearer-3c91e07ab25f"
            let service = KeychainManager.pluginService("acme")
            keychain.updateSecrets(service: service) { $0["API_TOKEN"] = value }
            #expect(keychain.secrets(service: service)["API_TOKEN"] == value)
            return value
        },
        Shape(name: "A2A signing seed") { keychain in
            let key = try IrisSigningKeyStore(keychain: keychain).loadOrCreate()
            return key.base64Seed
        },
        Shape(name: "MCP provider guest token") { keychain in
            try ProviderTokenRegistry(keychain: keychain).issueToken(forClientId: "dev-1")
        },
    ]

    private func config(_ keychain: KeychainManager) -> (ConfigManager, () -> Void) {
        let name = "iris-1220-scrub-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store, guardedSecrets: keychain), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private func freshKeychain() -> KeychainManager {
        KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
    }

    // MARK: the real boundaries

    private func turnResult(path: String, dir: String, owner: Bool, known: @escaping @Sendable () async -> Set<String>) async -> String {
        let call = FunctionCall(name: "read_file", args: ["path": .string(path)], id: "c1")
        let script: [[ScriptedStreamClient.Step]] = [[.event(.functionCall(call)), .event(.done(finishReason: "tool_use"))],
                                                     [.event(.textDelta("done")), .event(.done(finishReason: nil))]]
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id)
        app.selectedConversationId = id
        let binding = owner ? nil : AccessBinding(profile: AccessProfile(fsRoots: [dir]), principal: .main, isOwner: false)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: ScriptedStreamClient(script),
                                retryDelays: [], streamResponses: true, protectionEnabled: false, sessionPeerCount: 0,
                                binding: binding, knownSecrets: known)
        app.installEngine(engine)
        app.sendMessage("go")
        for _ in 0..<600 {
            if (app.conversations.first { $0.id == id }?.history ?? []).contains(where: { $0.parts.contains { $0.text == "done" } }) { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let parts = (app.conversations.first { $0.id == id }?.history ?? []).flatMap { $0.parts }
        return parts.compactMap { $0.functionResponse?.response["result"]?.stringValue }.joined(separator: "|")
    }

    private func deliveredToGuest(_ message: String, known: @escaping @Sendable () async -> Set<String>) async -> String {
        let app = AppState(store: try! ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let sender = app.createNewConversation(title: "role", select: false)
        let target = app.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest")
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)]),
            retryDelays: [], protectionEnabled: false, knownSecrets: known)
        app.installEngine(engine)
        let envelope = PeerEnvelope(msgId: "aaaa0001", contextId: "ctx", depth: 1, expectsReply: false, replyTo: nil)
        _ = await engine.deliverPeerMessage(message, from: sender, senderName: "role", to: target, envelope: envelope)
        func text() -> String { (app.conversations.first { $0.id == target }?.messages ?? []).map(\.content).joined(separator: "\n") }
        for _ in 0..<200 where !text().contains("plain sentence") && !text().contains("[redacted]") {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return text()
    }

    private func fileWith(_ secret: String) throws -> (dir: String, path: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1220-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/notes.txt"
        try "the value is \(secret) and the rest is ordinary text".write(toFile: path, atomically: true, encoding: .utf8)
        return (IrisPaths.canonicalPath(dir), IrisPaths.canonicalPath(dir) + "/notes.txt")
    }

    @Test("each newly covered secret is in the known set, removed from a non-owner turn's tool result and from a message to a guest; the owner's own turn is not filtered")
    func everyShapeIsScrubbed() async throws {
        for shape in Self.shapes {
            let keychain = freshKeychain()
            let (cfg, teardown) = config(keychain)
            defer { teardown() }
            let secret = try shape.hold(keychain)
            #expect(secret.count >= SecretScrub.minLength, "\(shape.name): fixture is long enough to count")
            #expect(cfg.knownSecretValues.contains(secret), "\(shape.name): in the known set")

            let (dir, path) = try fileWith(secret)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let known: @Sendable () async -> Set<String> = { await MainActor.run { cfg.knownSecretValues } }

            let result = await turnResult(path: path, dir: dir, owner: false, known: known)
            #expect(result.contains("the rest is ordinary text"), "\(shape.name): \(result)")
            #expect(result.contains("[redacted]"), "\(shape.name): \(result)")
            #expect(!result.contains(secret), "\(shape.name) reached a non-owner turn: \(result)")

            let ownerResult = await turnResult(path: path, dir: dir, owner: true, known: known)
            #expect(ownerResult.contains(secret), "\(shape.name): the owner's own turn is not filtered: \(ownerResult)")

            let delivered = await deliveredToGuest("here: \(secret) and a plain sentence", known: known)
            #expect(delivered.contains("a plain sentence"), "\(shape.name): \(delivered)")
            #expect(!delivered.contains(secret), "\(shape.name) reached a guest: \(delivered)")
            #expect(delivered.contains("[redacted]"), "\(shape.name): \(delivered)")
        }
    }

    // MARK: what is not in the set

    @Test("a value written to an item by this process is known; one never read or written here is not (the set reads no Keychain)")
    func noKeychainReadInTheCallPath() {
        let writer = freshKeychain()
        writer.updateSecrets(service: KeychainManager.githubService) { $0["token"] = "github_pat_never_read_by_other" }
        let (cfg, teardown) = config(freshKeychain())
        defer { teardown() }
        #expect(cfg.knownSecretValues.isEmpty, "another manager's items are not read to answer")
        let (cfgWriter, teardown2) = config(writer)
        defer { teardown2() }
        #expect(cfgWriter.knownSecretValues.contains("github_pat_never_read_by_other"), "the manager that wrote it holds it")
    }

    @Test("the roles item holds role names, which are not secrets, and a short value is not held")
    func rolesAndShortValuesAreNotHeld() throws {
        let keychain = freshKeychain()
        let (cfg, teardown) = config(keychain)
        defer { teardown() }
        keychain.updateSecrets(service: KeychainManager.mcpProviderRolesService) { $0["dev-1"] = #"["reviewer-role"]"# }
        _ = keychain.secrets(service: KeychainManager.mcpProviderRolesService)
        keychain.updateSecrets(service: KeychainManager.githubService) { $0["token"] = "short" }
        #expect(cfg.knownSecretValues.isEmpty, "\(cfg.knownSecretValues)")
    }

    @Test("a rotated value stays known: text that still carries the old one is scrubbed")
    func rotatedValueStaysKnown() {
        let keychain = freshKeychain()
        let (cfg, teardown) = config(keychain)
        defer { teardown() }
        keychain.updateSecrets(service: KeychainManager.githubService) { $0["token"] = "github_pat_old_value_111" }
        keychain.updateSecrets(service: KeychainManager.githubService) { $0["token"] = "github_pat_new_value_222" }
        #expect(cfg.knownSecretValues.isSuperset(of: ["github_pat_old_value_111", "github_pat_new_value_222"]))
    }
}
