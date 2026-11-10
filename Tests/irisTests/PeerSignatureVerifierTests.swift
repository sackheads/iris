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
    /// keeps the *last* value for a repeated object key. Standing in for "what a transport that
    /// never heard of `StrictJSON` would write." Used directly by the "last-wins decode still
    /// yields duplicate-key" test below: the core's own scan must catch what this decoder cannot.
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
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"message","envelopeId":"happy-path-1","ts":"\(ts)","payload":{"metadata":{"deadline":"\(deadline)"}},"taskId":"task-1","correlationId":"corr-1"}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)

        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)
        let result = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)

        #expect(result.envelopeId == "happy-path-1")
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

    // MARK: - envelope_id_missing (NOT the vendored vector — see report)
    //
    // The vendored `envelope_id_missing` vector's only change from the baseline frame is
    // `envelopeId: "short"` (5 ASCII characters) in place of `"conformance-vector-0001"` (24).
    // "short" is present, non-null and non-empty, so it decodes successfully as a `String` and
    // carries no structural signal this task's authoritative value-dump defines a check for —
    // romar evidently enforces some further format or length rule on `envelopeId` that wasn't
    // included in that dump. Rather than invent a threshold, this test exercises the one
    // non-arbitrary "missing" semantics available from the given interfaces: `decode` throwing
    // `FrameDecodeError.missingRequiredField("envelopeId")` for a genuinely absent/empty id. See
    // the task report for this gap.
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
        {"from":{"profile":"clomp"},"kind":"status-update","envelopeId":"ev-3","ts":"\(ts)","taskId":"task-1","correlationId":"corr-1"}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let outstanding = OutstandingRequest(addressee: "clomp", taskId: "task-1", correlationId: "corr-1")
        let context = VerificationContext(selfProfile: "iris", channel: .events, outstanding: outstanding, now: now)
        let result = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        #expect(result.envelopeId == "ev-3")
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
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"message","envelopeId":"dup-replay-1","ts":"\(ts)","payload":{"metadata":{"deadline":"\(deadline)"}}}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)

        let first = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        #expect(first.envelopeId == "dup-replay-1")

        #expect(throws: PeerVerificationError(reason: .duplicateEnvelopeId, envelopeId: "dup-replay-1")) {
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
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"message","envelopeId":"full-1","ts":"\(ts)","payload":{"metadata":{"deadline":"\(deadline)"}}}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet(forcedError: .full))
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)
        #expect(throws: PeerVerificationError(reason: .seenSetFull, envelopeId: "full-1")) {
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
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"message","envelopeId":"unavail-1","ts":"\(ts)","payload":{"metadata":{"deadline":"\(deadline)"}}}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet(forcedError: .unavailable))
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)
        #expect(throws: PeerVerificationError(reason: .seenSetUnavailable, envelopeId: "unavail-1")) {
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
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"cancel","envelopeId":"cancel-1","ts":"\(ts)"}
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
        {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"cancel","envelopeId":"cancel-2","ts":"\(tsString)"}
        """.utf8)
        let frame = PeerSigner(key: key).sign(envelopeBytes: envelope, principal: "clomp", keyId: nil)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)
        #expect(throws: PeerVerificationError(reason: .deadlineExpired, envelopeId: "cancel-2")) {
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

        let (passFrame, passContext) = frame(secondsAhead: 60, envelopeId: "skew-pass")
        let passed = try verifier.verifyAndAdmit(passFrame, context: passContext, decode: Self.decodeTestEnvelope)
        #expect(passed.envelopeId == "skew-pass")

        let (failFrame, failContext) = frame(secondsAhead: 61, envelopeId: "skew-fail")
        #expect(throws: PeerVerificationError(reason: .tsInFuture, envelopeId: "skew-fail")) {
            _ = try verifier.verifyAndAdmit(failFrame, context: failContext, decode: Self.decodeTestEnvelope)
        }
    }

    // MARK: - Verify-before-parse ordering

    @Test("a deliberately last-wins decode closure still yields duplicate_key: the core scans B itself")
    func lastWinsDecodeStillYieldsDuplicateKey() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = try enrolledKey(profile: "clomp", in: registry)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Self.iso(now)
        // Top-level "protocol" key repeated — a naive JSONSerialization-backed decode silently
        // keeps the last value and would never notice.
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
