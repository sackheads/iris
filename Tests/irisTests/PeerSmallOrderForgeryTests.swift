import Foundation
import CryptoKit
import Testing
@testable import IrisKit

/// #1038: a small-order Ed25519 public key makes a forged signature verify, and a byte match
/// against the 8 canonical encodings misses their other spellings (the opposite sign bit, and a
/// non-canonical y >= p). These tests forge a signature under every spelling and drive it through
/// the registry and the verifier: the key must be refused before `isValidSignature` ever runs.
@Suite("Small-order Ed25519 keys and their aliases (#1038)")
struct PeerSmallOrderForgeryTests {

    private static func bytes(_ lead: UInt8, middle: UInt8, count: Int = 32, last: UInt8) -> Data {
        var d = Data(repeating: middle, count: count)
        d[0] = lead
        d[count - 1] = last
        return d
    }

    /// Every spelling of a small-order point, labelled. Canonical entries mirror the registry's
    /// set; written out here so a mistake in one does not hide in the other.
    static let spellings: [(name: String, encoding: Data, canonical: Bool)] = [
        ("identity", Data([0x01]) + Data(repeating: 0, count: 31), true),
        ("order-2", bytes(0xec, middle: 0xff, last: 0x7f), true),
        ("order-4 y=0", Data(repeating: 0, count: 32), true),
        ("order-4 y=0 negative", Data(repeating: 0, count: 31) + Data([0x80]), true),
        ("order-8 a", Data([0x26, 0xe8, 0x95, 0x8f, 0xc2, 0xb2, 0x27, 0xb0, 0x45, 0xc3, 0xf4, 0x89, 0xf2, 0xef, 0x98, 0xf0, 0xd5, 0xdf, 0xac, 0x05, 0xd3, 0xc6, 0x33, 0x39, 0xb1, 0x38, 0x02, 0x88, 0x6d, 0x53, 0xfc, 0x05]), true),
        ("order-8 a negative", Data([0x26, 0xe8, 0x95, 0x8f, 0xc2, 0xb2, 0x27, 0xb0, 0x45, 0xc3, 0xf4, 0x89, 0xf2, 0xef, 0x98, 0xf0, 0xd5, 0xdf, 0xac, 0x05, 0xd3, 0xc6, 0x33, 0x39, 0xb1, 0x38, 0x02, 0x88, 0x6d, 0x53, 0xfc, 0x85]), true),
        ("order-8 b", Data([0xc7, 0x17, 0x6a, 0x70, 0x3d, 0x4d, 0xd8, 0x4f, 0xba, 0x3c, 0x0b, 0x76, 0x0d, 0x10, 0x67, 0x0f, 0x2a, 0x20, 0x53, 0xfa, 0x2c, 0x39, 0xcc, 0xc6, 0x4e, 0xc7, 0xfd, 0x77, 0x92, 0xac, 0x03, 0x7a]), true),
        ("order-8 b negative", Data([0xc7, 0x17, 0x6a, 0x70, 0x3d, 0x4d, 0xd8, 0x4f, 0xba, 0x3c, 0x0b, 0x76, 0x0d, 0x10, 0x67, 0x0f, 0x2a, 0x20, 0x53, 0xfa, 0x2c, 0x39, 0xcc, 0xc6, 0x4e, 0xc7, 0xfd, 0x77, 0x92, 0xac, 0x03, 0xfa]), true),
        // The aliases a canonical-bytes match lets through.
        ("identity, sign bit set", Data([0x01]) + Data(repeating: 0, count: 30) + Data([0x80]), false),
        ("order-2, sign bit set", bytes(0xec, middle: 0xff, last: 0xff), false),
        ("identity as y=p+1", bytes(0xee, middle: 0xff, last: 0x7f), false),
        ("identity as y=p+1, sign bit set", bytes(0xee, middle: 0xff, last: 0xff), false),
        ("order-4 as y=p", bytes(0xed, middle: 0xff, last: 0x7f), false),
        ("order-4 as y=p, sign bit set", bytes(0xed, middle: 0xff, last: 0xff), false),
    ]

