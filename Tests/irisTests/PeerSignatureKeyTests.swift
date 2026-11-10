import Foundation
import CryptoKit
import Testing
@testable import IrisKit

/// Covers #974 H4 Task 1: Iris's own Ed25519 signing identity, generated once and persisted in
/// the Keychain via `KeychainManager`'s secrets-lock pattern (#750). Later tasks build the peer
/// registry, signer and verifier on top of this.
@Suite("Peer-signature Ed25519 signing key (#974 H4)")
struct PeerSignatureKeyTests {
    /// The #678 in-memory seam, explicit rather than relied on via the `XCTestCase` name-sniff
    /// (the brief calls this out specifically): a fresh in-memory `KeychainManager` per test, so
    /// tests never share state through `KeychainManager.shared`.
    private func freshStore() -> IrisSigningKeyStore {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        return IrisSigningKeyStore(keychain: keychain, service: KeychainManager.a2aSigningKeyService)
    }

    @Test("loadOrCreate mints a key, and a second call returns the same public key")
    func loadOrCreatePersists() throws {
        let store = freshStore()
        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()
        #expect(first.publicKeyWireString == second.publicKeyWireString)
    }

    @Test("current() is nil before any loadOrCreate, and matches it after")
    func currentBeforeAndAfter() throws {
        let store = freshStore()
        #expect(try store.current() == nil)
        let created = try store.loadOrCreate()
        let current = try store.current()
        #expect(current?.publicKeyWireString == created.publicKeyWireString)
    }

    // Security-relevant: two callers racing on first use must never mint two different seeds —
    // whichever wins, every caller must end up with the same persisted identity.
    @Test("two concurrent loadOrCreate calls never mint two different seeds (no double-mint)")
    func noDoubleMint() async throws {
        let store = freshStore()
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { try store.loadOrCreate().publicKeyWireString }
            }
            var keys: [String] = []
            for try await key in group { keys.append(key) }
            return keys
        }
        #expect(results.count == 8)
        #expect(Set(results).count == 1)
    }

    @Test("publicKeyWireString carries romar's ed25519: prefix over 32 raw bytes")
    func wireStringFormat() throws {
        let store = freshStore()
        let key = try store.loadOrCreate()
        #expect(key.publicKeyWireString.hasPrefix("ed25519:"))
        let encoded = String(key.publicKeyWireString.dropFirst("ed25519:".count))
        let raw = try #require(Data(base64Encoded: encoded))
        #expect(raw.count == 32)
    }

    /// Minimal shape of `Fixtures/peer-signature-conformance.json` — only the two fields this
    /// test needs, so a change elsewhere in the fixture can't break decoding here.
    private struct ConformanceKeyPair: Decodable {
        let public_hex: String
        let private_hex: String
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

    // Review finding: the format was previously checked only by an uncommitted, one-off script
    // during development, so a regression (dropped padding, unpadded base64, hex instead of
    // base64) would have passed every committed test while silently breaking interop with
    // romar's peers. This pins `publicKeyWireString` against the vendored conformance fixture's
    // own known bytes — not a round-trip of a freshly minted key — by constructing the key from
    // the fixture's `private_hex` seed (independently confirmed via `openssl pkey -text_pub` to
    // derive exactly `public_hex`, so this isn't circular) and checking the wire string against
    // a literal built straight from `public_hex`.
    @Test("publicKeyWireString matches the vendored conformance fixture's own known key bytes")
    func wireStringMatchesVendoredFixture() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/peer-signature-conformance.json")
        let data = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(ConformanceKeyPair.self, from: data)

        let seed = Self.dataFromHex(fixture.private_hex)
        #expect(seed.count == 32)
        let key = try #require(IrisSigningKey(base64Seed: seed.base64EncodedString()))

        let expectedPublicKey = Self.dataFromHex(fixture.public_hex)
        #expect(expectedPublicKey.count == 32)
        let expectedWireString = "ed25519:" + expectedPublicKey.base64EncodedString()

        #expect(key.publicKeyWireString == expectedWireString)
    }

    @Test("a signature verifies for the signed message and fails for a one-byte-flipped message")
    func signatureVerifies() throws {
        let store = freshStore()
        let key = try store.loadOrCreate()
        let message = Data("iris a2a conformance".utf8)
        let signature = key.sign(message)
        #expect(signature.count == 64)

        let encoded = String(key.publicKeyWireString.dropFirst("ed25519:".count))
        let rawPublicKey = try #require(Data(base64Encoded: encoded))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)
        #expect(publicKey.isValidSignature(signature, for: message))

        var flipped = message
        flipped[0] ^= 0xFF
        #expect(!publicKey.isValidSignature(signature, for: flipped))
    }

    // Security-relevant: a caller that can't tell "persisted" from "ephemeral" could sign with a
    // key that vanishes on relaunch, breaking the pinned-key trust model entirely.
    @Test("loadOrCreate throws rather than returning an unpersisted key when writes are blocked")
    func throwsWhenWritesBlocked() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        keychain.blockWrites()
        let store = IrisSigningKeyStore(keychain: keychain, service: KeychainManager.a2aSigningKeyService)
        #expect(throws: IrisSigningKeyStore.StoreError.writesBlocked) {
            try store.loadOrCreate()
        }
    }

    // DevHomeSeeder.swift (~line 85) copies only `[legacyService, mcpFileService] + iris.plugin.*`
    // into a dev home; the signing-key service must never join that list, or a dev build would
    // sign as the release identity (#974 H4).
    @Test("the dev-home seeder never copies the signing-key service")
    func notSeededToDevHome() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("a2a-key-seed-\(UUID().uuidString)")
        let src = IrisPaths(root: base.appendingPathComponent("release"))
        let dst = IrisPaths(root: base.appendingPathComponent("dev"))
        defer { try? FileManager.default.removeItem(at: base) }
        try src.ensureDirectories()
        _ = try ConversationStore.onDisk(at: src.conversationsDB)
        try FileManager.default.createDirectory(at: src.modelsDir, withIntermediateDirectories: true)

        let srcKC = KeychainManager(serviceSuffix: "")
        let dstKC = KeychainManager(serviceSuffix: ".dev")
        srcKC.replaceSecrets(["seed": "not-a-real-persisted-seed"], service: KeychainManager.a2aSigningKeyService)

        let report = try DevHomeSeeder.seed(from: src, to: dst, identity: .dev,
                                            sourceKeychain: srcKC, destKeychain: dstKC)

        #expect(dstKC.secrets(service: KeychainManager.a2aSigningKeyService).isEmpty)
        #expect(!report.keychainServices.contains(dstKC.resolvedService(KeychainManager.a2aSigningKeyService)))
    }
}
