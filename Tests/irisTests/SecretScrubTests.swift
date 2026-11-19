import Testing
import Foundation
@testable import IrisKit

/// #974 Task 14 (C2, defence in depth): the owner's secret values are removed from what crosses into a
/// guest-bound context. Pure scrub tests first; then the boundaries driven for real: a tool result on a
/// non-owner turn through a real engine turn, and a message addressed to a guest session through
/// `deliverPeerMessage`.
@MainActor
@Suite("Secret scrub at the guest-bound boundary (#974 Task 14)", .timeLimit(.minutes(1)))
struct SecretScrubTests {
    nonisolated static let secret = "sk-ant-api03-ABCDEFGH1234567890zzzz"

    // MARK: the pure scrub

    @Test("an exact known secret is removed; text with no secret is unchanged")
    func exactAndUnchanged() {
        let known: Set<String> = [Self.secret]
        #expect(SecretScrub.scrubSecrets("key=\(Self.secret) end", known: known) == "key=[redacted] end")
        let plain = "nothing secret here, just a sentence with sk-ant in it"
        #expect(SecretScrub.scrubSecrets(plain, known: known) == plain)
        #expect(SecretScrub.scrubSecrets("anything", known: []) == "anything")
    }

    @Test("a short value is not a secret: it would redact ordinary words")
    func shortValueIgnored() {
        #expect(SecretScrub.scrubSecrets("the word secret appears", known: ["secret"]) == "the word secret appears")
        #expect(SecretScrub.scrubSecrets("1234567 and 12345678", known: ["1234567", "12345678"]) == "1234567 and [redacted]")
    }

    @Test("the likely spellings of a secret are removed too: percent-encoded (URL and strict) and JSON-escaped")
    func spellings() {
        let tricky = "ab/cd+ef=gh\"ij\\kl-mn_op.qr"
        let pct = tricky.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
        let strict = tricky.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let jsonInner = String(String(data: try! JSONEncoder().encode(tricky), encoding: .utf8)!.dropFirst().dropLast())
        for spelled in [tricky, pct, strict, jsonInner] {
            let out = SecretScrub.scrubSecrets("x \(spelled) y", known: [tricky])
            #expect(out == "x [redacted] y", Comment(rawValue: "\(spelled) -> \(out)"))
        }
    }

    @Test("a secret that contains another is removed whole, never leaving the longer one's tail")
    func longestFirst() {
        let short = "abcdefgh", long = "abcdefghIJKLMNOP"
        #expect(SecretScrub.scrubSecrets("v \(long) w", known: [short, long]) == "v [redacted] w")
    }

    @Test("the existing two-argument scrub keeps its behaviour for its callers")
    func legacyEntryPoint() {
        #expect(SecretScrub.scrub("token \(Self.secret)", [Self.secret]) == "token [redacted]")
        #expect(SecretScrub.scrub(Data("e \(Self.secret)".utf8), [Self.secret]) == Data("e [redacted]".utf8))
    }

    // MARK: what the app counts as a known secret

