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

    /// `config/a2a-peers/`. Already inside `IrisPaths.protectedWriteDirs` (via `configDir`), the
    /// same boundary as the rest of `config/` — no stronger a guarantee for this registry
    /// specifically (peer review, PR #1036 Finding 2). That boundary: a `write_file` call into
    /// this directory always asks and can never be covered by a standing grant; a shell command
    /// writing here (e.g. `echo '[...]' > ~/.iris/config/a2a-peers/x.json`) is judged exactly like
    /// any other shell command — asked unless an allowlist, grant or auto-approve covers it. A
    /// planted key here would be the one thing that breaks this whole core's trust model, so this
    /// boundary matters even though it is not specific to this file.
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

    /// The 8 known small-order Ed25519 point encodings (the torsion subgroup of order dividing 8
    /// under the curve's cofactor) — order-1 (identity), the one order-2 point, the two order-4
    /// points, and the four order-8 points, each as its canonical 32-byte compressed encoding.
    /// `Curve25519.Signing.PublicKey(rawRepresentation:)` only checks the byte count, not whether
    /// the point has full order, so a key equal to one of these can make `isValidSignature`
    /// return true independent of what was actually signed (peer review, PR #1036 Finding 3 — "I
    /// would not defer this one; it is the trust root"). Derived and verified independently here
    /// rather than trusted from memory: generated via the curve's own group law (a random curve
    /// point scaled by the prime-subgroup order ℓ lands in the 8-torsion subgroup; its 8 multiples
    /// are exactly these 8 points), with the decompression/arithmetic used to derive them checked
    /// against the published Ed25519 base point's x-coordinate before trusting the result.
    private static let smallOrderEncodings: Set<Data> = [
        Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
        Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80]),
        Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
        Data([0x26, 0xe8, 0x95, 0x8f, 0xc2, 0xb2, 0x27, 0xb0, 0x45, 0xc3, 0xf4, 0x89, 0xf2, 0xef, 0x98, 0xf0, 0xd5, 0xdf, 0xac, 0x05, 0xd3, 0xc6, 0x33, 0x39, 0xb1, 0x38, 0x02, 0x88, 0x6d, 0x53, 0xfc, 0x05]),
        Data([0x26, 0xe8, 0x95, 0x8f, 0xc2, 0xb2, 0x27, 0xb0, 0x45, 0xc3, 0xf4, 0x89, 0xf2, 0xef, 0x98, 0xf0, 0xd5, 0xdf, 0xac, 0x05, 0xd3, 0xc6, 0x33, 0x39, 0xb1, 0x38, 0x02, 0x88, 0x6d, 0x53, 0xfc, 0x85]),
        Data([0xc7, 0x17, 0x6a, 0x70, 0x3d, 0x4d, 0xd8, 0x4f, 0xba, 0x3c, 0x0b, 0x76, 0x0d, 0x10, 0x67, 0x0f, 0x2a, 0x20, 0x53, 0xfa, 0x2c, 0x39, 0xcc, 0xc6, 0x4e, 0xc7, 0xfd, 0x77, 0x92, 0xac, 0x03, 0x7a]),
        Data([0xc7, 0x17, 0x6a, 0x70, 0x3d, 0x4d, 0xd8, 0x4f, 0xba, 0x3c, 0x0b, 0x76, 0x0d, 0x10, 0x67, 0x0f, 0x2a, 0x20, 0x53, 0xfa, 0x2c, 0x39, 0xcc, 0xc6, 0x4e, 0xc7, 0xfd, 0x77, 0x92, 0xac, 0x03, 0xfa]),
        Data([0xec, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f]),
    ]

    /// The small-order points' y-coordinates with the sign bit cleared: a point is small-order
    /// whichever sign bit its encoding carries, so `01 00..80` (x = 0 "negative") and
    /// `ec ff..ff` are the same points as entries above, spelled the way a canonical-only
    /// byte match misses.
    private static let smallOrderYs: Set<Data> = Set(smallOrderEncodings.map(clearingSignBit))

    private static func clearingSignBit(_ encoding: Data) -> Data {
        var bytes = Array(encoding)
        bytes[31] &= 0x7f
        return Data(bytes)
    }

    /// True for a small-order point under any spelling: a canonical encoding, the same y with the
    /// other sign bit, or a non-canonical y >= p = 2^255 - 19 (only y < 19 has such a spelling,
    /// `ed ff..7f` for y = 0 and `ee ff..7f` for y = 1, each with either sign bit) that reduces
    /// to one. Libraries disagree on whether to decode a non-canonical y; CryptoKit accepts it as
    /// key material, so whether such a key can forge depends on its verifier, which is not a
    /// property to trust here (#1038). Any y >= p is refused, small-order or not: no honest
    /// signer produces one.
    private static func isSmallOrderOrAlias(_ encoding: Data) -> Bool {
        guard encoding.count == 32 else { return false }
        let y = clearingSignBit(encoding)
        if smallOrderYs.contains(y) { return true }
        let bytes = Array(y)
        let highBytesAllOnes = bytes[1..<31].allSatisfy { $0 == 0xff } && bytes[31] == 0x7f
        return highBytesAllOnes && bytes[0] >= 0xed
    }

    /// `nil` for anything that isn't valid Ed25519 key material in romar's wire form, AND for a
    /// small-order point (above) even though that *is* 32 bytes of validly-shaped key material —
    /// a small-order public key breaks `isValidSignature`'s soundness, so this registry must never
    /// hand one to a verifier. Checked at both `enroll` (refuse to persist one) and `resolve`
    /// (refuse to resolve one, catching a stale or hand-edited file that already has one), since
    /// both call through here.
    private static func parsePublicKey(_ wire: String) -> Curve25519.Signing.PublicKey? {
        guard wire.hasPrefix(wirePrefix) else { return nil }
        guard let data = Data(base64Encoded: String(wire.dropFirst(wirePrefix.count))) else { return nil }
        guard !isSmallOrderOrAlias(data) else { return nil }
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
        // Refuse to persist key material `parsePublicKey` would refuse to resolve — in
        // particular a small-order point (peer review, PR #1036 Finding 3): persisting one and
        // only discovering it at the next `resolve` would leave a trusted-looking record on disk
        // that can never actually verify anything.
        guard Self.parsePublicKey(key.publicKey) != nil else { throw RegistryError.unavailable }
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
