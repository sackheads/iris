import CryptoKit
import Foundation

/// One peer's registered public key under a profile (principal) name (#974 H4 Task 2). `profile`
/// is carried inside the record itself, not just implied by the filename it was loaded from, so
/// `resolve` can check it exactly against the file it opened — the defence against a mis-cased or
/// hand-moved file answering for the wrong principal on a case-insensitive volume.
struct RegisteredKey: Codable, Sendable, Equatable {
    let profile: String
    let keyId: String
    /// romar's wire form: `"ed25519:"` + standard base64 of the raw 32-byte public key (see
    /// `IrisSigningKey.publicKeyWireString`).
    let publicKey: String

    // Invariant 1: these three fields are required and decode with the synthesized initializer.
    // Any field added after them must arrive via `decodeIfPresent` in a custom `init(from:)`
    // (see `AgentProfileSnapshot.init(from:)` for the shape) — a plain stored property throws on
    // decode for every already-written record, which quarantines a whole principal's file.
}

/// Thrown by `enroll` when `keyId` is already registered for that profile under a *different*
/// public key. Silent replacement would let one enroll call quietly substitute another peer's
/// key; rotating a key is `revoke` then `enroll`, never a second `enroll` of the same id.
struct PeerKeySubstitutionError: Error, Equatable {
    let profile: String
    let keyId: String
}

/// A `<principal>.json` that exists but can't be read as `[RegisteredKey]` (truncated, not JSON,
/// or a record whose `publicKey` doesn't decode as Curve25519 key material) — distinct from a
/// clean "no such key". The eventual A2A verifier must map this to a fail-closed rejection, never
/// to "unknown key": a damaged trust file is not the same claim as an unenrolled one.
enum RegistryError: Error, Equatable {
    case unavailable
}

/// Per-profile registry of OTHER peers' Ed25519 public keys, for verifying signed A2A messages
/// (#974 H4 Task 2). The other side of Task 1's `IrisSigningKey`/`IrisSigningKeyStore`: that pair
/// is Iris's own signing identity; this one is who Iris is willing to trust claiming to be someone
/// else. One `<profile>.json` file per principal under `config/a2a-peers/`, each holding a
/// `[RegisteredKey]`.
///
/// **No flat global keyId→key map, no gateway-key fallback (romar#403).** `resolve` looks up
/// strictly within the *claimed* principal's own file: a key id is scoped to one profile, and a
/// signature verifying under a key enrolled for `rune` must never authenticate a message claiming
/// to be from `clomp`, even if the two profiles' files happen to use the same `keyId` string by
/// coincidence. There is exactly one lookup path — the claimed principal's file — and no shared
/// namespace a lookup could fall through to.
///
/// **A2A-scoped only.** This registry lives at `config/a2a-peers/`; #965 (MCP) must not read it
/// directly. An A2A-enrolled `clomp` key would otherwise authenticate an MCP guest also claiming
/// to be `clomp` — domain separation in the signed payload stops cross-protocol signature *reuse*,
/// but not identity *collision* (#999 M4). MCP gets its own registry, or a future shared one is
/// keyed by `(transport, principal)`; neither is built here.
struct PeerKeyRegistry: Sendable {
    let paths: IrisPaths

    init(paths: IrisPaths = .default) {
        self.paths = paths
    }

    /// `config/a2a-peers/`. Already inside `IrisPaths.protectedWriteDirs` (via `configDir`), so
    /// no tool call or model-driven write can plant or alter a trusted peer key here.
    var directory: URL { paths.a2aPeersDir }

    private static let wirePrefix = "ed25519:"

    /// A name safe to use as `<name>.json` under `directory`: the same single-path-component rule
    /// `AgentProfileStore.isValidName` already uses for profile names (lowercase letters, digits,
    /// dash; non-empty; at most 32 characters) — reused rather than reinvented. This rejects `/`,
    /// `..`, NUL, empty and over-long names before any `URL` is built from them, which matters
    /// because `resolve`'s `principal` is attacker-controlled wire data, read before any signature
    /// is checked: an unsafe name must return `nil` without a single filesystem call outside
    /// (indeed, without any call at all) `directory`.
    private static func isSafeName(_ name: String) -> Bool {
        AgentProfileStore.isValidName(name)
    }

    private func fileURL(for name: String) -> URL {
        directory.appendingPathComponent(name + ".json")
    }

