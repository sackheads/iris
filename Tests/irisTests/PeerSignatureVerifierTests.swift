import Foundation
import CryptoKit
import Testing
@testable import IrisKit

/// #974 H4 Task 4: the peer-signature verifier — the single enforcement point deciding whether an
/// inbound A2A frame is genuine, fresh and not a replay, before any of its content is trusted.
/// Every test uses its own temp directory via `IrisPaths(root:)` (Invariant 7), and every `now`
/// is injected into `VerificationContext`, never read from the system clock.
@Suite("Peer signature verifier (#974 H4)")
struct PeerSignatureVerifierTests {

    // MARK: - Test envelope + decode closure

    /// The fixture `VerifiableEnvelope` conformer the brief asks for.
    struct TestEnvelope: VerifiableEnvelope, Equatable {
        let fromProfile: String
        let toProfile: String?
        let kind: String
        let envelopeId: String
        let ts: String
        let deadline: String?
        let taskId: String?
        let correlationId: String?
    }

    /// A deliberately naive mapping from raw JSON bytes to `TestEnvelope`, via
    /// `JSONSerialization` — which, like any ordinary `JSONDecoder`-based transport, silently
    /// keeps the *first* value for a repeated object key (pinned independently by this task's own
    /// round-1 security review and by Task 6's `PeerSignatureConformanceTests`) rather than
    /// noticing the repeat at all. Standing in for "what a transport that never heard of
    /// `StrictJSON` would write." Used directly by the
    /// `firstWinsDecodeStillYieldsDuplicateKey` test below: the core's own scan must catch what
    /// this decoder cannot, regardless of which value it would have silently picked.
    static func decodeTestEnvelope(_ data: Data) throws -> TestEnvelope {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FrameDecodeError.missingRequiredField("root")
        }
        func requireString(_ key: String) throws -> String {
            guard let value = obj[key], !(value is NSNull), let str = value as? String else {
                throw FrameDecodeError.missingRequiredField(key)
            }
            return str
        }
        func optionalString(_ key: String) -> String? {
            guard let value = obj[key], !(value is NSNull) else { return nil }
            return value as? String
        }
        guard let from = obj["from"] as? [String: Any], let fromProfile = from["profile"] as? String else {
            throw FrameDecodeError.missingRequiredField("fromProfile")
        }
        let to = obj["to"] as? [String: Any]
        let toProfile = to?["profile"] as? String
        let kind = try requireString("kind")
        let envelopeId = try requireString("envelopeId")
        let ts = try requireString("ts")
        var deadline: String?
        if let payload = obj["payload"] as? [String: Any],
           let metadata = payload["metadata"] as? [String: Any],
           let d = metadata["deadline"], !(d is NSNull) {
            deadline = d as? String
        }
        return TestEnvelope(
            fromProfile: fromProfile,
            toProfile: toProfile,
            kind: kind,
            envelopeId: envelopeId,
            ts: ts,
            deadline: deadline,
            taskId: optionalString("taskId"),
            correlationId: optionalString("correlationId")
        )
    }

    // MARK: - In-memory SeenSetStore stub

    final class InMemorySeenSet: SeenSetStore, @unchecked Sendable {
        private let lock = NSLock()
        private var seenByPeer: [String: Set<String>] = [:]
        private let forcedError: SeenSetStoreError?

        init(forcedError: SeenSetStoreError? = nil) {
            self.forcedError = forcedError
        }

        func admit(peer: String, envelopeId: String, retainUntil: Date, maxPerPeer: Int, now: Date) throws -> AdmitResult {
            lock.lock()
            defer { lock.unlock() }
            if let forcedError { throw forcedError }
            var ids = seenByPeer[peer, default: []]
            if ids.contains(envelopeId) { return .duplicate }
            guard ids.count < maxPerPeer else { throw SeenSetStoreError.full }
            ids.insert(envelopeId)
            seenByPeer[peer] = ids
            return .fresh
        }
    }

    // MARK: - Registry / key helpers

    private func freshRegistry() -> (PeerKeyRegistry, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peer-sig-verifier-\(UUID().uuidString)")
        return (PeerKeyRegistry(paths: IrisPaths(root: tempDir)), tempDir)
    }

    /// Enrolls a fresh key for `profile` (keyId defaults to the profile name, matching
    /// `PeerKeyRegistry.resolve`'s convention) and returns it alongside the registry.
    private func enrolledKey(profile: String, in registry: PeerKeyRegistry) throws -> IrisSigningKey {
        let key = IrisSigningKey()
        try registry.enroll(RegisteredKey(profile: profile, keyId: profile, publicKey: key.publicKeyWireString))
        return key
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - Vendored conformance fixture

    private struct ConformanceFixture: Decodable {
        struct NegativeVector: Decodable {
            struct Identity: Decodable {
                let verifiedBy: String
                let principal: String
                let sig: String
            }
            struct Frame: Decodable {
                let identity: Identity
                let envelopeBytes: String
            }
            let name: String
            let frame: Frame
            let selfProfile: String
            let now: String
            let pubkeys: [String: String]

            enum CodingKeys: String, CodingKey {
                case name, frame, pubkeys
                case selfProfile = "self_profile"
                case now
            }
        }
        let negativeVectors: [NegativeVector]

        enum CodingKeys: String, CodingKey {
            case negativeVectors = "negative_vectors"
        }
    }

    private func loadFixture() throws -> ConformanceFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/peer-signature-conformance.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ConformanceFixture.self, from: data)
    }

    private func fixtureVector(named name: String) throws -> ConformanceFixture.NegativeVector {
        try #require(try loadFixture().negativeVectors.first { $0.name == name })
    }

    /// Enrolls every key a vendored vector lists, decodes its frame and `now`, and returns a
    /// ready-to-call `(frame, registry, tempDir, context)` tuple. Caller cleans up `tempDir`.
    private func setup(
        for vector: ConformanceFixture.NegativeVector,
        channel: A2AChannel = .inbox,
        outstanding: OutstandingRequest? = nil
    ) throws -> (SignedFrameParts, PeerKeyRegistry, URL, VerificationContext) {
        let (registry, tempDir) = freshRegistry()
        for (profile, wire) in vector.pubkeys {
            try registry.enroll(RegisteredKey(profile: profile, keyId: profile, publicKey: wire))
        }
        let envelopeBytes = try #require(Data(base64Encoded: vector.frame.envelopeBytes))
        let signature = try #require(Data(base64Encoded: vector.frame.identity.sig))
        let frame = SignedFrameParts(
            principal: vector.frame.identity.principal,
            keyId: nil,
            verifiedBy: vector.frame.identity.verifiedBy,
            signature: signature,
            envelopeBytes: envelopeBytes
        )
        let now = try #require(ISO8601DateFormatter().date(from: vector.now))
        let context = VerificationContext(selfProfile: vector.selfProfile, channel: channel, outstanding: outstanding, now: now)
        return (frame, registry, tempDir, context)
    }

    // MARK: - Happy path

    @Test("a well-formed inbound message is admitted")
    func wellFormedMessageAdmitted() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = try enrolledKey(profile: "clomp", in: registry)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Self.iso(now)
        let deadline = Self.iso(now.addingTimeInterval(3600))
        let envelope = Data("""
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"message","envelopeId":"happy-path-id-0001","ts":"\(ts)","payload":{"metadata":{"deadline":"\(deadline)"}},"taskId":"task-1","correlationId":"corr-1"}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)

        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)
        let result = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)

        #expect(result.envelopeId == "happy-path-id-0001")
        #expect(result.fromProfile == "clomp")
    }

    // MARK: - One test per romar §5.1 reason code backed by the vendored fixture

    @Test("invalid_signature: a corrupted-bytes frame fails the Ed25519 check")
    func invalidSignature() throws {
        let (frame, registry, tempDir, context) = try setup(for: try fixtureVector(named: "invalid_signature"))
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        #expect(throws: PeerVerificationError(reason: .invalidSignature, envelopeId: nil)) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    // Review Focus: a frame claiming `clomp` but whose key was never enrolled (this vector's
    // `pubkeys` is empty) — `unknown_key`, not any kind of partial trust.
    @Test("unknown_key: a principal with no enrolled key is rejected")
    func unknownKey() throws {
        let (frame, registry, tempDir, context) = try setup(for: try fixtureVector(named: "unknown_key"))
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        #expect(throws: PeerVerificationError(reason: .unknownKey, envelopeId: nil)) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    // Review Focus (the brief's own named case, distinct from the vendored vector above): the
    // `unknown_key` vendored vector has NO key enrolled anywhere, which doesn't actually exercise
    // cross-principal isolation. This test enrolls a REAL key under `rune`, then signs a frame
    // that CLAIMS principal `clomp` with that rune-registered key. `resolve(principal: "clomp",
    // keyId: nil)` must look strictly within clomp's own (empty) keyset and never find rune's key
    // just because a valid Ed25519 signature happens to exist for it — a signature that would
    // genuinely verify is not itself proof of the claimed identity.
    @Test("unknown_key: a frame claiming clomp but signed with a key registered only under rune")
    func unknownKeyCrossPrincipalIsolation() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let runeKey = try enrolledKey(profile: "rune", in: registry) // clomp.json never gets a key
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Self.iso(now)
        let envelope = Data("""
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"cancel","envelopeId":"cross-principal-id-1","ts":"\(ts)"}
        """.utf8)
        let frame = PeerSigner(key: runeKey).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)
        #expect(throws: PeerVerificationError(reason: .unknownKey, envelopeId: nil)) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    @Test("recipient_mismatch: envelope addressed to iris, context self-profile is rune")
    func recipientMismatch() throws {
        let (frame, registry, tempDir, context) = try setup(for: try fixtureVector(named: "recipient_mismatch"))
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        #expect(throws: PeerVerificationError(reason: .recipientMismatch, envelopeId: "conformance-vector-0001")) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    // Review Focus: a signature that genuinely verifies under a real registered key (rune's) is
    // still rejected when the envelope's own `from.profile` (clomp) doesn't match the signer's
    // claimed principal (rune). A valid signature from a known key is not itself a sender claim.
    @Test("principal_mismatch: a valid signature from rune's key over an envelope claiming to be from clomp")
    func principalMismatch() throws {
        let (frame, registry, tempDir, context) = try setup(for: try fixtureVector(named: "principal_mismatch"))
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        #expect(throws: PeerVerificationError(reason: .principalMismatch, envelopeId: "conformance-vector-0001")) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    @Test("duplicate_key: the vendored frame's top-level protocol key is repeated")
    func duplicateKeyVendoredVector() throws {
        let (frame, registry, tempDir, context) = try setup(for: try fixtureVector(named: "duplicate_key"))
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        #expect(throws: PeerVerificationError(reason: .duplicateKey, envelopeId: nil)) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    @Test("deadline_missing: a message with no deadline field in payload.metadata")
    func deadlineMissing() throws {
        let (frame, registry, tempDir, context) = try setup(for: try fixtureVector(named: "deadline_missing"))
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        #expect(throws: PeerVerificationError(reason: .deadlineMissing, envelopeId: "conformance-vector-0001")) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    @Test("deadline_expired: now is already past the message's deadline")
    func deadlineExpired() throws {
        let (frame, registry, tempDir, context) = try setup(for: try fixtureVector(named: "deadline_expired"))
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        #expect(throws: PeerVerificationError(reason: .deadlineExpired, envelopeId: "conformance-vector-0001")) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    @Test("deadline_over_cap: the message's deadline is more than 24h past its ts")
    func deadlineOverCap() throws {
        let (frame, registry, tempDir, context) = try setup(for: try fixtureVector(named: "deadline_over_cap"))
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        #expect(throws: PeerVerificationError(reason: .deadlineOverCap, envelopeId: "conformance-vector-0001")) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    @Test("ts_in_future: the vendored vector's ts is ahead of now by more than the tolerance")
    func tsInFutureVendoredVector() throws {
        let (frame, registry, tempDir, context) = try setup(for: try fixtureVector(named: "ts_in_future"))
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        #expect(throws: PeerVerificationError(reason: .tsInFuture, envelopeId: "conformance-vector-0001")) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    @Test("ts_missing: ts is JSON null, which decode treats as absent")
    func tsMissing() throws {
        let (frame, registry, tempDir, context) = try setup(for: try fixtureVector(named: "ts_missing"))
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        #expect(throws: PeerVerificationError(reason: .tsMissing, envelopeId: nil)) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    @Test("ts_invalid: ts uses a space instead of T, failing the RFC-3339 grammar")
    func tsInvalid() throws {
        let (frame, registry, tempDir, context) = try setup(for: try fixtureVector(named: "ts_invalid"))
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        #expect(throws: PeerVerificationError(reason: .tsInvalid, envelopeId: "conformance-vector-0001")) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    @Test("channel_kind_mismatch: a message-kind frame delivered on the events channel")
    func channelKindMismatch() throws {
        let (frame, registry, tempDir, context) = try setup(for: try fixtureVector(named: "channel_kind_mismatch"), channel: .events)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        #expect(throws: PeerVerificationError(reason: .channelKindMismatch, envelopeId: "conformance-vector-0001")) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    @Test("gateway_attested_rejected: verifiedBy a2a-gateway is always rejected, with no opt-in anywhere in this type")
    func gatewayAttestedRejected() throws {
        let (frame, registry, tempDir, context) = try setup(for: try fixtureVector(named: "gateway_attested_rejected"))
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        #expect(throws: PeerVerificationError(reason: .gatewayAttestedRejected, envelopeId: nil)) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    // MARK: - envelope_id_missing
    //
    // Resolved via iris-planner, sourced from romar §5.1: `envelopeId` MUST be present, non-empty,
    // AND at least 16 characters, counted in Unicode scalars (matching romar's own Python `len()`,
    // which counts code points, not Swift grapheme clusters) — no charset or UUID requirement,
    // just a length floor. That's why the vendored vector's `"short"` (5 scalars) is rejected while
    // the baseline `"conformance-vector-0001"` (23 scalars) clears this check.

    @Test("envelope_id_missing: decode throws missingRequiredField(\"envelopeId\") for an absent id")
    func envelopeIdMissingViaDecodeFailure() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = try enrolledKey(profile: "clomp", in: registry)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Self.iso(now)
        // No "envelopeId" key at all.
        let envelope = Data("""
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"cancel","ts":"\(ts)"}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)
        #expect(throws: PeerVerificationError(reason: .envelopeIdMissing, envelopeId: nil)) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    // Now driven by the vendored fixture's real signed frame, rather than a hand-built one: its
    // `envelopeId: "short"` (5 scalars) is rejected by the 16-scalar floor.
    @Test("envelope_id_missing: the vendored fixture's own 5-scalar envelopeId (\"short\") is rejected")
    func envelopeIdMissingVendoredVector() throws {
        let (frame, registry, tempDir, context) = try setup(for: try fixtureVector(named: "envelope_id_missing"))
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        #expect(throws: PeerVerificationError(reason: .envelopeIdMissing, envelopeId: nil)) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    // Pins the boundary itself (not just "the fixture's 23-scalar baseline happens to pass"): 16
    // scalars exactly clears the floor and the frame is admitted end-to-end; 15 scalars rejects.
    @Test("envelopeId at exactly the 16-scalar floor is admitted; 15 scalars rejects with envelope_id_missing")
    func envelopeIdLengthBoundary() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = try enrolledKey(profile: "clomp", in: registry)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Self.iso(now)
        let deadline = Self.iso(now.addingTimeInterval(3600))

        func envelope(envelopeId: String) -> Data {
            Data("""
            {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"message","envelopeId":"\(envelopeId)","ts":"\(ts)","payload":{"metadata":{"deadline":"\(deadline)"}}}
            """.utf8)
        }
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)

        let sixteenScalars = "sixteen-chars-ok"
        #expect(sixteenScalars.unicodeScalars.count == 16)
        let passFrame = PeerSigner(key: key).sign(envelopeBytes: envelope(envelopeId: sixteenScalars), principal: "clomp", keyId: nil)
        let passed = try verifier.verifyAndAdmit(passFrame, context: context, decode: Self.decodeTestEnvelope)
        #expect(passed.envelopeId == sixteenScalars)

        let fifteenScalars = "fifteen-chars-x"
        #expect(fifteenScalars.unicodeScalars.count == 15)
        let failFrame = PeerSigner(key: key).sign(envelopeBytes: envelope(envelopeId: fifteenScalars), principal: "clomp", keyId: nil)
        #expect(throws: PeerVerificationError(reason: .envelopeIdMissing, envelopeId: nil)) {
            _ = try verifier.verifyAndAdmit(failFrame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    // MARK: - The four codes with no vendored vector

    @Test("events_request_mismatch: an .events frame with outstanding == nil is itself a reject")
    func eventsMismatchNoOutstanding() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = try enrolledKey(profile: "clomp", in: registry)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Self.iso(now)
        let envelope = Data("""
        {"from":{"profile":"clomp"},"kind":"status-update","envelopeId":"ev-1","ts":"\(ts)","taskId":"task-1"}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let context = VerificationContext(selfProfile: "iris", channel: .events, outstanding: nil, now: now)
        #expect(throws: PeerVerificationError(reason: .eventsRequestMismatch, envelopeId: "ev-1")) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    @Test("events_request_mismatch: an .events frame whose taskId doesn't match the OutstandingRequest")
    func eventsMismatchWrongTask() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = try enrolledKey(profile: "clomp", in: registry)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Self.iso(now)
        let envelope = Data("""
        {"from":{"profile":"clomp"},"kind":"artifact-update","envelopeId":"ev-2","ts":"\(ts)","taskId":"task-actual"}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let outstanding = OutstandingRequest(addressee: "clomp", taskId: "task-expected", correlationId: nil)
        let context = VerificationContext(selfProfile: "iris", channel: .events, outstanding: outstanding, now: now)
        #expect(throws: PeerVerificationError(reason: .eventsRequestMismatch, envelopeId: "ev-2")) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    @Test(".events frame whose taskId and addressee match the OutstandingRequest is admitted")
    func eventsBindingMatches() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = try enrolledKey(profile: "clomp", in: registry)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Self.iso(now)
        let envelope = Data("""
        {"from":{"profile":"clomp"},"kind":"status-update","envelopeId":"events-binding-id-3","ts":"\(ts)","taskId":"task-1","correlationId":"corr-1"}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let outstanding = OutstandingRequest(addressee: "clomp", taskId: "task-1", correlationId: "corr-1")
        let context = VerificationContext(selfProfile: "iris", channel: .events, outstanding: outstanding, now: now)
        let result = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        #expect(result.envelopeId == "events-binding-id-3")
    }

    @Test("duplicate_envelope_id: the same id admitted twice rejects the second call")
    func duplicateEnvelopeId() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = try enrolledKey(profile: "clomp", in: registry)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Self.iso(now)
        let deadline = Self.iso(now.addingTimeInterval(3600))
        let envelope = Data("""
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"message","envelopeId":"dup-replay-id-0001","ts":"\(ts)","payload":{"metadata":{"deadline":"\(deadline)"}}}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)

        let first = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        #expect(first.envelopeId == "dup-replay-id-0001")

        #expect(throws: PeerVerificationError(reason: .duplicateEnvelopeId, envelopeId: "dup-replay-id-0001")) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    @Test("seen_set_full: the store's .full throw maps to seen_set_full")
    func seenSetFull() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = try enrolledKey(profile: "clomp", in: registry)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Self.iso(now)
        let deadline = Self.iso(now.addingTimeInterval(3600))
        let envelope = Data("""
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"message","envelopeId":"seen-set-full-id-1","ts":"\(ts)","payload":{"metadata":{"deadline":"\(deadline)"}}}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet(forcedError: .full))
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)
        #expect(throws: PeerVerificationError(reason: .seenSetFull, envelopeId: "seen-set-full-id-1")) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    @Test("seen_set_unavailable: the store's .unavailable throw maps to seen_set_unavailable")
    func seenSetUnavailable() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = try enrolledKey(profile: "clomp", in: registry)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Self.iso(now)
        let deadline = Self.iso(now.addingTimeInterval(3600))
        let envelope = Data("""
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"message","envelopeId":"seen-set-unavail-id-1","ts":"\(ts)","payload":{"metadata":{"deadline":"\(deadline)"}}}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet(forcedError: .unavailable))
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)
        #expect(throws: PeerVerificationError(reason: .seenSetUnavailable, envelopeId: "seen-set-unavail-id-1")) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    // MARK: - Non-message freshness bound (folded into deadlineExpired — see report)

    @Test("a non-message kind with no deadline field is admitted when fresh")
    func nonMessageKindAdmittedWithNoDeadline() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = try enrolledKey(profile: "clomp", in: registry)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Self.iso(now)
        let envelope = Data("""
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"cancel","envelopeId":"cancel-fresh-id-1","ts":"\(ts)"}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)
        let result = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        #expect(result.kind == "cancel")
        #expect(result.deadline == nil)
    }

    @Test("a non-message kind rejects once now passes ts + 24h, with no deadline field involved")
    func nonMessageKindRejectedPastTheNonMessageBound() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = try enrolledKey(profile: "clomp", in: registry)
        let ts = Date(timeIntervalSince1970: 1_800_000_000)
        let tsString = Self.iso(ts)
        let now = ts.addingTimeInterval(24 * 60 * 60 + 1) // one second past the implicit bound
        let envelope = Data("""
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"cancel","envelopeId":"cancel-expired-id-2","ts":"\(tsString)"}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)
        #expect(throws: PeerVerificationError(reason: .deadlineExpired, envelopeId: "cancel-expired-id-2")) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    // MARK: - 60-second clock-skew boundary (spec-sourced, not just "<=120s" per the fixture)

    @Test("ts exactly 60s ahead of now passes; 61s ahead rejects with ts_in_future")
    func clockSkewBoundary() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = try enrolledKey(profile: "clomp", in: registry)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        func frame(secondsAhead: TimeInterval, envelopeId: String) -> (SignedFrameParts, VerificationContext) {
            let ts = now.addingTimeInterval(secondsAhead)
            let tsString = Self.iso(ts)
            let deadline = Self.iso(ts.addingTimeInterval(3600))
            let envelope = Data("""
            {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"message","envelopeId":"\(envelopeId)","ts":"\(tsString)","payload":{"metadata":{"deadline":"\(deadline)"}}}
            """.utf8)
            let signed = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
            let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)
            return (signed, context)
        }

        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())

        let (passFrame, passContext) = frame(secondsAhead: 60, envelopeId: "skew-pass-id-0001")
        let passed = try verifier.verifyAndAdmit(passFrame, context: passContext, decode: Self.decodeTestEnvelope)
        #expect(passed.envelopeId == "skew-pass-id-0001")

        let (failFrame, failContext) = frame(secondsAhead: 61, envelopeId: "skew-fail-id-0002")
        #expect(throws: PeerVerificationError(reason: .tsInFuture, envelopeId: "skew-fail-id-0002")) {
            _ = try verifier.verifyAndAdmit(failFrame, context: failContext, decode: Self.decodeTestEnvelope)
        }
    }

    // MARK: - Verify-before-parse ordering

    @Test("a naive first-wins decode closure still yields duplicate_key: the core scans B itself")
    func firstWinsDecodeStillYieldsDuplicateKey() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = try enrolledKey(profile: "clomp", in: registry)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Self.iso(now)
        // Top-level "protocol" key repeated — a naive JSONSerialization-backed decode silently
        // keeps the first value and would never notice the repeat at all.
        let envelope = Data("""
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"message","envelopeId":"dup-1","ts":"\(ts)","protocol":"a2a-jetstream/0.4","protocol":"a2a-jetstream/0.4"}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)

        var decodeCalls = 0
        let countingDecode: (Data) throws -> TestEnvelope = { data in
            decodeCalls += 1
            return try Self.decodeTestEnvelope(data)
        }

        #expect(throws: PeerVerificationError(reason: .duplicateKey, envelopeId: nil)) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: countingDecode)
        }
        #expect(decodeCalls == 0)
    }

    @Test("the decode closure is never invoked on a bad signature")
    func decodeNotInvokedOnBadSignature() throws {
        let (frame, registry, tempDir, context) = try setup(for: try fixtureVector(named: "invalid_signature"))
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())

        var decodeCalled = false
        let flaggingDecode: (Data) throws -> TestEnvelope = { data in
            decodeCalled = true
            return try Self.decodeTestEnvelope(data)
        }

        #expect(throws: PeerVerificationError(reason: .invalidSignature, envelopeId: nil)) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: flaggingDecode)
        }
        #expect(!decodeCalled)
    }

    // The brief's own ordering stress test: a frame with a bad signature AND a duplicate top-level
    // key AND an unrecognized kind, all at once. If check order is right, it fails on
    // `invalid_signature` — the first check in romar's order among the three this frame
    // violates — and the decode closure (which would be the only way to even see the bad `kind`)
    // is never invoked at all.
    @Test("check order: bad signature + duplicate key + unknown kind all at once still fails on invalid_signature, decode never called")
    func orderingStressTest() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = try enrolledKey(profile: "clomp", in: registry)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Self.iso(now)
        // kind is not in any channel's allowed set, AND "dup" is repeated at the top level.
        let envelope = Data("""
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"not-a-real-kind","envelopeId":"order-1","ts":"\(ts)","dup":"a","dup":"b"}
        """.utf8)
        var frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        var corruptedSignature = frame.signature
        corruptedSignature[0] ^= 0xFF
        frame = SignedFrameParts(
            principal: frame.principal,
            keyId: frame.keyId,
            verifiedBy: frame.verifiedBy,
            signature: corruptedSignature,
            envelopeBytes: frame.envelopeBytes
        )

        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)

        var decodeCalls = 0
        let countingDecode: (Data) throws -> TestEnvelope = { data in
            decodeCalls += 1
            return try Self.decodeTestEnvelope(data)
        }

        #expect(throws: PeerVerificationError(reason: .invalidSignature, envelopeId: nil)) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: countingDecode)
        }
        #expect(decodeCalls == 0)
    }

    // MARK: - RegistryError.unavailable propagates as-is (fail-closed, never relabelled unknown_key)

    @Test("a corrupt registry file propagates RegistryError.unavailable rather than reading as unknown_key")
    func corruptRegistryFailsClosedNotUnknownKey() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: registry.directory, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: registry.directory.appendingPathComponent("clomp.json"))

        let key = IrisSigningKey()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Self.iso(now)
        let envelope = Data("""
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"cancel","envelopeId":"corrupt-1","ts":"\(ts)"}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)

        #expect(throws: RegistryError.unavailable) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }

    // MARK: - .inbox with a non-nil OutstandingRequest is a caller error

    @Test(".inbox with a non-nil OutstandingRequest is rejected as a caller-contract violation")
    func inboxWithOutstandingIsCallerError() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = try enrolledKey(profile: "clomp", in: registry)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Self.iso(now)
        let deadline = Self.iso(now.addingTimeInterval(3600))
        let envelope = Data("""
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"message","envelopeId":"caller-err-1","ts":"\(ts)","payload":{"metadata":{"deadline":"\(deadline)"}}}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let outstanding = OutstandingRequest(addressee: "clomp", taskId: "task-1", correlationId: nil)
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: outstanding, now: now)

        #expect(throws: VerifierUsageError.self) {
            _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        }
    }
}

/// Direct tests against `StrictJSON.rejectDuplicateKeys` itself, below the `verifyAndAdmit`
/// level (review follow-up, #974 H4 Task 4). An independent review harness built standalone
/// against the scanner (never touching `PeerSignatureVerifier`) found that earlier versions
/// silently returned — i.e. reported "no duplicate found," which `verifyAndAdmit` reads as
/// "proceed" — on bytes that were not valid, strict, bare-UTF-8 JSON at all: a UTF-8 BOM, UTF-16
/// or UTF-32-encoded payloads, and JSON5-style unquoted keys all decode cleanly under
/// `JSONSerialization`/`JSONDecoder`, so a scanner that stayed quiet on "not quite JSON" bytes let
/// exactly those bypass the duplicate-key guarantee this type exists to give. The same harness
/// found a crash (an unvalidated surrogate-pair low-half underflowing a `UInt32` subtraction,
/// reachable from any string value in a legitimately signed envelope) and a stack overflow from
/// unbounded recursion on deeply nested input. These tests exercise `StrictJSON` directly so each
/// of those three bug classes has a test that would have caught it without going through a full
/// signed frame.
@Suite("StrictJSON duplicate-key scanner (#974 H4 Task 4 — review follow-up)")
struct StrictJSONTests {
    private static let validJSON = #"{"from":{"profile":"clomp"},"kind":"message"}"#

    // MARK: - Encoding/grammar bypasses (Critical)

    @Test("a UTF-8 BOM-prefixed payload is rejected, not silently accepted")
    func utf8BOMRejected() throws {
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(Data(Self.validJSON.utf8))
        #expect(throws: StrictJSONError.invalidEncoding) {
            try StrictJSON.rejectDuplicateKeys(bytes)
        }
    }

    @Test("UTF-16LE-encoded JSON is rejected, not silently accepted")
    func utf16LERejected() throws {
        let data = try #require(Self.validJSON.data(using: .utf16LittleEndian))
        #expect(throws: StrictJSONError.self) {
            try StrictJSON.rejectDuplicateKeys(data)
        }
    }

    @Test("UTF-16BE-encoded JSON is rejected, not silently accepted")
    func utf16BERejected() throws {
        let data = try #require(Self.validJSON.data(using: .utf16BigEndian))
        #expect(throws: StrictJSONError.self) {
            try StrictJSON.rejectDuplicateKeys(data)
        }
    }

    @Test("UTF-32LE-encoded JSON is rejected, not silently accepted")
    func utf32LERejected() throws {
        let data = try #require(Self.validJSON.data(using: .utf32LittleEndian))
        #expect(throws: StrictJSONError.self) {
            try StrictJSON.rejectDuplicateKeys(data)
        }
    }

    @Test("JSON5-style unquoted keys are rejected, not silently accepted")
    func json5UnquotedKeysRejected() throws {
        let data = Data(#"{from:"clomp",kind:"message"}"#.utf8)
        #expect(throws: StrictJSONError.self) {
            try StrictJSON.rejectDuplicateKeys(data)
        }
    }

    @Test("trailing garbage after the top-level value is rejected")
    func trailingGarbageRejected() throws {
        let data = Data(#"{"a":1} garbage"#.utf8)
        #expect(throws: StrictJSONError.malformed) {
            try StrictJSON.rejectDuplicateKeys(data)
        }
    }

    @Test("well-formed, strict UTF-8 JSON with no duplicate keys is accepted")
    func wellFormedJSONAccepted() throws {
        try StrictJSON.rejectDuplicateKeys(Data(Self.validJSON.utf8))
    }

    // MARK: - Surrogate-pair crash (Important)

    /// Builds the *literal source text* `\` + `u` + `hex` — e.g. `literalUnicodeEscape("D800")`
    /// returns the 6-character string `\uD800`, never the single (invalid, since D800 is a lone
    /// surrogate) Unicode scalar that text would decode to if it appeared as a real escape.
    ///
    /// Review finding: a Swift string literal containing `\uD800` would not even compile (D800 is
    /// not a valid standalone Unicode scalar), and this project's earlier version of these tests
    /// used `\uD800A` — a *literal* `A` character right after the one escape, not a second `\u`
    /// escape — which exercises a different guard (`appendUnicodeEscape`'s "no `\u` at all follows
    /// the high surrogate" branch) than the one the underflow bug actually lived in (the "low
    /// surrogate's *value* is out of `0xDC00...0xDFFF` range" branch, which needs a second,
    /// separate `\u` escape to reach). A mutation check (temporarily deleting that range guard)
    /// proved the old tests kept passing even with the guard gone — i.e. they gave zero coverage
    /// of the actual fix. Building the escape as plain-ASCII text concatenation — `"\u{5C}"` is
    /// itself a safe, unambiguous, non-surrogate scalar escape for the backslash character alone,
    /// resolved at compile time — removes any dependence on how a `\uXXXX`-shaped substring inside
    /// a string literal might otherwise be written or transformed, and makes the intended two
    /// separate escapes unambiguous in the resulting bytes.
    private static func literalUnicodeEscape(_ hex: String) -> String {
        "\u{5C}u" + hex
    }

    @Test("a malformed surrogate-pair escape throws instead of crashing")
    func malformedSurrogatePairThrowsNotCrashes() throws {
        // The exact original underflow shape: a high surrogate (\uD800) immediately followed by a
        // SECOND, separate \u escape whose value (A = 'A') is not in the low-surrogate range
        // 0xDC00...0xDFFF — this is what used to compute `UInt32(0x0041) - 0xDC00`, an unsigned
        // underflow, and trap the process (SIGTRAP).
        let escapes = Self.literalUnicodeEscape("D800") + Self.literalUnicodeEscape("0041")
        let data = Data("{\"k\":\"\(escapes)\"}".utf8)
        #expect(throws: StrictJSONError.malformed) {
            try StrictJSON.rejectDuplicateKeys(data)
        }
    }

    @Test("an unpaired high surrogate with no following \\u escape at all throws")
    func unpairedHighSurrogateThrows() throws {
        let escape = Self.literalUnicodeEscape("D800")
        let data = Data("{\"k\":\"\(escape)\"}".utf8)
        #expect(throws: StrictJSONError.malformed) {
            try StrictJSON.rejectDuplicateKeys(data)
        }
    }

    @Test("a lone low surrogate with no preceding high surrogate throws")
    func unpairedLowSurrogateThrows() throws {
        let escape = Self.literalUnicodeEscape("DC00")
        let data = Data("{\"k\":\"\(escape)\"}".utf8)
        #expect(throws: StrictJSONError.malformed) {
            try StrictJSON.rejectDuplicateKeys(data)
        }
    }

    @Test("a correctly paired high/low surrogate escape (an astral character) is accepted")
    func validSurrogatePairAccepted() throws {
        // The ACTUAL \u-escaped surrogate pair for U+1F600 (😀): \uD83D\uDE00, built the same
        // literal-text way as the other tests in this group — not a raw UTF-8 emoji character
        // embedded directly, which would bypass the \u-escape-combining code (`appendUnicodeEscape`)
        // entirely via `scanString`'s plain non-backslash byte-passthrough path, and so would never
        // actually exercise the pair-combining logic this test means to cover.
        let escapes = Self.literalUnicodeEscape("D83D") + Self.literalUnicodeEscape("DE00")
        let data = Data("{\"k\":\"\(escapes)\"}".utf8)
        try StrictJSON.rejectDuplicateKeys(data)
    }

    // MARK: - Escaped/raw key collision for duplicate detection (review follow-up)
    //
    // `scanString` decodes escapes (rather than comparing raw bytes between the quotes)
    // specifically so two keys that are the *same character* written two different ways still
    // collide as one key for duplicate detection — e.g. `{"a":1,"a":2}` where the second "a" is
    // written as `a`. Nothing exercised that property directly: a mutant that combines a
    // surrogate pair with a different, still-valid-but-wrong formula would pass every other test
    // in this file, because none of them actually relies on two differently-written keys landing
    // on the same decoded string.

    @Test("an escaped key collides with its raw equivalent for duplicate detection")
    func escapedKeyCollidesWithRawEquivalent() throws {
        // One raw "a", one "a" written as a (built via literalUnicodeEscape, never typed
        // directly as a \uXXXX span in source — see that helper's own doc comment for why).
        let escapedA = Self.literalUnicodeEscape("0061")
        let data = Data("{\"a\":1,\"\(escapedA)\":2}".utf8)
        #expect(throws: StrictJSONError.duplicateKey) {
            try StrictJSON.rejectDuplicateKeys(data)
        }
    }

    @Test("an escaped astral key collides with its raw UTF-8 equivalent for duplicate detection")
    func escapedAstralKeyCollidesWithRawEquivalent() throws {
        // One key is the raw UTF-8 emoji character directly (safe to type literally — it is not
        // a \uXXXX-shaped escape span); the other is the same character built as an escaped
        // surrogate pair via `literalUnicodeEscape`. Both must decode to the identical key.
        let escapedEmoji = Self.literalUnicodeEscape("D83D") + Self.literalUnicodeEscape("DE00")
        let data = Data("{\"😀\":1,\"\(escapedEmoji)\":2}".utf8)
        #expect(throws: StrictJSONError.duplicateKey) {
            try StrictJSON.rejectDuplicateKeys(data)
        }
    }

    // MARK: - Unbounded recursion / stack overflow (Important)

    @Test("nesting exactly at DuplicateKeyScanner.maxDepth (64) is accepted; one level past it throws tooDeep")
    func depthLimitBoundary() throws {
        func nested(depth: Int) -> Data {
            var s = String(repeating: "[", count: depth)
            s += "1"
            s += String(repeating: "]", count: depth)
            return Data(s.utf8)
        }

        // Mirrors `DuplicateKeyScanner.maxDepth` (not importable — it's `private`), the same way
        // the clock-skew test hardcodes romar's 60s tolerance rather than reaching into the
        // implementation. Exactly at the cap: each `[` increments the scanner's depth counter by
        // one on entry, so 64 nested arrays peaks the counter at exactly 64, which the guard
        // `depth <= maxDepth` still admits.
        try StrictJSON.rejectDuplicateKeys(nested(depth: 64))

        // One level past it: the 65th `[` increments the counter to 65, which the same guard now
        // rejects.
        #expect(throws: StrictJSONError.tooDeep) {
            try StrictJSON.rejectDuplicateKeys(nested(depth: 65))
        }
    }

    @Test("~20,000 nested brackets (the depth that reproduced the original stack-overflow crash) still just throws tooDeep")
    func depthLimitStopsTheOriginalCrashShape() throws {
        func nested(depth: Int) -> Data {
            var s = String(repeating: "[", count: depth)
            s += "1"
            s += String(repeating: "]", count: depth)
            return Data(s.utf8)
        }
        #expect(throws: StrictJSONError.tooDeep) {
            try StrictJSON.rejectDuplicateKeys(nested(depth: 20_000))
        }
    }
}