    @Test("knownSecretValues is the secrets item minus the settings that live in it, and minus short values")
    func knownFromConfig() {
        let name = "iris-1214-scrub-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        keychain.replaceSecrets(["ANTHROPIC_API_KEY": Self.secret, "SHORT": "abc",
                                 GuardedKey.anthropicBaseURL.rawValue: "https://proxy.example.com/v1",
                                 GuardedSettings.markerKey: "1"])
        let config = ConfigManager(store: store, guardedSecrets: keychain)
        let known = config.knownSecretValues
        #expect(known.contains(Self.secret))
        #expect(!known.contains("https://proxy.example.com/v1"), "a guarded setting is not a secret")
        #expect(!known.contains("abc"))
    }

    // MARK: a tool result on a non-owner turn, through a real engine turn

    private func turnResult(for call: FunctionCall, binding: AccessBinding?, known: Set<String>) async -> String {
        var script: [[ScriptedStreamClient.Step]] = [[.event(.functionCall(call)), .event(.done(finishReason: "tool_use"))]]
        script.append([.event(.textDelta("done")), .event(.done(finishReason: nil))])
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id)
        app.selectedConversationId = id
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: ScriptedStreamClient(script),
                                retryDelays: [], streamResponses: true, protectionEnabled: false, sessionPeerCount: 0,
                                binding: binding, knownSecrets: { known })
        app.installEngine(engine)
        app.sendMessage("go")
        for _ in 0..<600 {
            if (app.conversations.first { $0.id == id }?.history ?? []).contains(where: { $0.parts.contains { $0.text == "done" } }) { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let parts = (app.conversations.first { $0.id == id }?.history ?? []).flatMap { $0.parts }
        return parts.compactMap { $0.functionResponse?.response["result"]?.stringValue }.joined(separator: "|")
    }

    private func fileWithSecret() throws -> (dir: String, path: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-scrub-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/notes.txt"
        try "the key is \(Self.secret) and the rest is ordinary text".write(toFile: path, atomically: true, encoding: .utf8)
        return (IrisPaths.canonicalPath(dir), IrisPaths.canonicalPath(dir) + "/notes.txt")
    }

    @Test("a non-owner turn's read_file result has the owner's secret removed before the model reads it")
    func nonOwnerResultIsScrubbed() async throws {
        let (dir, path) = try fileWithSecret()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let nonOwner = AccessBinding(profile: AccessProfile(fsRoots: [dir]), principal: .main, isOwner: false)
        let result = await turnResult(for: FunctionCall(name: "read_file", args: ["path": .string(path)], id: "c1"),
                                      binding: nonOwner, known: [Self.secret])
        #expect(result.contains("the rest is ordinary text"), "the non-secret text survives: \(result)")
        #expect(result.contains("[redacted]"), "the secret was removed: \(result)")
        #expect(!result.contains(Self.secret), "the secret reached the model: \(result)")
    }

    @Test("the control: the same read on the owner's own turn is not scrubbed")
    func ownerResultIsNotScrubbed() async throws {
        let (dir, path) = try fileWithSecret()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let result = await turnResult(for: FunctionCall(name: "read_file", args: ["path": .string(path)], id: "c1"),
                                      binding: nil, known: [Self.secret])
        #expect(result.contains(Self.secret), "the owner's own turn is not filtered: \(result)")
    }

    @Test("a non-owner turn with nothing to scrub gets its result unchanged")
    func nonOwnerNothingToScrub() async throws {
        let (dir, path) = try fileWithSecret()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let nonOwner = AccessBinding(profile: AccessProfile(fsRoots: [dir]), principal: .main, isOwner: false)
        let result = await turnResult(for: FunctionCall(name: "read_file", args: ["path": .string(path)], id: "c1"),
                                      binding: nonOwner, known: [])
        #expect(result.contains(Self.secret), "with no known secrets nothing is removed")
    }

    // MARK: a message addressed to a guest session

    private func deliver(_ message: String, toGuest: Bool, known: Set<String>) async -> String {
        let app = AppState(store: try! ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let sender = app.createNewConversation(title: "role", select: false)
        let target = toGuest ? app.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest")
                             : app.createNewConversation(title: "peer", select: false)
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)]),
            retryDelays: [], protectionEnabled: false, knownSecrets: { known })
        app.installEngine(engine)
        let envelope = PeerEnvelope(msgId: "aaaa0001", contextId: "ctx", depth: 1, expectsReply: false, replyTo: nil)
        _ = await engine.deliverPeerMessage(message, from: sender, senderName: "role", to: target, envelope: envelope)
        func text() -> String { (app.conversations.first { $0.id == target }?.messages ?? []).map(\.content).joined(separator: "\n") }
        for _ in 0..<200 where !text().contains("plain sentence") && !text().contains("[redacted]") {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return text()
    }

    @Test("a message addressed to a guest session has the owner's secret removed, and the rest is delivered")
    func messageToGuestIsScrubbed() async {
        let delivered = await deliver("here you go: \(Self.secret) and a plain sentence", toGuest: true, known: [Self.secret])
        #expect(delivered.contains("a plain sentence"), Comment(rawValue: delivered))
        #expect(!delivered.contains(Self.secret), Comment(rawValue: delivered))
        #expect(delivered.contains("[redacted]"))
    }

    @Test("a message to an ordinary session is not filtered: the boundary is the guest, not owner-internal traffic")
    func messageToOrdinarySessionUntouched() async {
        let delivered = await deliver("internal note \(Self.secret) and a plain sentence", toGuest: false, known: [Self.secret])
        #expect(delivered.contains(Self.secret), "owner-internal traffic is not scrubbed: \(delivered)")
    }
}
