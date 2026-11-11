import Testing
import Foundation
@testable import IrisKit

private func temporaryTestDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("iris-provider-artifacts-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class DateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }
}

@Suite("ProviderArtifactStore")
struct ProviderArtifactStoreTests {
    @Test("the uploader can always read its own object; an unauthorized client cannot, even knowing the hash")
    func putGetACLEnforced() async throws {
        let store = ProviderArtifactStore(root: temporaryTestDirectory())
        let sha = try await store.put(bytes: Data("hello".utf8), from: "a")
        #expect(try await store.get(sha256: sha, requestingClientId: "a") == Data("hello".utf8))
        await #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
            try await store.get(sha256: sha, requestingClientId: "b")
        }
        try await store.authorize(sha256: sha, by: "a", adding: ["b"])
        #expect(try await store.get(sha256: sha, requestingClientId: "b") == Data("hello".utf8))
        await #expect(throws: ProviderArtifactStore.ArtifactError.notFound) {
            try await store.get(sha256: String(repeating: "0", count: 64), requestingClientId: "a")
        }
    }

    @Test("a client who only learned the hash cannot grant anyone else a read (Gap 4)")
    func authorizeRequiresSenderAlreadyAuthorized() async throws {
        let store = ProviderArtifactStore(root: temporaryTestDirectory())
        let sha = try await store.put(bytes: Data("hello".utf8), from: "a")
        await #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
            try await store.authorize(sha256: sha, by: "c", adding: ["b"])
        }
        await #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
            try await store.get(sha256: sha, requestingClientId: "b")
        }
    }

    @Test("a malformed sha256 is rejected before touching the filesystem")
    func malformedHashRejected() async throws {
        let store = ProviderArtifactStore(root: temporaryTestDirectory())
        await #expect(throws: ProviderArtifactStore.ArtifactError.invalidHash) {
            try await store.get(sha256: "../../etc/passwd", requestingClientId: "a")
        }
    }

    @Test("an uppercase-spelled hash is rejected the same way (only lowercase 64-hex is valid)")
    func uppercaseHashRejected() async throws {
        let store = ProviderArtifactStore(root: temporaryTestDirectory())
        let sha = try await store.put(bytes: Data("hello".utf8), from: "a")
        await #expect(throws: ProviderArtifactStore.ArtifactError.invalidHash) {
            try await store.get(sha256: sha.uppercased(), requestingClientId: "a")
        }
    }

    @Test("an object over the size cap is rejected before any write")
    func oversizeRejected() async throws {
        let root = temporaryTestDirectory()
        var quotas = ProviderArtifactStore.Quotas()
        quotas.maxBytesPerObject = 10
        let store = ProviderArtifactStore(root: root, quotas: quotas)
        let oversized = Data(repeating: 0, count: 11)
        await #expect(throws: ProviderArtifactStore.ArtifactError.tooLarge) {
            try await store.put(bytes: oversized, from: "a")
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(contents.isEmpty)
    }

    @Test("a client's own daily quota is enforced independently of another client's")
    func perClientQuotaEnforced() async throws {
        var quotas = ProviderArtifactStore.Quotas()
        quotas.maxBytesPerObject = 10
        quotas.perClientDailyBytes = 25
        let store = ProviderArtifactStore(root: temporaryTestDirectory(), quotas: quotas)
        for i in 0..<2 {
            // Distinct content per call so each put() is a genuinely new object, not a free re-upload.
            _ = try await store.put(bytes: Data(repeating: UInt8(i), count: 10), from: "a")
        }
        // 20 bytes used of 25; one more 10-byte object would put "a" at 30, over quota.
        await #expect(throws: ProviderArtifactStore.ArtifactError.quotaExceeded) {
            _ = try await store.put(bytes: Data(repeating: 9, count: 10), from: "a")
        }
        // A second client's own quota is untouched by "a"'s exhaustion.
        _ = try await store.put(bytes: Data("small".utf8), from: "b")
    }

    @Test("the store's total cap is enforced across every client's uploads combined")
    func totalStoreCapEnforced() async throws {
        var quotas = ProviderArtifactStore.Quotas()
        quotas.maxBytesPerObject = 10
        quotas.perClientDailyBytes = 1000  // high enough that only the total cap can trip here
        quotas.totalStoreCapBytes = 25
        let store = ProviderArtifactStore(root: temporaryTestDirectory(), quotas: quotas)
        _ = try await store.put(bytes: Data(repeating: 0, count: 10), from: "a")
        _ = try await store.put(bytes: Data(repeating: 1, count: 10), from: "b")
        // 20 of 25 used, by two different clients; "c"'s own quota is fine, but the store is full.
        await #expect(throws: ProviderArtifactStore.ArtifactError.quotaExceeded) {
            _ = try await store.put(bytes: Data(repeating: 2, count: 10), from: "c")
        }
    }

    @Test("sweepExpired reclaims an object past its TTL and leaves a fresh one alone")
    func sweepReclaimsOnlyExpired() async throws {
        let base = Date()
        let clockBox = DateBox(base)
        let store = ProviderArtifactStore(root: temporaryTestDirectory(), now: { clockBox.value })
        let expiredSHA = try await store.put(bytes: Data("old".utf8), from: "a")
        clockBox.value = base.addingTimeInterval(ProviderArtifactStore.ttl + 1)
        let freshSHA = try await store.put(bytes: Data("new".utf8), from: "a")

        await store.sweepExpired(now: clockBox.value)

        await #expect(throws: ProviderArtifactStore.ArtifactError.notFound) {
            try await store.get(sha256: expiredSHA, requestingClientId: "a")
        }
        #expect(try await store.get(sha256: freshSHA, requestingClientId: "a") == Data("new".utf8))
    }

    @Test("purge removes a client's authorized-reader grants but not objects it uploaded itself")
    func purgeRemovesGrantsOnly() async throws {
        let store = ProviderArtifactStore(root: temporaryTestDirectory())
        let sha = try await store.put(bytes: Data("hello".utf8), from: "a")
        try await store.authorize(sha256: sha, by: "a", adding: ["b"])
        await store.purge(clientId: "b")
        await #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
            try await store.get(sha256: sha, requestingClientId: "b")
        }
        #expect(try await store.get(sha256: sha, requestingClientId: "a") == Data("hello".utf8))
    }

    @Test("a client no longer registered cannot put a new object under its old id")
    func uploaderMustBeRegistered() async throws {
        let store = ProviderArtifactStore(root: temporaryTestDirectory(), isRegistered: { $0 != "a" })
        await #expect(throws: ProviderArtifactStore.ArtifactError.uploaderNoLongerRegistered) {
            try await store.put(bytes: Data("late".utf8), from: "a")
        }
    }

    @Test("authorizeAll grants every hash together, or none, atomically")
    func authorizeAllIsAllOrNothing() async throws {
        let store = ProviderArtifactStore(root: temporaryTestDirectory())
        let shaA = try await store.put(bytes: Data("one".utf8), from: "a")
        let shaB = try await store.put(bytes: Data("two".utf8), from: "a")
        let shaUnowned = try await store.put(bytes: Data("three".utf8), from: "z")  // "a" never authorized on this one

        await #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
            try await store.authorizeAll(sha256s: [shaA, shaB, shaUnowned], by: "a", adding: "c")
        }
        // Neither shaA nor shaB granted "c" a read: the failure on the third hash left no partial grant.
        await #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
            try await store.get(sha256: shaA, requestingClientId: "c")
        }
        await #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
            try await store.get(sha256: shaB, requestingClientId: "c")
        }
    }
}
