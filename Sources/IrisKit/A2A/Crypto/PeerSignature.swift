import Foundation

/// Domain separators for the signing input romar's peer-signature protocol signs (#974 H4 Task
/// 3). Keeping the string in exactly one place means a future protocol version change touches one
/// constant, not every call site that builds a signing input.
public enum PeerSignatureDomain {
    /// romar's A2A jetstream domain, version 0.4. Verified byte-for-byte against the vendored
    /// conformance fixture's `protocol_domain` field
    /// (`Tests/irisTests/Fixtures/peer-signature-conformance.json`) — not re-read from romar §4,
    /// which isn't in this repo.
    public static let a2a = "a2a-jetstream/0.4"
}

/// Builds the exact bytes that get Ed25519-signed: the domain string's UTF-8 bytes, a single
/// newline (`0x0a`), then the envelope bytes `B` verbatim. No canonicalization of `B` — it signs
/// precisely the bytes it is given, never re-serializing or normalizing them, so the signer and a
/// later verifier agree on the input only if both are handed the identical wire bytes.
///
/// Construction confirmed against the vendored conformance fixture: its `signing_input_hex` bytes
/// are exactly `protocol_domain + "\n" + B_hex`'s bytes (`Tests/irisTests/Fixtures/peer-signature-conformance.json`).
public func signingInput(domain: String, envelopeBytes B: Data) -> Data {
    var input = Data(domain.utf8)
    input.append(0x0a)
    input.append(B)
    return input
}

/// The signer output / verifier input for one signed A2A frame (#974 H4 Task 3). The transport
/// serializes this into / parses it out of romar's outer frame (#931 Task 1) — this type carries
/// the fields, not the wire encoding.
public struct SignedFrameParts: Sendable {
    public let principal: String
    public let keyId: String?
    public let verifiedBy: String
    public let signature: Data
    public let envelopeBytes: Data

    public init(principal: String, keyId: String?, verifiedBy: String, signature: Data, envelopeBytes: Data) {
        self.principal = principal
        self.keyId = keyId
        self.verifiedBy = verifiedBy
        self.signature = signature
        self.envelopeBytes = envelopeBytes
    }
}

/// Signs outbound A2A envelope bytes with Iris's own `IrisSigningKey` (#974 H4 Task 3). The
/// counterpart to a later verifier, which re-derives `signingInput` the same way to check an
/// incoming `SignedFrameParts`.
public struct PeerSigner: Sendable {
    private let key: IrisSigningKey

    public init(key: IrisSigningKey) {
        self.key = key
    }

    /// romar's `verifiedBy` value for a direct (non-gateway-attested) Ed25519 signature. Matches
    /// the vendored conformance fixture's `negative_vectors[].frame.identity.verifiedBy` for
    /// every vector except the one deliberately testing gateway-attestation rejection
    /// (`"a2a-gateway"`), which this signer never produces.
    private static let directVerifiedBy = "ed25519"

    /// Signs `B` over the domain-separated `signingInput(domain, B)`, never over `B` directly —
    /// so a signature produced here only verifies against the same domain-separated construction
    /// a verifier must also use. `domain` is always `PeerSignatureDomain.a2a` — not a per-call
    /// parameter (peer review, PR #1036 Finding 1): a transport that could pass a non-default
    /// domain would defeat the whole point of domain separation, so nothing above this signer can
    /// choose it.
    public func sign(envelopeBytes B: Data, principal: String, keyId: String?) -> SignedFrameParts {
        let input = signingInput(domain: PeerSignatureDomain.a2a, envelopeBytes: B)
        let signature = key.sign(input)
        return SignedFrameParts(
            principal: principal,
            keyId: keyId,
            verifiedBy: Self.directVerifiedBy,
            signature: signature,
            envelopeBytes: B
        )
    }
}
