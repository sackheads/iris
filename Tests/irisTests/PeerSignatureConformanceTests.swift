import Foundation
import CryptoKit
import Testing
@testable import IrisKit

/// #974 H4 Task 6: the vendored romar conformance vector, driven generically rather than
/// hand-built per case. `PeerSignerTests.swift` and `PeerSignatureVerifierTests.swift` (Tasks 3
/// and 4) already cover the fixture's individual vectors with purpose-built Swift test functions,
/// one per vector; this file's distinct value is a single loop over the fixture's actual
/// `negative_vectors` JSON array, so a vector romar adds tomorrow is exercised without a code
/// change here. Every `now` is injected into `VerificationContext`, never read from the system
/// clock (AGENTS.md Invariant 7), and every registry lives under its own temp `IrisPaths(root:)`.
@Suite("Peer-signature conformance vector (#974 H4 Task 6)")
struct PeerSignatureConformanceTests {

    // MARK: - Fixture decoding

    /// Mirrors `Fixtures/peer-signature-conformance.json`'s exact shape — both the positive
    /// vector's top-level fields and the `negative_vectors` array, each entry's `frame.identity`
    /// and `frame.envelopeBytes`, `self_profile`, `expected_kind` and `pubkeys` — so the generic
    /// loop below decodes real JSON structure, not a Swift literal standing in for it.
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
            let reason: String
            let frame: Frame
            let selfProfile: String
            let expectedKind: [String]?
            let pubkeys: [String: String]
            let now: String

