import Foundation
import CryptoKit

/// Iris's own Ed25519 identity for agent-to-agent message signing (#974 H4 Task 1). One keypair
/// per build identity: `KeychainManager`'s dev/release service suffix keeps the dev build's key
/// separate from the release build's, so a peer enrolls the right one and a dev build can never
/// sign as the release identity. Later tasks (peer registry, signer, verifier) build on this.
public struct IrisSigningKey: Sendable {
    private let privateKey: Curve25519.Signing.PrivateKey

    /// A fresh random keypair. Only `IrisSigningKeyStore` should call this — everyone else loads
    /// the persisted key so the signing identity is stable across relaunches.
    init() {
        self.privateKey = Curve25519.Signing.PrivateKey()
    }

    /// Reconstructs from the base64 form of `rawRepresentation` (the 32-byte seed) as stored in
    /// the Keychain. `nil` for anything that isn't a valid 32-byte Curve25519 seed, so a corrupted
    /// stored value reads as "no usable key" rather than crashing.
    init?(base64Seed: String) {
        guard let seed = Data(base64Encoded: base64Seed),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
        self.privateKey = key
    }

    /// The base64 form of the 32-byte seed, for Keychain storage.
    var base64Seed: String { privateKey.rawRepresentation.base64EncodedString() }

    /// A 64-byte Ed25519 signature over `data`. `Curve25519.Signing.PrivateKey.signature(for:)`
    /// only throws for malformed key material, which cannot happen with a key constructed by this
    /// type (freshly generated, or decoded from a 32-byte seed by the failable initializer above),
    /// so this wraps it as the non-throwing interface the crypto-core consumers need.
    public func sign(_ data: Data) -> Data {
        guard let signature = try? privateKey.signature(for: data) else {
            preconditionFailure("Curve25519 signing failed for a validly-constructed IrisSigningKey")
        }
        return signature
    }

    /// The wire form of the public key, as romar's peer-signature protocol expects it:
    /// `"ed25519:"` followed by the standard base64 (RFC 4648, with padding) encoding of the raw
    /// 32-byte Ed25519 public key. Verified directly against the vendored conformance fixture
    /// (`Tests/irisTests/Fixtures/peer-signature-conformance.json`): its
    /// `negative_vectors[].pubkeys["clomp"]` entry, `"ed25519:A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="`,
    /// base64-decodes to exactly the 32 bytes in that same fixture's `public_hex`.
    public var publicKeyWireString: String {
        "ed25519:" + privateKey.publicKey.rawRepresentation.base64EncodedString()
    }
}

/// Keychain-backed store for `IrisSigningKey` (#974 H4 Task 1): one signing identity per build,
/// minted once and reused forever so a peer's pinned key stays valid across relaunches.
public struct IrisSigningKeyStore: Sendable {
    private let keychain: KeychainManager
    private let service: String

    public init(keychain: KeychainManager = .shared, service: String = KeychainManager.a2aSigningKeyService) {
        self.keychain = keychain
        self.service = service
    }

    /// Thrown instead of generating or returning a key that isn't durably persisted. A caller
    /// that can't tell "persisted" from "ephemeral" could sign with a key that's gone on the next
    /// relaunch, which breaks the pinned-key trust model this crypto core exists to support.
    public enum StoreError: Error, Equatable {
        /// `KeychainManager.areWritesBlocked` was set: the secrets item couldn't be read earlier
        /// in this process, so writing now would replace what's there with only what this call
        /// knows (#678's rationale, applied here rather than minting an ephemeral key instead).
        case writesBlocked
        /// A seed was stored under this service but doesn't decode as a 32-byte Curve25519 seed.
        case corruptSeed
    }

    private static let seedKey = "seed"

    /// Loads the persisted key, or mints and persists one if none exists yet. The absent-check,
    /// generate and store all happen inside one `updateSecretsOrThrow` mutate, which runs under
    /// `KeychainManager`'s single cross-instance lock (#750) — so two callers racing here can
    /// never mint two different seeds; whichever runs second always sees what the first just
    /// wrote and returns that instead of generating its own.
    public func loadOrCreate() throws -> IrisSigningKey {
        if keychain.areWritesBlocked { throw StoreError.writesBlocked }
        var minted: IrisSigningKey?
        var corrupt = false
        try keychain.updateSecretsOrThrow(service: service) { secrets in
            if let seed = secrets[Self.seedKey] {
                guard let existing = IrisSigningKey(base64Seed: seed) else {
                    corrupt = true
                    return
                }
                minted = existing
                return
            }
            let fresh = IrisSigningKey()
            secrets[Self.seedKey] = fresh.base64Seed
            minted = fresh
        }
        if corrupt { throw StoreError.corruptSeed }
        guard let key = minted else { throw StoreError.corruptSeed }
        return key
    }

    /// `nil` only if `loadOrCreate` was never called for this service; any Keychain read failure
    /// throws rather than reading as "never created" (`secretsOrThrow`'s contract).
    public func current() throws -> IrisSigningKey? {
        let secrets = try keychain.secretsOrThrow(service: service)
        guard let seed = secrets[Self.seedKey] else { return nil }
        guard let key = IrisSigningKey(base64Seed: seed) else { throw StoreError.corruptSeed }
        return key
    }

    /// The wire-form public key for enrollment display. Mints the key if it doesn't exist yet, so
    /// the first-run enrollment flow doesn't need a separate "ensure key exists" step. Which
    /// build's key this is comes from the caller's `KeychainManager` — its dev/release service
    /// suffix is already baked in, so dev and release Iris always show different keys.
    public func publicKeyWireString() throws -> String {
        try loadOrCreate().publicKeyWireString
    }
}
