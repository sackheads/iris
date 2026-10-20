import CryptoKit
import Foundation
import GRDB
import UniformTypeIdentifiers

// Session artifacts (#469 §7, rulings in §7.6): snapshots one session hands another, kept in a
// content-addressed exchange under Iris's home and named by `iris-artifact://<sha256>`.

/// The `iris-artifact://` URI: identity (the hash), never a location.
enum ArtifactURI {
    static let scheme = "iris-artifact://"

    static func string(_ sha256: String) -> String { scheme + sha256 }

    /// The hash an `iris-artifact://` string names, or nil when it isn't one: 64 lowercase hex.
    static func hash(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(scheme) else { return nil }
        let hash = String(trimmed.dropFirst(scheme.count)).lowercased()
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hash
    }
}

/// What the exchange keeps beside an artifact's bytes. Invariant 1: every field past the hash
/// may be absent in a later format.
struct ArtifactSidecar: Codable, Equatable, Sendable {
    var sha256: String
    var name: String
    var mimeType: String
    var size: Int
    var senderSession: UUID?
    var createdAt: Date
    /// Where the bytes were read from: the host path, or `vm:<path>` (3b).
    var origin: String

    init(sha256: String, name: String, mimeType: String, size: Int, senderSession: UUID?, createdAt: Date, origin: String) {
        self.sha256 = sha256; self.name = name; self.mimeType = mimeType; self.size = size
        self.senderSession = senderSession; self.createdAt = createdAt; self.origin = origin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sha256 = try c.decode(String.self, forKey: .sha256)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? sha256
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "application/octet-stream"
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        senderSession = try c.decodeIfPresent(UUID.self, forKey: .senderSession)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? ""
    }
}

enum ArtifactLimits {
    static let perSend = 10
    static let fileBytes = 50 * 1024 * 1024
    static let dataPartBytes = 64 * 1024
    /// New artifact bytes one session may send in a day (§7.6 J).
    static let sessionDailyBytes = 200 * 1024 * 1024
    /// The whole exchange's default ceiling, in megabytes; Settings changes it.
    static let defaultExchangeCapMB = 2048
    /// How long an artifact nothing references is kept before the sweep removes it.
    static let graceSeconds: TimeInterval = 7 * 86_400
}

enum ArtifactError: Error, Equatable {
    case missing(String)
    /// The file's hash isn't its name: replaced by something other than the harness (§7.6 A).
    case corrupt(String)
    case tooLarge(Int)
    case exchangeFull(totalBytes: Int64, capBytes: Int64)