    private static func parsePublicKey(_ wire: String) -> Curve25519.Signing.PublicKey? {
        guard wire.hasPrefix(wirePrefix) else { return nil }
        guard let data = Data(base64Encoded: String(wire.dropFirst(wirePrefix.count))) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    /// Looks up a peer's public key. `principal` is treated as hostile: validated before any path
    /// is built, and the only record that can answer is one whose stored `profile` field equals
    /// `principal` exactly (not merely "the file this name happened to open" — APFS folds case, so
    /// a mis-cased or hand-moved file must never answer for another principal). `keyId` defaults
    /// to `principal`, the "my own name is my default key id" convention.
    func resolve(principal: String, keyId: String?) throws -> Curve25519.Signing.PublicKey? {
        guard Self.isSafeName(principal) else { return nil }
        let records = try load(principal)
        let wantedKeyId = keyId ?? principal
        guard let record = records.first(where: { $0.profile == principal && $0.keyId == wantedKeyId }) else {
            return nil
        }
        guard let key = Self.parsePublicKey(record.publicKey) else {
            // Fail closed, not nil: a stored record that matched but won't parse as key material
            // is damage, not an absent key, and must not read as "unknown" to the verifier.
            throw RegistryError.unavailable
        }
        return key
    }

    /// Registers `key`, or throws `PeerKeySubstitutionError` if its `keyId` is already registered
    /// under that profile with a different `publicKey`. Re-enrolling the exact same (keyId,
    /// publicKey) pair is a no-op, not an error, so re-running an enrollment step is safe.
    func enroll(_ key: RegisteredKey) throws {
        // Unlike `resolve` (nil for an unsafe name — attacker-controlled wire data), this throws:
        // `key.profile` here is always a caller-supplied value, never wire data pre-signature, and
        // no legitimate caller can produce an invalid one (profiles are created and validated
        // through `AgentProfileStore.isValidName` elsewhere). Reusing `.unavailable` for "can't
        // locate the file safely" is a slight overload of its documented "damaged file" meaning,
        // accepted because this path is unreachable for any real caller.
        guard Self.isSafeName(key.profile) else { throw RegistryError.unavailable }
        try withLock(for: key.profile) {
            var records = try load(key.profile)
            if let existing = records.first(where: { $0.keyId == key.keyId }) {
                guard existing.publicKey == key.publicKey else {
                    throw PeerKeySubstitutionError(profile: key.profile, keyId: key.keyId)
                }
                return
            }
            records.append(key)
            try save(records, for: key.profile)
        }
    }

    /// Removes the key `keyId` (defaulting to `profile`, matching `resolve`'s convention) from
    /// that profile's keyset. Takes effect for the very next `resolve` call. A no-op if no such
    /// key was registered.
    func revoke(profile: String, keyId: String?) throws {
        // See the comment on the same guard in `enroll`: this is caller input, not wire data, so
        // throwing (rather than `resolve`'s nil-for-unsafe-name) is fine — no real caller path
        // reaches an invalid name here.
        guard Self.isSafeName(profile) else { throw RegistryError.unavailable }
        try withLock(for: profile) {
            var records = try load(profile)
            let wanted = keyId ?? profile
            records.removeAll { $0.keyId == wanted }
            try save(records, for: profile)
        }
    }

    /// Every key registered for `profile`, or `[]` if none have been enrolled yet.
    func list(profile: String) throws -> [RegisteredKey] {
        // See the comment on the same guard in `enroll`: caller input, not wire data.
        guard Self.isSafeName(profile) else { throw RegistryError.unavailable }
        return try load(profile)
    }

    /// `[]` when `<name>.json` doesn't exist (an empty keyset, not an error). Throws
    /// `.unavailable` for anything present but unreadable, so a caller can tell damage from
    /// absence — isolated to this one principal's file; a corrupt `rune.json` never prevents
    /// `clomp.json` from loading.
    private func load(_ name: String) throws -> [RegisteredKey] {
        let url = fileURL(for: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = FileManager.default.contents(atPath: url.path),
              let records = try? JSONDecoder().decode([RegisteredKey].self, from: data) else {
            throw RegistryError.unavailable
        }
        return records
    }

    /// Atomic temp-file-then-rename write, the same idiom `Tier2Scores.save()` uses for its own
    /// per-file JSON store: `Data.write(options: .atomic)` never leaves a half-written file for a
    /// concurrent reader to open.
    private func save(_ records: [RegisteredKey], for name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: fileURL(for: name), options: .atomic)
    }

    /// Serializes `enroll`/`revoke`'s read-modify-write per (registry directory, profile) within
    /// this process, so two concurrent calls can't both pass the key-substitution check before
    /// either writes. Keyed by directory so distinct `PeerKeyRegistry` instances over the same
    /// `IrisPaths.root` (and distinct test temp dirs) don't share a lock unnecessarily. This does
    /// not make the registry safe across processes — only one Iris process is expected to manage
    /// enrollment at a time, same scope as the rest of `config/`.
    private static let locksLock = NSLock()
    nonisolated(unsafe) private static var locks: [String: NSLock] = [:]

    private func withLock<T>(for name: String, _ body: () throws -> T) throws -> T {
        let key = directory.path + "/" + name
        let lock = Self.locksLock.withLock {
            if let existing = Self.locks[key] { return existing }
            let fresh = NSLock()
            Self.locks[key] = fresh
            return fresh
        }
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