            enum CodingKeys: String, CodingKey {
                case name, reason, frame, pubkeys, now
                case selfProfile = "self_profile"
                case expectedKind = "expected_kind"
            }
        }

        let protocolDomain: String
        let bHex: String
        let signingInputHex: String
        let publicHex: String
        let privateHex: String
        let sigB64: String
        let negativeVectors: [NegativeVector]

        enum CodingKeys: String, CodingKey {
            case protocolDomain = "protocol_domain"
            case bHex = "B_hex"
            case signingInputHex = "signing_input_hex"
            case publicHex = "public_hex"
            case privateHex = "private_hex"
            case sigB64 = "sig_b64"
            case negativeVectors = "negative_vectors"
        }
    }

    private static func dataFromHex(_ hex: String) -> Data {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    private static func loadFixture() throws -> ConformanceFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/peer-signature-conformance.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ConformanceFixture.self, from: data)
    }

    // MARK: - Local, non-vendored negative vector (events_request_mismatch — romar omits it)
    //
    // Built as real JSON (JSONSerialization-encoded, then decoded back through the exact same
    // `ConformanceFixture.NegativeVector` type the vendored vectors decode into) rather than a
    // hand-assembled Swift struct literal, so it provably round-trips through the identical JSON
    // shape before it ever reaches the generic loop. `frame.identity.sig` and `frame.envelopeBytes`
    // are produced by actually signing with a freshly generated `IrisSigningKey` via `PeerSigner`
    // (Task 1/3) — romar's own 14 vectors are pre-signed with a fixture keypair; this one is signed
    // here because it has no romar-provided signature to borrow.
    private static func localEventsMismatchVector() throws -> ConformanceFixture.NegativeVector {
        let key = IrisSigningKey()
        let principal = "clomp-local"
        let ts = "2026-11-09T15:30:00Z"
        let envelopeDict: [String: Any] = [
            "from": ["profile": principal],
            "kind": "status-update",
            "envelopeId": "local-events-mismatch-0001",
            "ts": ts,
            "taskId": "task-actual-local"
        ]
        let envelopeBytes = try JSONSerialization.data(withJSONObject: envelopeDict, options: [.sortedKeys])
        let signedFrame = PeerSigner(key: key).sign(envelopeBytes: envelopeBytes, principal: principal, keyId: nil)

        let vectorDict: [String: Any] = [
            "name": "events_request_mismatch_local",
            "reason": "events_request_mismatch",
            "frame": [
                "identity": [
                    "verifiedBy": signedFrame.verifiedBy,
                    "principal": signedFrame.principal,
                    "sig": signedFrame.signature.base64EncodedString()
                ],
                "envelopeBytes": envelopeBytes.base64EncodedString()
            ],
            "self_profile": "iris",
            "expected_kind": ["status-update", "artifact-update"],
            "pubkeys": [principal: key.publicKeyWireString],
            "now": ts
        ]
        let vectorData = try JSONSerialization.data(withJSONObject: vectorDict)
        return try JSONDecoder().decode(ConformanceFixture.NegativeVector.self, from: vectorData)
    }

    // MARK: - VerifiableEnvelope conformer + naive decode (first-wins on this platform, see below)

    private struct TestEnvelope: VerifiableEnvelope, Equatable {
        let fromProfile: String
        let toProfile: String?
        let kind: String
        let envelopeId: String
        let ts: String
        let deadline: String?
        let taskId: String?
        let correlationId: String?
    }

    private static func decodeTestEnvelope(_ data: Data) throws -> TestEnvelope {
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

    private final class InMemorySeenSet: SeenSetStore, @unchecked Sendable {
        private let lock = NSLock()
        private var seenByPeer: [String: Set<String>] = [:]

        func admit(peer: String, envelopeId: String, retainUntil: Date, maxPerPeer: Int, now: Date) throws -> AdmitResult {
            lock.lock()
            defer { lock.unlock() }
            var ids = seenByPeer[peer, default: []]
            if ids.contains(envelopeId) { return .duplicate }
            guard ids.count < maxPerPeer else { throw SeenSetStoreError.full }
            ids.insert(envelopeId)
            seenByPeer[peer] = ids
            return .fresh
        }
    }

    private func freshRegistry() -> (PeerKeyRegistry, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peer-sig-conformance-\(UUID().uuidString)")
        return (PeerKeyRegistry(paths: IrisPaths(root: tempDir)), tempDir)
    }

    /// `expected_kind` doubles, in the vendored fixture, as the only per-vector signal of which
    /// channel the vector means to exercise: `null` for every vector whose envelope carries a
    /// `message`/`cancel` kind bound for `.inbox`'s rules, and romar's own `allowedKinds` array
    /// for the one vector (`channel_kind_mismatch`) that means `.events`. Deriving the channel
    /// from that field — rather than hand-picking it per vector name — is what lets the loop below
    /// stay generic: a future vector naming `.events`'s kinds here routes itself without a code
    /// change, exactly as this task's local vector does.
    private func channel(for expectedKind: [String]?) throws -> A2AChannel {
        guard let expectedKind else { return .inbox }
        let wanted = Set(expectedKind)
        if wanted == A2AChannel.events.allowedKinds { return .events }
        if wanted == A2AChannel.inbox.allowedKinds { return .inbox }
        throw VerifierUsageError(message: "expected_kind \(expectedKind) matches no known channel's allowedKinds")
    }

    // MARK: - 1. signingInput byte-identical to the fixture's signing_input

    @Test("signingInput over the fixture's positive-vector envelope bytes equals signing_input_hex byte-identically")
    func signingInputMatchesFixtureByteForByte() throws {
        let fixture = try Self.loadFixture()
        let B = Self.dataFromHex(fixture.bHex)
        let expected = Self.dataFromHex(fixture.signingInputHex)

        #expect(fixture.protocolDomain == PeerSignatureDomain.a2a)
        let actual = signingInput(domain: PeerSignatureDomain.a2a, envelopeBytes: B)
        #expect(actual == expected)
    }

    // MARK: - 2. PeerSigner from the fixture's private key verifies against the fixture's public key

    @Test("a PeerSigner built from the fixture's known private key produces a signature that verifies, not byte-equals")
    func signerProducesVerifyingSignatureAgainstFixture() throws {
        let fixture = try Self.loadFixture()
        let seed = Self.dataFromHex(fixture.privateHex)
        #expect(seed.count == 32)
        let key = try #require(IrisSigningKey(base64Seed: seed.base64EncodedString()))

        let B = Self.dataFromHex(fixture.bHex)
        let parts = PeerSigner(key: key).sign(envelopeBytes: B, principal: "clomp", keyId: nil)

        let expectedPublicKey = Self.dataFromHex(fixture.publicHex)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: expectedPublicKey)
        let expectedInput = signingInput(domain: PeerSignatureDomain.a2a, envelopeBytes: B)

        // Verification, never byte-equality: CryptoKit's Ed25519 signing is hedged on this
        // platform (Task 3's finding) — a freshly produced signature over the same key/message
        // is not expected to equal any fixed bytes, including the fixture's own `sig_b64`.
        #expect(publicKey.isValidSignature(parts.signature, for: expectedInput))

        // KAT: the fixture's own externally-produced sig_b64 also verifies against the same
        // domain-separated input and key, confirming cross-implementation interop independent of
        // whatever this signer just produced.
        let fixtureSignature = try #require(Data(base64Encoded: fixture.sigB64))
        #expect(publicKey.isValidSignature(fixtureSignature, for: expectedInput))
    }

    // MARK: - 3. The verifier admits the positive vector end-to-end

    @Test("verifyAndAdmit admits the fixture's positive vector end-to-end")
    func positiveVectorAdmittedEndToEnd() throws {
        let fixture = try Self.loadFixture()
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let publicWire = "ed25519:" + Self.dataFromHex(fixture.publicHex).base64EncodedString()
        try registry.enroll(RegisteredKey(profile: "clomp", keyId: "clomp", publicKey: publicWire))

        let envelopeBytes = Self.dataFromHex(fixture.bHex)
        let signature = try #require(Data(base64Encoded: fixture.sigB64))
        let frame = SignedFrameParts(principal: "clomp", keyId: nil, verifiedBy: "ed25519", signature: signature, envelopeBytes: envelopeBytes)

        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-09T15:30:00Z"))
        let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)
        let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())

        let result = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
        #expect(result.envelopeId == "conformance-vector-0001")
        #expect(result.fromProfile == "clomp")
    }

    // MARK: - 4. The generic loop: every negative vector, vendored plus local, by reason code

    @Test("every negative vector (romar's 14 plus this task's 1 local addition) rejects with exactly its stated reason")
    func everyNegativeVectorRejectsWithStatedReason() throws {
        let fixture = try Self.loadFixture()
        let vectors = fixture.negativeVectors + [try Self.localEventsMismatchVector()]
        #expect(vectors.count == 15)

        for vector in vectors {
            let (registry, tempDir) = freshRegistry()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            for (profile, wire) in vector.pubkeys {
                try registry.enroll(RegisteredKey(profile: profile, keyId: profile, publicKey: wire))
            }

            guard let envelopeBytes = Data(base64Encoded: vector.frame.envelopeBytes),
                  let signature = Data(base64Encoded: vector.frame.identity.sig) else {
                Issue.record("vector \(vector.name): envelopeBytes/sig did not base64-decode")
                continue
            }
            let frame = SignedFrameParts(
                principal: vector.frame.identity.principal,
                keyId: nil,
                verifiedBy: vector.frame.identity.verifiedBy,
                signature: signature,
                envelopeBytes: envelopeBytes
            )

            guard let now = ISO8601DateFormatter().date(from: vector.now) else {
                Issue.record("vector \(vector.name): now (\(vector.now)) did not parse as RFC3339")
                continue
            }
            guard let resolvedChannel = try? channel(for: vector.expectedKind) else {
                Issue.record("vector \(vector.name): expected_kind \(String(describing: vector.expectedKind)) matches no known channel")
                continue
            }
            let context = VerificationContext(selfProfile: vector.selfProfile, channel: resolvedChannel, outstanding: nil, now: now)

            guard let expectedReason = PeerRejectReason(rawValue: vector.reason) else {
                Issue.record("vector \(vector.name): reason \"\(vector.reason)\" is not a known PeerRejectReason raw value")
                continue
            }

            let verifier = PeerSignatureVerifier(registry: registry, seenSet: InMemorySeenSet())
            do {
                _ = try verifier.verifyAndAdmit(frame, context: context, decode: Self.decodeTestEnvelope)
                Issue.record("vector \(vector.name): expected rejection (\(expectedReason)) but was admitted")
            } catch let error as PeerVerificationError {
                #expect(error.reason == expectedReason, "vector \(vector.name)")
            } catch {
                Issue.record("vector \(vector.name): expected PeerVerificationError(\(expectedReason)) but threw \(error)")
            }
        }
    }

    // MARK: - 5. macOS duplicate-key grounding: a naive decode keeps FIRST, the core rejects regardless

    @Test("a naive decode of a repeated top-level key keeps the FIRST value on this platform; the core rejects the same bytes outright")
    func duplicateKeyPlatformGroundingAndCoreRejection() throws {
        let data = Data(#"{"a":"first-value","a":"second-value"}"#.utf8)

        // Pin the actual platform behavior (Task 4's security review measured this empirically:
        // both JSONSerialization and JSONDecoder keep the FIRST value for a duplicate key on this
        // Mac, not the last) rather than assuming either direction.
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let serializationValue = try #require(obj["a"] as? String)
        #expect(serializationValue == "first-value")

        struct Pair: Decodable { let a: String }
        let decoded = try JSONDecoder().decode(Pair.self, from: data)
        #expect(decoded.a == "first-value")

        // Regardless of which value a downstream decoder would have silently picked, the core's
        // own scan — the thing `verifyAndAdmit` actually calls before any decode runs — rejects
        // these bytes outright.
        #expect(throws: StrictJSONError.duplicateKey) {
            try StrictJSON.rejectDuplicateKeys(data)
        }
    }
}
