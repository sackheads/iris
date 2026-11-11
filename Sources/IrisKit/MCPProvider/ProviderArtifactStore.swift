import Foundation
import CryptoKit

/// Content-addressed file exchange for registered clients of the loopback MCP provider (#1067).
/// Intentionally its own store, independent of `ArtifactStore`'s conversation-row model — a
/// client here has no `Conversation`, so no row-delete path, and its own TTL sweep instead.
actor ProviderArtifactStore {
    enum ArtifactError: Error, Equatable {
        case tooLarge
        case quotaExceeded
        case notFound
        case unauthorized
        case invalidHash
        case uploaderNoLongerRegistered
    }

    /// 8 MiB for Phase 1, not romar's 64 MiB conformance baseline: a 64 MiB inline-base64
    /// `artifact_put` body is ~86 MB resident per request once decoded, with no per-request
    /// concurrency cap in front of it yet.
    static let maxBytesPerObject = 8 * 1024 * 1024
    /// 7 days, matching romar's object TTL (§3.6).
    static let ttl: TimeInterval = 7 * 24 * 60 * 60
    static let perClientDailyBytes = 200 * 1024 * 1024
    static let totalStoreCapBytes = 2048 * 1024 * 1024

    /// Every cap, instance-level so tests can shrink the quota caps without writing hundreds of
    /// megabytes to disk to exercise them. Defaults to this type's own named constants —
    /// production code never passes this.
    struct Quotas: Sendable {
        var maxBytesPerObject = ProviderArtifactStore.maxBytesPerObject
        var perClientDailyBytes = ProviderArtifactStore.perClientDailyBytes
        var totalStoreCapBytes = ProviderArtifactStore.totalStoreCapBytes
    }

    private struct Record {
        var storedAt: Date
        var sizeBytes: Int
        var authorizedReaders: Set<String>
    }

    private let root: URL
    private let isRegistered: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date
    private let quotas: Quotas

    private var records: [String: Record] = [:]
    /// clientId -> (day, bytesWrittenThatDay). "Day" is a calendar-day string, so this resets
    /// naturally across midnight without a separate timer.
    private var dailyBytes: [String: (day: String, bytes: Int)] = [:]
    private var totalBytes = 0

    init(root: URL, isRegistered: @escaping @Sendable (String) -> Bool = { _ in true },
         now: @escaping @Sendable () -> Date = Date.init, quotas: Quotas = Quotas()) {
        self.root = root
        self.isRegistered = isRegistered
        self.now = now
        self.quotas = quotas
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private static func isValidHash(_ sha256: String) -> Bool {
        sha256.count == 64 && sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private func path(for sha256: String) -> URL { root.appendingPathComponent(sha256) }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    func put(bytes: Data, from clientId: String) throws -> String {
        guard isRegistered(clientId) else { throw ArtifactError.uploaderNoLongerRegistered }
        guard bytes.count <= quotas.maxBytesPerObject else { throw ArtifactError.tooLarge }

        let today = Self.dayString(now())
        let clientBytesToday = dailyBytes[clientId]?.day == today ? dailyBytes[clientId]?.bytes ?? 0 : 0
        guard clientBytesToday + bytes.count <= quotas.perClientDailyBytes else { throw ArtifactError.quotaExceeded }
        guard totalBytes + bytes.count <= quotas.totalStoreCapBytes else { throw ArtifactError.quotaExceeded }

        let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        if records[sha256] == nil {
            try bytes.write(to: path(for: sha256))
            totalBytes += bytes.count
            dailyBytes[clientId] = (today, clientBytesToday + bytes.count)
        }
        // Re-uploading identical bytes (same hash) doesn't double-charge storage or quota, but
        // still grants the uploader a read, same as a fresh object would.
        var record = records[sha256] ?? Record(storedAt: now(), sizeBytes: bytes.count, authorizedReaders: [])
        record.authorizedReaders.insert(clientId)
        records[sha256] = record
        return sha256
    }

    func authorize(sha256: String, by senderId: String, adding clientIds: Set<String>) throws {
        try authorizeAllInternal(sha256s: [sha256], by: senderId, adding: clientIds)
    }

    /// The atomic, all-or-nothing version: one actor hop validates and authorizes every hash in
    /// `sha256s` together, with no partial grant left behind if any of them fails. Nothing else
    /// runs on this actor between the first hash's check and the last's.
    func authorizeAll(sha256s: [String], by senderId: String, adding clientId: String) throws {
        try authorizeAllInternal(sha256s: sha256s, by: senderId, adding: [clientId])
    }

    private func authorizeAllInternal(sha256s: [String], by senderId: String, adding clientIds: Set<String>) throws {
        for sha256 in sha256s {
            guard Self.isValidHash(sha256) else { throw ArtifactError.invalidHash }
            guard let record = records[sha256] else { throw ArtifactError.notFound }
            guard record.authorizedReaders.contains(senderId) else { throw ArtifactError.unauthorized }
        }
        // Every hash validated above; now actually mutate — nothing else runs on this actor
        // in between, so there is no window for a partial grant.
        for sha256 in sha256s {
            records[sha256]?.authorizedReaders.formUnion(clientIds)
        }
    }

    func get(sha256: String, requestingClientId: String) throws -> Data {
        guard Self.isValidHash(sha256) else { throw ArtifactError.invalidHash }
        guard let record = records[sha256] else { throw ArtifactError.notFound }
        guard record.authorizedReaders.contains(requestingClientId) else { throw ArtifactError.unauthorized }
        return try Data(contentsOf: path(for: sha256))
    }

    func sweepExpired(now: Date = Date()) {
        for (sha256, record) in records where now.timeIntervalSince(record.storedAt) > Self.ttl {
            try? FileManager.default.removeItem(at: path(for: sha256))
            totalBytes -= record.sizeBytes
            records[sha256] = nil
        }
    }

    /// Removes `clientId` from every object's authorized-reader set and clears its quota
    /// bookkeeping. Does not remove objects `clientId` itself uploaded — those stay until
    /// `sweepExpired` reclaims them on the normal TTL, since another authorized reader may still
    /// hold a valid grant to them.
    func purge(clientId: String) {
        for sha256 in records.keys {
            records[sha256]?.authorizedReaders.remove(clientId)
        }
        dailyBytes[clientId] = nil
    }
}
