import Foundation
import CryptoKit
import Testing
@testable import IrisKit

/// Covers #974 H4 Task 3: the domain-separated signing-input codec and the outbound signer built
/// on Task 1's `IrisSigningKey`. A later verifier (not this task) re-derives the same
/// `signingInput` to check incoming signatures against this same construction.
@Suite("Peer-signature signing input and outbound signer (#974 H4)")
struct PeerSignerTests {
    /// Minimal shape of `Fixtures/peer-signature-conformance.json` — only the fields this suite
    /// needs, so a change elsewhere in the fixture can't break decoding here.
    private struct ConformanceVector: Decodable {
        let protocol_domain: String
        let B_hex: String
        let signing_input_hex: String
        let public_hex: String
        let private_hex: String
        let sig_b64: String
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

    private static func loadFixture() throws -> ConformanceVector {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/peer-signature-conformance.json")
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(ConformanceVector.self, from: data)
    }

    @Test("signingInput matches the vendored conformance vector's signing_input byte-for-byte")
    func signingInputMatchesFixture() throws {
        let fixture = try Self.loadFixture()
        let B = Self.dataFromHex(fixture.B_hex)
        let expected = Self.dataFromHex(fixture.signing_input_hex)

        #expect(fixture.protocol_domain == PeerSignatureDomain.a2a)

        let actual = signingInput(domain: PeerSignatureDomain.a2a, envelopeBytes: B)
        #expect(actual == expected)
    }

    @Test("signingInput is domain bytes + newline + the exact envelope bytes, no re-encoding")
    func signingInputConstruction() {
        let domain = "test-domain/1.0"
        let envelope = Data("not-json-just-raw-bytes".utf8)
        let result = signingInput(domain: domain, envelopeBytes: envelope)

        var expected = Data(domain.utf8)
        expected.append(0x0a)
        expected.append(envelope)
        #expect(result == expected)
    }

    @Test("PeerSigner.sign produces a signature that verifies over signingInput, with the fixture's known key and envelope")
    func signProducesVerifiableSignatureAgainstFixture() throws {
        let fixture = try Self.loadFixture()
        let seed = Self.dataFromHex(fixture.private_hex)
        #expect(seed.count == 32)
        let key = try #require(IrisSigningKey(base64Seed: seed.base64EncodedString()))

        let B = Self.dataFromHex(fixture.B_hex)
        let signer = PeerSigner(key: key)
        let parts = signer.sign(envelopeBytes: B, principal: "clomp", keyId: "key-1")

        let expectedPublicKey = Self.dataFromHex(fixture.public_hex)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: expectedPublicKey)
        let expectedInput = signingInput(domain: PeerSignatureDomain.a2a, envelopeBytes: B)
        #expect(publicKey.isValidSignature(parts.signature, for: expectedInput))
        #expect(parts.envelopeBytes == B)
        #expect(parts.verifiedBy == "ed25519")

        // And confirm it is domain-separated: the raw envelope bytes alone must NOT verify.
        #expect(!publicKey.isValidSignature(parts.signature, for: B))

        // KAT, without asserting byte-equality against a freshly produced signature: the
        // fixture's own `sig_b64` IS the canonical Ed25519 signature over `signing_input_hex`
        // for this same key pair (independently reproduced with `openssl pkeyutl -sign` over a
        // DER-wrapped `private_hex`, byte-for-byte identical to `sig_b64`). It is not asserted
        // as `parts.signature`'s expected value, because `Curve25519.Signing.PrivateKey
        // .signature(for:)` is empirically NOT deterministic across calls for an identical key
        // and message on this toolchain — signing the fixture's own `signing_input_hex` with
        // its `private_hex` five times in one process produced five distinct, independently
        // valid, signatures, none equal to each other or to `sig_b64` (CryptoKit's Ed25519
        // hedges/randomizes the nonce; its *verification* path remains standards-compliant).
        // A byte-equality assertion against a live `parts.signature` would therefore never
        // pass here, not from a bug in this signer, but from that property of the underlying
        // primitive `IrisSigningKey.sign` calls. What this checks instead, and is a genuine
        // KAT: `sig_b64` itself verifies against the fixture's public key over the same
        // domain-separated `signingInput`, confirming the construction interoperates with an
        // externally (non-CryptoKit) produced canonical signature, not just a CryptoKit round trip.
        let fixtureSignature = try #require(Data(base64Encoded: fixture.sig_b64))
        #expect(publicKey.isValidSignature(fixtureSignature, for: expectedInput))
    }

    @Test("PeerSigner.sign fills principal, keyId, verifiedBy and envelopeBytes correctly")
    func signFillsSignedFrameParts() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let store = IrisSigningKeyStore(keychain: keychain, service: KeychainManager.a2aSigningKeyService)
        let key = try store.loadOrCreate()

        let envelope = Data("{\"hello\":\"world\"}".utf8)
        let signer = PeerSigner(key: key)
        let parts = signer.sign(envelopeBytes: envelope, principal: "rune", keyId: "rune-key-1")

        #expect(parts.principal == "rune")
        #expect(parts.keyId == "rune-key-1")
        #expect(parts.verifiedBy == "ed25519")
        #expect(parts.envelopeBytes == envelope)

        let rawPublicKey = try #require(Data(base64Encoded: String(key.publicKeyWireString.dropFirst("ed25519:".count))))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)
        let expectedInput = signingInput(domain: PeerSignatureDomain.a2a, envelopeBytes: envelope)
        #expect(publicKey.isValidSignature(parts.signature, for: expectedInput))
    }

    @Test("PeerSigner.sign accepts a nil keyId")
    func signAllowsNilKeyId() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let store = IrisSigningKeyStore(keychain: keychain, service: KeychainManager.a2aSigningKeyService)
        let key = try store.loadOrCreate()

        let envelope = Data("payload".utf8)
        let signer = PeerSigner(key: key)
        let parts = signer.sign(envelopeBytes: envelope, principal: "iris", keyId: nil)

        #expect(parts.keyId == nil)
        #expect(parts.verifiedBy == "ed25519")
    }
}