    private static func wire(_ encoding: Data) -> String { "ed25519:" + encoding.base64EncodedString() }

    private func freshRegistry() -> (PeerKeyRegistry, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peer-small-order-\(UUID().uuidString)")
        return (PeerKeyRegistry(paths: IrisPaths(root: tempDir)), tempDir)
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    @Test("the spellings are 14 distinct 32-byte encodings")
    func tableIsSound() {
        #expect(Self.spellings.count == 14)
        #expect(Set(Self.spellings.map(\.encoding)).count == 14)
        #expect(Self.spellings.allSatisfy { $0.encoding.count == 32 })
    }

    @Test("enroll refuses every spelling and persists nothing")
    func enrollRefusesEverySpelling() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        for (index, spelling) in Self.spellings.enumerated() {
            #expect(throws: RegistryError.unavailable, "\(spelling.name)") {
                try registry.enroll(RegisteredKey(profile: "clomp", keyId: "k\(index)", publicKey: Self.wire(spelling.encoding)))
            }
        }
        #expect(try registry.list(profile: "clomp").isEmpty)
    }

    @Test("a forged signature under every spelling is refused before the signature is checked")
    func forgedFrameNeverReachesTheSignatureCheck() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var forgeriesThatVerifyUnderCryptoKit = 0
        for (index, spelling) in Self.spellings.enumerated() {
            let (registry, tempDir) = freshRegistry()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            // Planted straight into the file, as a stale or hand-edited registry would hold it.
            try FileManager.default.createDirectory(at: registry.directory, withIntermediateDirectories: true)
            let record = RegisteredKey(profile: "clomp", keyId: "clomp", publicKey: Self.wire(spelling.encoding))
            try JSONEncoder().encode([record]).write(to: registry.directory.appendingPathComponent("clomp.json"))

            // R = identity, S = 0 verifies under any key whose point has order dividing k, which
            // depends on the message; search envelopes until the raw key accepts one, so the
            // frame under test is a forgery that really verifies where the key is accepted.
            let rawKey = try Curve25519.Signing.PublicKey(rawRepresentation: spelling.encoding)
            let forgedSignature = Data([0x01]) + Data(repeating: 0, count: 63)
            var chosen: Data?
            var fallback: Data?
            for attempt in 0..<512 {
                let envelope = Data("""
                {"from":{"profile":"clomp"},"to":{"profile":"iris"},"kind":"message","envelopeId":"forged-\(index)-\(attempt)","ts":"\(Self.iso(now))"}
                """.utf8)
                fallback = envelope
                let input = signingInput(domain: PeerSignatureDomain.a2a, envelopeBytes: envelope)
                if rawKey.isValidSignature(forgedSignature, for: input) { chosen = envelope; break }
            }
            if chosen != nil { forgeriesThatVerifyUnderCryptoKit += 1 }
            let envelopeBytes = try #require(chosen ?? fallback)
            let frame = SignedFrameParts(principal: "clomp", keyId: nil, verifiedBy: "direct",
                                         signature: forgedSignature, envelopeBytes: envelopeBytes)
            let verifier = PeerSignatureVerifier(registry: registry, seenSet: PeerSignatureVerifierTests.InMemorySeenSet())
            let context = VerificationContext(selfProfile: "iris", channel: .inbox, outstanding: nil, now: now)
            #expect(throws: RegistryError.unavailable, "\(spelling.name)") {
                _ = try verifier.verifyAndAdmit(frame, context: context, decode: PeerSignatureVerifierTests.decodeTestEnvelope)
            }
        }
        // The test is only worth something if the threat is real on this toolchain: the canonical
        // spellings forge under CryptoKit, so removing the guard would admit them.
        #expect(forgeriesThatVerifyUnderCryptoKit >= 4)
    }

    @Test("a freshly generated key still enrolls and resolves")
    func ordinaryKeyStillWorks() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = IrisSigningKey()
        try registry.enroll(RegisteredKey(profile: "clomp", keyId: "clomp", publicKey: key.publicKeyWireString))
        #expect(try registry.resolve(principal: "clomp", keyId: nil) != nil)
    }
}
