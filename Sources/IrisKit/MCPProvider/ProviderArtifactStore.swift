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
        // records/totalBytes/dailyBytes are memory-only and start empty every launch — with no
        // persistent manifest, leaving a prior run's files in place would make them orphaned
        // (unreadable: no record exists; never swept: sweepExpired only ever walks records) and
        // uncounted (totalBytes starts at 0, so the 2 GiB cap no longer reflects what's on disk).
        // Phase 1 accepts losing provider-exchanged files across a restart (bounded, at most 7
        // days of exchange data, and this is a messaging convenience cache, not durable storage).
        //
        // Only entries whose name is this store's own hash-named shape are removed, never the
        // whole directory: `removeItem(at: root)` would delete everything under whatever path
        // Task 8 passes as `root`, recursively and silently (`try?`), if that path were ever
        // wrong — this store has no business touching a file it didn't itself name.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for name in entries where Self.isValidHash(name) {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }

    private static func isValidHash(_ sha256: String) -> Bool {
        // ASCII only: `Character.isHexDigit` is Unicode-aware and accepts fullwidth digits like
        // U+FF41 ("ａ"), which would otherwise pass this check while being a different sequence
        // of bytes than the ASCII hex this type's paths are built from.
        sha256.utf8.count == 64 && sha256.count == 64
            && sha256.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
    }

    private func path(for sha256: String) -> URL { root.appendingPathComponent(sha256) }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    func put(bytes: Data, from clientId: String) throws -> String {
        guard isRegistered(clientId) else { throw ArtifactError.uploaderNoLongerRegistered }
        guard bytes.count <= quotas.maxBytesPerObject else { throw ArtifactError.tooLarge }

        let today = Self.dayString(now())
        let clientBytesToday = dailyBytes[clientId]?.day == today ? dailyBytes[clientId]?.bytes ?? 0 : 0
        guard clientBytesToday + bytes.count <= quotas.perClientDailyBytes else { throw ArtifactError.quotaExceeded }
        guard totalBytes + bytes.count <= quotas.totalStoreCapBytes else { throw ArtifactError.quotaExceeded }

        let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var record: Record
        if let existing = records[sha256] {
            // Re-uploading identical bytes doesn't double-charge storage or quota — the bytes are
            // already on disk — but storedAt still refreshes: the client was just told it stored
            // this, so the next sweep must not delete it on the strength of a stale timestamp
            // from before this call (dev-2/dev-3 review on #1075). This also means re-uploading an
            // expired-but-unswept object revives it, with its *existing* authorized-reader set
            // intact — every client previously granted a read keeps it, not just this uploader.
            // That is accepted as correct, not a bug: the bytes those readers were granted access
            // to are the exact bytes still on disk.
            record = existing
            record.storedAt = now()
        } else {
            try bytes.write(to: path(for: sha256), options: .atomic)
            totalBytes += bytes.count
            dailyBytes[clientId] = (today, clientBytesToday + bytes.count)
            record = Record(storedAt: now(), sizeBytes: bytes.count, authorizedReaders: [])
        }
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
        // An object past its TTL but not yet reclaimed (sweepExpired runs on whatever schedule
        // Task 8's lifecycle wiring gives it, not on every get) must not be served as though it
        // were still live — treat it as absent, the same as if it had already been swept.
        guard now().timeIntervalSince(record.storedAt) <= Self.ttl else { throw ArtifactError.notFound }
        guard record.authorizedReaders.contains(requestingClientId) else { throw ArtifactError.unauthorized }
        return try Data(contentsOf: path(for: sha256))
    }

    /// Reclaims every object past `ttl`. Runs on whatever schedule Task 8's app-lifecycle wiring
    /// gives it (a periodic timer) — nothing in this actor schedules it itself.
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