    var message: String {
        switch self {
        case .missing(let sha): return "artifact \(sha) isn't in the exchange any more."
        case .corrupt(let sha): return "artifact \(sha) is corrupt or was replaced, so it isn't read."
        case .tooLarge(let bytes): return "the file is \(Self.size(Int64(bytes))), over the \(Self.size(Int64(ArtifactLimits.fileBytes))) limit for an attachment."
        case .exchangeFull(let total, let cap):
            return "the attachment exchange holds \(Self.size(total)) of its \(Self.size(cap)) limit (Settings → Advanced → Session attachments), so no new attachment can be stored."
        }
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// The exchange directory: `<home>/exchange/<first two hex>/<sha256>` plus `<sha256>.json`.
/// Written only here. Every read checks the bytes against their name.
struct ArtifactStore: Sendable {
    let paths: IrisPaths

    init(paths: IrisPaths = .default) { self.paths = paths }

    var directory: URL { paths.exchangeDir }

    func fileURL(_ sha: String) -> URL {
        directory.appendingPathComponent(String(sha.prefix(2))).appendingPathComponent(sha)
    }

    func sidecarURL(_ sha: String) -> URL {
        directory.appendingPathComponent(String(sha.prefix(2))).appendingPathComponent(sha + ".json")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func mimeType(forName name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Stores `data` once (content-addressed: the same bytes are one artifact), refusing it when
    /// the exchange would pass `capBytes`. An artifact already present is not written again.
    func put(_ data: Data, name: String, sender: UUID?, origin: String, capBytes: Int64,
             now: Date = Date()) throws -> ArtifactSidecar {
        let sha = Self.sha256(data)
        if let existing = try? sidecar(sha), (try? Data(contentsOf: fileURL(sha))).map(Self.sha256) == sha {
            return existing
        }
        let total = totalBytes()
        guard total + Int64(data.count) <= capBytes else { throw ArtifactError.exchangeFull(totalBytes: total, capBytes: capBytes) }
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL(sha).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL(sha), options: .atomic)
        let side = ArtifactSidecar(sha256: sha, name: name, mimeType: Self.mimeType(forName: name), size: data.count,
                                   senderSession: sender, createdAt: now, origin: origin)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(side).write(to: sidecarURL(sha), options: .atomic)
        return side
    }

    func sidecar(_ sha: String) throws -> ArtifactSidecar {
        guard let data = try? Data(contentsOf: sidecarURL(sha)) else { throw ArtifactError.missing(sha) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ArtifactSidecar.self, from: data)
    }

    /// The artifact's bytes, only when they still hash to its name (§7.6 A): content addressing
    /// enforces immutability rather than claiming it.
    func read(_ sha: String) throws -> (data: Data, sidecar: ArtifactSidecar) {
        guard let data = try? Data(contentsOf: fileURL(sha)) else { throw ArtifactError.missing(sha) }
        guard Self.sha256(data) == sha else { throw ArtifactError.corrupt(sha) }
        let side = (try? sidecar(sha)) ?? ArtifactSidecar(sha256: sha, name: sha, mimeType: "application/octet-stream",
                                                         size: data.count, senderSession: nil, createdAt: .distantPast, origin: "")
        return (data, side)
    }

    /// Every artifact's hash, from the files present.
    func allHashes() -> [String] {
        let fm = FileManager.default
        guard let shards = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return shards.flatMap { shard -> [String] in
            let names = (try? fm.contentsOfDirectory(atPath: directory.appendingPathComponent(shard).path)) ?? []
            return names.filter { $0.count == 64 }
        }
    }

    func totalBytes() -> Int64 {
        allHashes().reduce(Int64(0)) { sum, sha in
            sum + Int64((try? FileManager.default.attributesOfItem(atPath: fileURL(sha).path)[.size] as? Int) ?? 0)
        }
    }

    func remove(_ sha: String) {
        try? FileManager.default.removeItem(at: fileURL(sha))
        try? FileManager.default.removeItem(at: sidecarURL(sha))
        try? FileManager.default.removeItem(at: orphanURL(sha))
    }

    /// When an artifact was first found unreferenced: the grace runs from the last reference
    /// going (§7.5), not from the artifact's creation.
    func orphanURL(_ sha: String) -> URL {
        directory.appendingPathComponent(String(sha.prefix(2))).appendingPathComponent(sha + ".orphan")
    }

    /// Removes artifacts no conversation has referenced for `grace`; marks newly unreferenced ones,
    /// and unmarks any referenced again. Returns the hashes removed.
    @discardableResult
    func sweep(referenced: Set<String>, now: Date = Date(), grace: TimeInterval = ArtifactLimits.graceSeconds) -> [String] {
        var removed: [String] = []
        for sha in allHashes() {
            let marker = orphanURL(sha)
            if referenced.contains(sha) {
                try? FileManager.default.removeItem(at: marker)
                continue
            }
            if let text = try? String(contentsOf: marker, encoding: .utf8),
               let since = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                if now.timeIntervalSince1970 - since >= grace { remove(sha); removed.append(sha) }
            } else {
                try? String(now.timeIntervalSince1970).write(to: marker, atomically: true, encoding: .utf8)
            }
        }
        return removed
    }
}

/// `artifact_refs` (#469 §8): a row per artifact, conversation and message. Written at send for
/// the sender and at delivery for each receiver, and nowhere else (§7.6 B). It decides who may
/// read an artifact, and keeps an artifact while any non-deleted conversation references it.
final class ArtifactLedger: Sendable {
    private let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) { self.writer = writer }

    func insert(sha: String, conversationId: UUID, msgId: String, sent: Bool, bytes: Int, at date: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO artifact_refs (sha256, conversationId, msgId, sent, bytes, createdAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [sha, conversationId.uuidString, msgId, sent, bytes, date])
        }
    }

    func hasRef(sha: String, conversationId: UUID) throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM artifact_refs WHERE sha256 = ? AND conversationId = ?)",
                              arguments: [sha, conversationId.uuidString]) ?? false
        }
    }

    /// The bytes `conversationId` has sent as new attachments since `date` (§7.6 J).
    func bytesSent(by conversationId: UUID, since date: Date) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM artifact_refs WHERE conversationId = ? AND sent = 1 AND createdAt >= ?",
                             arguments: [conversationId.uuidString, date]) ?? 0
        }
    }

    func referencedHashes() throws -> Set<String> {
        try writer.read { db in Set(try String.fetchAll(db, sql: "SELECT DISTINCT sha256 FROM artifact_refs")) }
    }

    func deleteRefs(involving conversationId: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM artifact_refs WHERE conversationId = ?", arguments: [conversationId.uuidString])
        }
    }
}
