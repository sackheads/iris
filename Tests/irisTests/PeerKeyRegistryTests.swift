import Foundation
import CryptoKit
import Testing
@testable import IrisKit

/// #974 H4 Task 2: the per-profile registry of OTHER peers' public keys, the other side of Task
/// 1's `IrisSigningKey` (Iris's own identity). Every test uses its own temp directory via
/// `IrisPaths(root:)` (Invariant 7) — never `IrisPaths.default`.
@Suite("Peer key registry (#974 H4)")
struct PeerKeyRegistryTests {
    private func freshRegistry() -> (PeerKeyRegistry, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peer-key-registry-\(UUID().uuidString)")
        return (PeerKeyRegistry(paths: IrisPaths(root: tempDir)), tempDir)
    }

    /// A fresh, valid Ed25519 wire-form public key, independent of any registered identity.
    private func freshWireKey() -> String {
        IrisSigningKey().publicKeyWireString
    }

    @Test("enroll then resolve by exact keyId returns the enrolled key")
    func enrollAndResolveExactKeyId() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let wire = freshWireKey()
        try registry.enroll(RegisteredKey(profile: "clomp", keyId: "clomp-2026-11", publicKey: wire))

        let resolved = try registry.resolve(principal: "clomp", keyId: "clomp-2026-11")
        #expect(resolved != nil)
        #expect(resolved?.rawRepresentation.base64EncodedString() ==
                 String(wire.dropFirst("ed25519:".count)))
    }

    @Test("resolve with nil keyId defaults to the principal name, resolving a default-named key")
    func resolveDefaultKeyIdHit() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let wire = freshWireKey()
        // Enrolled under keyId == profile, the default-key convention.
        try registry.enroll(RegisteredKey(profile: "clomp", keyId: "clomp", publicKey: wire))

        let resolved = try registry.resolve(principal: "clomp", keyId: nil)
        #expect(resolved != nil)
    }

    @Test("resolve with nil keyId is nil when only a non-default keyId is enrolled")
    func resolveDefaultKeyIdMiss() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try registry.enroll(RegisteredKey(profile: "clomp", keyId: "clomp-2026-11", publicKey: freshWireKey()))

        let resolved = try registry.resolve(principal: "clomp", keyId: nil)
        #expect(resolved == nil)
    }

    // Review Focus: cross-principal key confusion. A keyId that coincidentally matches across
    // two principals' files must never resolve under the wrong principal.
    @Test("resolve('clomp', 'rune-key-1') is nil even after enrolling rune/rune-key-1")
    func crossPrincipalIsolation() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try registry.enroll(RegisteredKey(profile: "rune", keyId: "rune-key-1", publicKey: freshWireKey()))

        let resolved = try registry.resolve(principal: "clomp", keyId: "rune-key-1")
        #expect(resolved == nil)
        // Sanity: the key is reachable under its own principal.
        #expect(try registry.resolve(principal: "rune", keyId: "rune-key-1") != nil)
    }

    @Test("unsafe principal names resolve to nil without touching the filesystem outside a2aPeersDir")
    func unsafeNamesTouchNothing() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let unsafeNames = [
            "../conversations",
            "",
            "has/slash",
            "has\0nul",
            String(repeating: "a", count: 200),
        ]
        for name in unsafeNames {
            #expect(try registry.resolve(principal: name, keyId: nil) == nil, "name: \(name.debugDescription)")
        }

        // No resolve call above wrote or created anything: the temp root (which did not exist
        // before this test ran) must still not exist at all.
        #expect(!FileManager.default.fileExists(atPath: tempDir.path))
    }

    @Test("a file mis-cased as Clomp.json does not answer for principal clomp (record-profile-exact)")
    func misCasedFileDoesNotAnswer() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let wire = freshWireKey()

        // Planted directly on disk (not through `enroll`, which would reject "Clomp" as a
        // profile name) to simulate a hand-moved or case-folded file.
        try FileManager.default.createDirectory(at: registry.directory, withIntermediateDirectories: true)
        let record = RegisteredKey(profile: "Clomp", keyId: "clomp", publicKey: wire)
        let data = try JSONEncoder().encode([record])
        try data.write(to: registry.directory.appendingPathComponent("Clomp.json"))

        let resolved = try registry.resolve(principal: "clomp", keyId: "clomp")
        #expect(resolved == nil)
    }

    @Test("enroll of an existing keyId with a different public key throws")
    func enrollKeySubstitutionThrows() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try registry.enroll(RegisteredKey(profile: "clomp", keyId: "clomp-2026-11", publicKey: freshWireKey()))

        let substitute = RegisteredKey(profile: "clomp", keyId: "clomp-2026-11", publicKey: freshWireKey())
        #expect(throws: PeerKeySubstitutionError(profile: "clomp", keyId: "clomp-2026-11")) {
            try registry.enroll(substitute)
        }
    }

    @Test("re-enrolling the exact same keyId and public key is a no-op, not a throw")
    func enrollIdempotentForIdenticalKey() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let key = RegisteredKey(profile: "clomp", keyId: "clomp-2026-11", publicKey: freshWireKey())
        try registry.enroll(key)
        try registry.enroll(key)

        #expect(try registry.list(profile: "clomp").count == 1)
    }

    @Test("a corrupt principal file throws RegistryError.unavailable while other principals stay resolvable")
    func corruptFileFailsClosed() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try registry.enroll(RegisteredKey(profile: "clomp", keyId: "clomp", publicKey: freshWireKey()))

        try FileManager.default.createDirectory(at: registry.directory, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: registry.directory.appendingPathComponent("rune.json"))

        #expect(throws: RegistryError.unavailable) {
            _ = try registry.resolve(principal: "rune", keyId: nil)
        }
        // The corruption is isolated to rune's own file.
        #expect(try registry.resolve(principal: "clomp", keyId: "clomp") != nil)
    }

    // Review finding: `corruptFileFailsClosed` only covered file-level corruption (not valid
    // JSON). This covers the other half of the fail-closed design: a syntactically valid
    // `[RegisteredKey]` array whose matched record's `publicKey` string is unusable key
    // material — a bad prefix, non-base64 content, or the right base64 shape but the wrong
    // decoded byte count for Curve25519. Each must also throw `.unavailable`, never read as a
    // clean "no such key".
    @Test("a record with unparseable key material throws RegistryError.unavailable, not nil")
    func badKeyMaterialFailsClosed() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let badRecords = [
            RegisteredKey(profile: "clomp", keyId: "bad-prefix", publicKey: "not-ed25519:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="),
            RegisteredKey(profile: "clomp", keyId: "bad-base64", publicKey: "ed25519:not-valid-base64!!"),
            RegisteredKey(profile: "clomp", keyId: "wrong-length", publicKey: "ed25519:" + Data([1, 2, 3]).base64EncodedString()),
        ]
        try FileManager.default.createDirectory(at: registry.directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(badRecords)
        try data.write(to: registry.directory.appendingPathComponent("clomp.json"))

        for record in badRecords {
            #expect(throws: RegistryError.unavailable) {
                _ = try registry.resolve(principal: "clomp", keyId: record.keyId)
            }
        }
    }

    // Peer review (PR #1036 Finding 3): a key equal to one of Ed25519's 8 known small-order
    // point encodings makes `isValidSignature` return true independent of what was actually
    // signed — "the trust root" of this whole core. Each wire string below is the base64 wire
    // form of one of the 8 small-order compressed points (identity, the order-2 point, the two
    // order-4 points, and the four order-8 points), derived and checked independently (see the
    // implementation comment on `PeerKeyRegistry.smallOrderEncodings`) rather than taken from
    // memory.
    private static let smallOrderWireKeys: [String] = [
        "ed25519:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "ed25519:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIA=",
        "ed25519:AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "ed25519:JuiVj8KyJ7BFw/SJ8u+Y8NXfrAXTxjM5sTgCiG1T/AU=",
        "ed25519:JuiVj8KyJ7BFw/SJ8u+Y8NXfrAXTxjM5sTgCiG1T/IU=",
        "ed25519:xxdqcD1N2E+6PAt2DRBnDyogU/osOczGTsf9d5KsA3o=",
        "ed25519:xxdqcD1N2E+6PAt2DRBnDyogU/osOczGTsf9d5KsA/o=",
        "ed25519:7P///////////////////////////////////////38=",
    ]

    @Test("enroll of a small-order Ed25519 point fails closed, the same as unparseable key material")
    func enrollRejectsSmallOrderKey() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for (index, wire) in Self.smallOrderWireKeys.enumerated() {
            #expect(throws: RegistryError.unavailable) {
                try registry.enroll(RegisteredKey(profile: "clomp", keyId: "small-order-\(index)", publicKey: wire))
            }
        }
        // None of the rejected attempts persisted anything.
        #expect(try registry.list(profile: "clomp").isEmpty)
    }

    // The registry file is hand-writable, so a small-order key can reach disk by a path other
    // than `enroll` (a stale file from before this check existed, or one hand-edited) — `resolve`
    // must refuse it too, the same way `badKeyMaterialFailsClosed` covers other unusable key
    // material planted directly into the file.
    @Test("a stale file with a small-order key fails closed at resolve, not as a clean miss")
    func resolveRejectsStaleSmallOrderKey() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let staleRecords = Self.smallOrderWireKeys.enumerated().map { index, wire in
            RegisteredKey(profile: "clomp", keyId: "small-order-\(index)", publicKey: wire)
        }
        try FileManager.default.createDirectory(at: registry.directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(staleRecords)
        try data.write(to: registry.directory.appendingPathComponent("clomp.json"))

        for record in staleRecords {
            #expect(throws: RegistryError.unavailable) {
                _ = try registry.resolve(principal: "clomp", keyId: record.keyId)
            }
        }
    }

    // Review finding: AGENTS.md Invariant 3 documents that tool calls run concurrently via
    // `withTaskGroup` — this is a real, recurring race class here, not a generic worry. The
    // `withLock` serialization around `enroll`'s read-check-write must hold under real
    // contention: with several callers racing to enroll the same (profile, keyId) under
    // different public keys, exactly one must win (and persist), every other must see
    // `PeerKeySubstitutionError`, and the file on disk afterward must hold exactly one
    // uncorrupted record — never a torn or merged write from two writers racing `save`.
    @Test("concurrent enroll calls for the same (profile, keyId) with differing public keys: exactly one wins, the rest see substitution, the file is never torn")
    func concurrentEnrollSubstitutionIsSerialized() async throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let attempts = (0..<8).map { _ in freshWireKey() }

        let outcomes = await withTaskGroup(of: Result<Void, Error>.self) { group in
            for wire in attempts {
                group.addTask {
                    do {
                        try registry.enroll(RegisteredKey(profile: "clomp", keyId: "clomp-2026-11", publicKey: wire))
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var results: [Result<Void, Error>] = []
            for await result in group { results.append(result) }
            return results
        }

        let successes = outcomes.filter { if case .success = $0 { return true }; return false }
        let substitutionFailures = outcomes.compactMap { outcome -> PeerKeySubstitutionError? in
            if case .failure(let error) = outcome { return error as? PeerKeySubstitutionError }
            return nil
        }
        #expect(successes.count == 1)
        #expect(substitutionFailures.count == attempts.count - 1)
        #expect(substitutionFailures.allSatisfy { $0 == PeerKeySubstitutionError(profile: "clomp", keyId: "clomp-2026-11") })

        // The file holds exactly one record, and it's one of the attempted values — not a torn
        // or merged write from two writers racing `save` under the lock.
        let stored = try registry.list(profile: "clomp")
        #expect(stored.count == 1)
        #expect(attempts.contains(stored[0].publicKey))
    }

    @Test("revoke then resolve returns nil")
    func revokeThenResolve() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try registry.enroll(RegisteredKey(profile: "clomp", keyId: "clomp-2026-11", publicKey: freshWireKey()))
        #expect(try registry.resolve(principal: "clomp", keyId: "clomp-2026-11") != nil)

        try registry.revoke(profile: "clomp", keyId: "clomp-2026-11")
        #expect(try registry.resolve(principal: "clomp", keyId: "clomp-2026-11") == nil)
    }

    @Test("list returns every registered key for a profile")
    func listReturnsAll() throws {
        let (registry, tempDir) = freshRegistry()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try registry.enroll(RegisteredKey(profile: "clomp", keyId: "clomp-2026-11", publicKey: freshWireKey()))
        try registry.enroll(RegisteredKey(profile: "clomp", keyId: "clomp-2026-12", publicKey: freshWireKey()))

        let keys = try registry.list(profile: "clomp")
        #expect(Set(keys.map(\.keyId)) == ["clomp-2026-11", "clomp-2026-12"])
    }
}
