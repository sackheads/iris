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

    @Test("the encodings real tool output contains are removed: base64 (standard, URL-safe, padded, unpadded) and hex (both cases)")
    func commonEncodings() {
        let secret = "sk-ant-api03-AB/CD+EF1234567890zz"   // contains / and + so the URL-safe form differs
        let bytes = Data(secret.utf8)
        let std = bytes.base64EncodedString()
        let url = std.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let trim = { (t: String) in t.trimmingCharacters(in: CharacterSet(charactersIn: "=")) }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let spelled: [(String, String)] = [("base64", std), ("base64url", url), ("base64 unpadded", trim(std)),
                                           ("base64url unpadded", trim(url)), ("hex lower", hex), ("hex upper", hex.uppercased())]
        for (name, form) in spelled {
            let out = SecretScrub.scrubSecrets("dump: \(form) end", known: [secret])
            #expect(out == "dump: [redacted] end", Comment(rawValue: "\(name): \(out)"))
        }
    }

    @Test("a secret inside a longer base64 value (Basic auth, any alignment) is removed down to the edge characters")
    func basicAuthShape() {
        let secret = "sk-ant-api03-ABCDEFGH1234567890zzzz"
        for prefix in ["user:", "ab:", "a:", "", "longer-user-name:"] {
            let encoded = Data((prefix + secret).utf8).base64EncodedString()
            let out = SecretScrub.scrubSecrets("Authorization: Basic \(encoded)", known: [secret])
            let leftover = out.replacingOccurrences(of: "Authorization: Basic ", with: "").replacingOccurrences(of: "[redacted]", with: "")
            #expect(out.contains("[redacted]"), Comment(rawValue: "\(prefix.debugDescription): \(out)"))
            // Only the edge characters that mix in the neighbours' bytes remain: the prefix's own
            // encoding plus at most a few characters at each seam.
            let allowed = Data(prefix.utf8).base64EncodedString().count + 8
            #expect(leftover.count <= allowed, Comment(rawValue: "\(prefix.debugDescription): \(out)"))
        }
    }

    @Test("a secret that contains another is removed whole, never leaving the longer one's tail")
    func longestFirst() {
        // Several pairs at once: a set has no order, so one pair could pass by luck with the sort removed.
        var known: Set<String> = []
        var text = "", expected = ""
        for i in 0..<12 {
            let short = "secret\(i)abcd", long = "secret\(i)abcdLONGTAIL\(i)"
            known.formUnion([short, long])
            text += "v \(long) w "
            expected += "v [redacted] w "
        }
        #expect(SecretScrub.scrubSecrets(text, known: known) == expected)
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

    // MARK: an approved card, which reaches the model without the dispatch loop

    private func approvedCardRead(binding: AccessBinding?, dir: String, path: String, known: Set<String>) async -> String {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: []),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0,
                                binding: binding, knownSecrets: { known })
        let call = BlockedCall(toolName: "read_file", args: ["path": .string(path)], cwd: nil, reason: .approval)
        return await engine.executeApprovedCall(call, conversationId: id)
    }

    @Test("an approved card's result on a non-owner turn has the owner's secret removed")
    func approvedCardResultIsScrubbed() async throws {
        let (dir, path) = try fileWithSecret()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let nonOwner = AccessBinding(profile: AccessProfile(fsRoots: [dir]), principal: .main, isOwner: false)
        let result = await approvedCardRead(binding: nonOwner, dir: dir, path: path, known: [Self.secret])
        #expect(result.contains("the rest is ordinary text"), Comment(rawValue: result))
        #expect(!result.contains(Self.secret), Comment(rawValue: result))
        #expect(result.contains("[redacted]"))
    }

    @Test("the control: an approved card on the owner's own engine is not scrubbed")
    func approvedCardOwnerNotScrubbed() async throws {
        let (dir, path) = try fileWithSecret()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let result = await approvedCardRead(binding: nil, dir: dir, path: path, known: [Self.secret])
        #expect(result.contains(Self.secret), Comment(rawValue: result))
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
