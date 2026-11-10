import CryptoKit
import Foundation

/// The transport-neutral channel a signed A2A frame arrived on (#974 H4 Task 4). Maps to whatever
/// NATS subject or queue the transport actually uses — this type never spells one out, so the
/// crypto core stays independent of the wire transport.
enum A2AChannel: Sendable, Equatable {
    case inbox
    case events

    /// romar §5.1's kind-per-channel table. A kind outside its channel's set is
    /// `.channelKindMismatch` — there is no other table to fall back to.
    var allowedKinds: Set<String> {
        switch self {
        case .inbox: return ["message", "cancel"]
        case .events: return ["status-update", "artifact-update"]
        }
    }
}

/// What the transport maps its decoded envelope onto so the verifier never needs to know the
/// transport's own envelope type (#974 H4 Task 4). `deadline` is the envelope's metadata deadline
/// (romar: `payload.metadata.deadline`), required only when `kind == "message"`.
protocol VerifiableEnvelope: Sendable {
    var fromProfile: String { get }
    var toProfile: String? { get }
    var kind: String { get }
    var envelopeId: String { get }
    var ts: String { get }
    var deadline: String? { get }
    var taskId: String? { get }
    var correlationId: String? { get }
}

/// The request Iris is still waiting on a reply to, for binding an inbound `.events` frame back
/// to it. `addressee` is the peer Iris originally sent the request to — the peer we expect to be
/// the one now reporting status on it.
struct OutstandingRequest: Sendable, Equatable {
    let addressee: String
    let taskId: String
    let correlationId: String?
}

/// Everything `verifyAndAdmit` needs beyond the signed frame itself: who "we" are for recipient
/// binding, which channel this frame arrived on, what (if anything) it binds to, and the injected
/// clock (AGENTS.md Invariant 7 — this type, not the verifier, is where `now` enters; the verifier
/// itself never reads the system clock).
struct VerificationContext: Sendable, Equatable {
    let selfProfile: String
    let channel: A2AChannel
    let outstanding: OutstandingRequest?
    let now: Date

    init(selfProfile: String, channel: A2AChannel, outstanding: OutstandingRequest?, now: Date) {
        self.selfProfile = selfProfile
        self.channel = channel
        self.outstanding = outstanding
        self.now = now
    }
}

/// One case per romar §5.1/§6 reason code (#974 H4 Task 4), raw values exactly as romar spells
/// them — these are wire-visible-by-name-only (never serialized back to the sender, but the
/// string is what a human reading a rejection log should see). 14 of the 18 are directly exercised
/// by the vendored conformance fixture (`Tests/irisTests/Fixtures/peer-signature-conformance.json`,
/// `negative_vectors`); the other four (`eventsRequestMismatch`, `duplicateEnvelopeId`,
/// `seenSetFull`, `seenSetUnavailable`) have no vendored vector and are covered by this task's own
/// tests instead.
enum PeerRejectReason: String, Sendable, Equatable {
    case invalidSignature = "invalid_signature"
    case unknownKey = "unknown_key"
    case recipientMismatch = "recipient_mismatch"
    case principalMismatch = "principal_mismatch"
    case duplicateKey = "duplicate_key"
    case deadlineMissing = "deadline_missing"
    case deadlineExpired = "deadline_expired"
    case deadlineOverCap = "deadline_over_cap"
    case tsInFuture = "ts_in_future"
    case tsMissing = "ts_missing"
    case tsInvalid = "ts_invalid"
    case envelopeIdMissing = "envelope_id_missing"
    case channelKindMismatch = "channel_kind_mismatch"
    case gatewayAttestedRejected = "gateway_attested_rejected"
    case eventsRequestMismatch = "events_request_mismatch"
    case duplicateEnvelopeId = "duplicate_envelope_id"
    case seenSetFull = "seen_set_full"
    case seenSetUnavailable = "seen_set_unavailable"
}

/// Thrown by `verifyAndAdmit` for any romar-defined rejection. `envelopeId` is `nil` until the
/// envelope has been decoded (every check before `decode` runs — signature, duplicate-key scan —
/// cannot yet name the envelope it rejected).
struct PeerVerificationError: Error, Sendable, Equatable {
    let reason: PeerRejectReason
    let envelopeId: String?
}

/// Thrown when the caller hands `verifyAndAdmit` a `VerificationContext` that cannot correspond to
/// any real wire frame — not a romar rejection (no signed frame produced this), a contract
/// violation by the transport code calling this verifier. `.inbox` never carries an
/// `OutstandingRequest`: binding an inbox message to one would let an event be routed through
/// inbox rules.
struct VerifierUsageError: Error, Sendable, Equatable {
    let message: String
}

/// Thrown by `StrictJSON.rejectDuplicateKeys`. `.duplicateKey` — any single JSON object in the
/// scanned bytes repeats a key — is the one `verifyAndAdmit` maps to `PeerRejectReason.duplicateKey`;
/// the rest are this scanner's own fail-closed signals for bytes that are not the strict UTF-8
/// JSON romar's wire format requires, and `verifyAndAdmit` propagates them unmodified (romar names
/// no code for "malformed/wrong-encoding envelope" — same precedent as `RegistryError.unavailable`
/// above: an undefined-by-romar failure fails closed via its own error type rather than being
/// mapped to a `PeerRejectReason` that would misrepresent what went wrong).
///
/// - `.invalidEncoding`: the bytes carry a UTF-8 BOM, or are not valid UTF-8 at all.
/// - `.malformed`: the bytes don't parse as strict JSON — an unrecognized token, an unterminated
///   string, an invalid `\u` escape or surrogate pair, trailing garbage after the top-level value,
///   etc. (Review finding, Critical: earlier versions of this scanner silently returned instead of
///   throwing here, which let a BOM-prefixed, UTF-16/UTF-32-encoded, or JSON5-unquoted-key payload
///   — all of which `JSONSerialization` decodes without complaint — sail past the duplicate-key
///   scan the core is supposed to own.)
/// - `.tooDeep`: nesting exceeded `DuplicateKeyScanner.maxDepth` — bounds the scanner's own
///   recursion so a deeply nested payload can't overflow the stack (Review finding, Important).
enum StrictJSONError: Error, Equatable {
    case duplicateKey
    case invalidEncoding
    case malformed
    case tooDeep
}

/// Thrown by a transport's `decode` closure when a required wire field is absent (or, as this
/// task's own tests treat it, present but unusable — e.g. JSON `null` where a `String` is
/// required). `verifyAndAdmit` maps the ones romar names a `*_missing` code for
/// (`envelopeId`, `ts`) to that code; any other field name is rethrown unmapped, since no romar
/// code exists for it and swallowing it into one would misreport the rejection.
enum FrameDecodeError: Error, Equatable {
    case missingRequiredField(String)
}

/// What one atomic `SeenSetStore.admit` call reports: `.fresh` for the first caller of a
/// `(peer, envelopeId)` pair, `.duplicate` for every caller after it.
enum AdmitResult: Sendable, Equatable {
    case fresh
    case duplicate
}

/// Thrown by a `SeenSetStore.admit` implementation when it cannot honestly answer `.fresh` or
/// `.duplicate` — `.full` when `maxPerPeer` is already reached for `peer` and admitting would have
/// to evict something still inside its own `retainUntil`, `.unavailable` when the store itself
/// (e.g. the GRDB ledger's database) cannot be read or written right now. Both fail closed:
/// `verifyAndAdmit` maps them to `.seenSetFull`/`.seenSetUnavailable`, never to `.fresh`.
enum SeenSetStoreError: Error, Sendable, Equatable {
    case full
    case unavailable
}

/// The replay-defence ledger `verifyAndAdmit` consumes: one atomic check-and-record per inbound
/// frame, so two concurrent callers for the same `(peer, envelopeId)` can never both observe
/// `.fresh` (TOCTOU — a separate `contains` then `insert` would race). The id is recorded before
/// the first caller's `.fresh` is returned (write-before-execute), so a crash between "recorded"
/// and "acted on" fails closed (a replay after a crash reads as a duplicate, not as fresh) rather
/// than open. `now` is injected (AGENTS.md Invariant 7) for the store's own opportunistic pruning
/// of ids past their `retainUntil`. The GRDB `A2ASeenLedger` (#974 H4 Task 5) and an in-memory test
/// stub both conform.
protocol SeenSetStore: Sendable {
    func admit(peer: String, envelopeId: String, retainUntil: Date, maxPerPeer: Int, now: Date) throws -> AdmitResult
}

/// A small raw-bytes JSON validator and duplicate-key scanner over one JSON document (#974 H4
/// Task 4). Exists because `JSONDecoder`/`JSONSerialization` resolve a duplicate key by silently
/// keeping the last value — exactly the fail-open a transport's naive decode closure could
/// reproduce without ever being told. The core owns this scan over the raw bytes `B` itself,
/// before any decode runs, so no transport implementation can skip it.
///
/// Fails closed on anything that isn't strict, bare-UTF-8 JSON (Review finding, Critical): a
/// BOM-prefixed, UTF-16/UTF-32-encoded, or JSON5-style-unquoted-key payload all decode cleanly
/// under `JSONSerialization`, so a scanner that stayed silent on "not quite JSON" bytes it didn't
/// recognize would let exactly those bypass the duplicate-key guarantee this type exists to give.
/// Every unrecognized byte, state or trailing garbage after the top-level value throws rather than
/// returning — this is now a validating scan, not a best-effort one.
enum StrictJSON {
    static func rejectDuplicateKeys(_ bytes: Data) throws {
        let array = Array(bytes)
        // A UTF-8 BOM is itself valid UTF-8 (it decodes as U+FEFF), so the UTF-8-validity check
        // below would not catch it on its own — romar's wire format is bare UTF-8, never
        // BOM-prefixed, so reject it outright before any structural scan.
        if array.count >= 3, array[0] == 0xEF, array[1] == 0xBB, array[2] == 0xBF {
            throw StrictJSONError.invalidEncoding
        }
        // Rejects UTF-16/UTF-32-encoded bytes that contain any invalid UTF-8 continuation
        // sequence. Does NOT by itself reject an all-ASCII UTF-16 payload (its interleaved NUL
        // bytes are themselves valid lone UTF-8 code points) — the strict structural scan below,
        // which now throws on any unrecognized byte instead of silently returning, is what catches
        // that case (a NUL byte where a key's opening quote or a value's leading token is
        // expected is simply not valid JSON).
        guard String(bytes: array, encoding: .utf8) != nil else {
            throw StrictJSONError.invalidEncoding
        }
        var scanner = DuplicateKeyScanner(array)
        try scanner.scanValue()
        try scanner.expectEndOfInput()
    }
}

private struct DuplicateKeyScanner {
    /// Bounds this scanner's own recursion so a deeply nested payload throws instead of
    /// overflowing the stack (Review finding, Important: ~20,000 nested brackets in a ~20KB
    /// payload reproduced a stack-overflow crash before this bound existed). 64 is generous
    /// headroom under a debug (`-Onone`) build's ~512KB cooperative-pool thread stack — a
    /// follow-up review measured a 500-deep payload using roughly 93% of that stack in a debug
    /// build before the transport's own call frames are even counted, overflowing around depth
    /// 540-550 with no cap at all (vs. 4,000-8,000 in a release build); the vendored fixture's own
    /// envelope nests only 4-5 levels deep, so there is no legitimate-payload reason to need more
    /// than a small multiple of that.
    private static let maxDepth = 64

    private let bytes: [UInt8]
    private var index: Int = 0
    private var depth = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func skipWhitespace() {
        while let b = peek(), b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
            index += 1
        }
    }

    /// Nothing may follow the top-level value but whitespace — trailing garbage is itself a
    /// fail-closed signal (Review finding, Critical).
    mutating func expectEndOfInput() throws {
        skipWhitespace()
        guard peek() == nil else { throw StrictJSONError.malformed }
    }

    mutating func scanValue() throws {
        skipWhitespace()
        guard let b = peek() else { throw StrictJSONError.malformed } // a value was expected
        switch b {
        case 0x7B: try scanObject()           // {
        case 0x5B: try scanArray()            // [
        case 0x22: _ = try scanString()       // "
        case 0x74: try expectLiteral("true")
        case 0x66: try expectLiteral("false")
        case 0x6E: try expectLiteral("null")
        case 0x2D, 0x30...0x39: try scanNumber() // - or a digit
        default: throw StrictJSONError.malformed // not a recognized JSON token
        }
    }

    private mutating func enterNesting() throws {
        depth += 1
        guard depth <= Self.maxDepth else { throw StrictJSONError.tooDeep }
    }

    private mutating func exitNesting() {
        depth -= 1
    }

    private mutating func scanObject() throws {
        try enterNesting()
        defer { exitNesting() }
        index += 1 // consume {
        var keys = Set<String>()
        skipWhitespace()
        if peek() == 0x7D { index += 1; return } // empty object
        while true {
            skipWhitespace()
            guard peek() == 0x22 else { throw StrictJSONError.malformed } // a quoted key was expected
            let key = try scanString()
            if !keys.insert(key).inserted {
                throw StrictJSONError.duplicateKey
            }
            skipWhitespace()
            guard peek() == 0x3A else { throw StrictJSONError.malformed } // :
            index += 1
            try scanValue()
            skipWhitespace()
            if peek() == 0x2C { index += 1; continue } // ,
            break
        }
        skipWhitespace()
        guard peek() == 0x7D else { throw StrictJSONError.malformed }
        index += 1
    }

    private mutating func scanArray() throws {
        try enterNesting()
        defer { exitNesting() }
        index += 1 // consume [
        skipWhitespace()
        if peek() == 0x5D { index += 1; return } // empty array
        while true {
            try scanValue()
            skipWhitespace()
            if peek() == 0x2C { index += 1; continue }
            break
        }
        skipWhitespace()
        guard peek() == 0x5D else { throw StrictJSONError.malformed }
        index += 1
    }

    private mutating func expectLiteral(_ literal: String) throws {
        for expected in literal.utf8 {
            guard peek() == expected else { throw StrictJSONError.malformed }
            index += 1
        }
    }

    /// A JSON number: `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`. Grammar-checked, not
    /// value-parsed — this scanner only needs to consume exactly the bytes a number occupies, not
    /// the numeric value itself (romar's bignum/scientific-notation conformance values are handled
    /// the same way a decoder would).
    private mutating func scanNumber() throws {
        if peek() == 0x2D { index += 1 } // -
        guard let first = peek(), (0x30...0x39).contains(first) else { throw StrictJSONError.malformed }
        if first == 0x30 {
            index += 1 // a leading zero stands alone in the integer part
        } else {
            while let d = peek(), (0x30...0x39).contains(d) { index += 1 }
        }
        if peek() == 0x2E { // .
            index += 1
            guard let d = peek(), (0x30...0x39).contains(d) else { throw StrictJSONError.malformed }
            while let d2 = peek(), (0x30...0x39).contains(d2) { index += 1 }
        }
        if let e = peek(), e == 0x65 || e == 0x45 { // e / E
            index += 1
            if let sign = peek(), sign == 0x2B || sign == 0x2D { index += 1 }
            guard let d = peek(), (0x30...0x39).contains(d) else { throw StrictJSONError.malformed }
            while let d2 = peek(), (0x30...0x39).contains(d2) { index += 1 }
        }
    }

    /// Returns the string's *decoded* content (escapes resolved), so two keys that are the same
    /// character sequence written with different escaping (`"a"` vs `"\u0061"`) are still caught
    /// as the same key — comparing raw bytes between the quotes would miss that.
    private mutating func scanString() throws -> String {
        index += 1 // consume opening quote
        var decoded: [UInt8] = []
        while let b = peek() {
            index += 1
            if b == 0x22 { return String(decoding: decoded, as: UTF8.self) }
            if b == 0x5C {
                guard let esc = peek() else { throw StrictJSONError.malformed } // backslash at EOF
                index += 1
                switch esc {
                case 0x22: decoded.append(0x22) // \"
                case 0x5C: decoded.append(0x5C) // \\
                case 0x2F: decoded.append(0x2F) // \/
                case 0x62: decoded.append(0x08) // \b
                case 0x66: decoded.append(0x0C) // \f
                case 0x6E: decoded.append(0x0A) // \n
                case 0x72: decoded.append(0x0D) // \r
                case 0x74: decoded.append(0x09) // \t
                case 0x75: // \uXXXX, with surrogate-pair support
                    try appendUnicodeEscape(to: &decoded)
                default:
                    throw StrictJSONError.malformed // not a recognized escape
                }
                continue
            }
            decoded.append(b)
        }
        throw StrictJSONError.malformed // unterminated string
    }

    /// Review finding, Important: the previous version computed
    /// `(UInt32(low) - 0xDC00)` unconditionally once a `\uD800`-range escape was followed by any
    /// second `\u` escape, with no check that `low` actually fell in the `0xDC00...0xDFFF` low-
    /// surrogate range first — an unpaired or malformed high surrogate underflowed that `UInt32`
    /// subtraction and trapped the whole process (SIGTRAP), from any string value in a
    /// legitimately *signed* envelope, not just a key. Every surrogate case below either combines
    /// a validated high/low pair or throws — it never traps and never silently drops a code unit.
    private mutating func appendUnicodeEscape(to decoded: inout [UInt8]) throws {
        let unit = try readUnicodeEscape()
        if (0xD800...0xDBFF).contains(unit) {
            // High surrogate: must be immediately followed by a low-surrogate \u escape.
            guard peek() == 0x5C, index + 1 < bytes.count, bytes[index + 1] == 0x75 else {
                throw StrictJSONError.malformed
            }
            index += 2
            let low = try readUnicodeEscape()
            guard (0xDC00...0xDFFF).contains(low) else { throw StrictJSONError.malformed }
            let value = 0x10000 + (UInt32(unit) - 0xD800) * 0x400 + (UInt32(low) - 0xDC00)
            guard let scalar = Unicode.Scalar(value) else { throw StrictJSONError.malformed }
            decoded.append(contentsOf: String(scalar).utf8)
        } else if (0xDC00...0xDFFF).contains(unit) {
            throw StrictJSONError.malformed // a lone low surrogate with no preceding high one
        } else {
            guard let scalar = Unicode.Scalar(unit) else { throw StrictJSONError.malformed }
            decoded.append(contentsOf: String(scalar).utf8)
        }
    }

    private mutating func readUnicodeEscape() throws -> UInt16 {
        guard index + 4 <= bytes.count else { throw StrictJSONError.malformed }
        guard let hex = String(bytes: bytes[index..<index + 4], encoding: .utf8),
              let value = UInt16(hex, radix: 16)
        else {
            throw StrictJSONError.malformed
        }
        index += 4
        return value
    }
}

/// Verifies an inbound signed A2A frame and admits it against the replay ledger — the single
/// enforcement point deciding whether a peer's claim is genuine, fresh and not a replay, before
/// any of its content is trusted (#974 H4 Task 4). `verifyAndAdmit` runs romar §5's fixed order;
/// see the method's own doc for the exact sequence. The verifier never reads the envelope's
/// self-claimed authority — it returns the verified envelope and the consumer derives tier from
/// the local registry.
struct PeerSignatureVerifier: Sendable {
    private let registry: PeerKeyRegistry
    private let seenSet: any SeenSetStore
    private let maxSeenPerPeer: Int

    /// romar's `verifiedBy` value for a direct (non-gateway-attested) Ed25519 signature — the only
    /// value this verifier ever accepts. There is no opt-in flag for gateway attestation: the
    /// spec's "unless the user opted into a separate gateway profile" is a #974 profile-layer
    /// concern, never a settable switch in this security core.
    private static let directVerifiedBy = "ed25519"

    /// romar §5.1: reject `ts_in_future` only once the clock skew exceeds this; equal to it still
    /// passes.
    private static let clockSkewTolerance: TimeInterval = 60

    /// romar §5.1: a `deadline` (for `message`) or an implicit freshness bound (for every other
    /// kind) may never reach further than this past `ts`.
    private static let deadlineCap: TimeInterval = 24 * 60 * 60

    /// romar §5.1: `envelopeId` shorter than this (in Unicode scalars, matching romar's own
    /// Python `len()`) is treated the same as absent — too short to carry any real replay-defence
    /// value.
    private static let minimumEnvelopeIdLength = 16

    /// romar §5.1's exact RFC-3339 grammar — anchored to the full string, ASCII-digit-only (never
    /// substitute `\d`, which some regex engines also match against Unicode decimal digits).
    private static let rfc3339Regex = try! NSRegularExpression(
        pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?Z$"
    )

    // `ISO8601DateFormatter` isn't `Sendable`, but these are never mutated after construction and
    // `date(from:)` is a pure read, so a shared instance across concurrent tool-call tasks
    // (Invariant 3) is safe despite the compiler's inability to see that.
    nonisolated(unsafe) private static let isoFormatterFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let isoFormatterPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(registry: PeerKeyRegistry, seenSet: any SeenSetStore, maxSeenPerPeer: Int = 10_000) {
        self.registry = registry
        self.seenSet = seenSet
        self.maxSeenPerPeer = maxSeenPerPeer
    }

    /// romar §5's fixed order, each failure throwing `PeerVerificationError(reason, envelopeId:)`
    /// (`envelopeId` `nil` until the envelope is decoded):
    ///
    /// 1. **Always** reject gateway-attested (`verifiedBy != "ed25519"`).
    /// 2. Resolve the key within the claimed principal's keyset (`nil` ⇒ unknown-key; a
    ///    corrupt-registry `RegistryError.unavailable` propagates as-is — fail-closed, never
    ///    relabelled as unknown-key).
    /// 3. Ed25519-verify the signing input — **before any decode**.
    /// 4. `StrictJSON.rejectDuplicateKeys(frame.envelopeBytes)` (⇒ duplicate-key).
    /// 5. `decode(frame.envelopeBytes)`, mapping `FrameDecodeError.missingRequiredField` to the
    ///    matching romar `*_missing` code where one exists.
    /// 6. The romar §5.1 post-parse checks, in order: sender binding, kind↔channel, recipient
    ///    binding by channel, envelopeId/ts/skew, deadline rules.
    /// 7. One atomic `seenSet.admit(..., retainUntil:, now: context.now)`.
    ///
    /// No canonicalization anywhere in this: every check up through the signature verify operates
    /// on `frame.envelopeBytes` exactly as given, and nothing before that signature check ever
    /// inspects a decoded field.
    func verifyAndAdmit<E: VerifiableEnvelope>(
        _ frame: SignedFrameParts,
        context: VerificationContext,
        domain: String = PeerSignatureDomain.a2a,
        decode: (Data) throws -> E
    ) throws -> E {
        // Caller contract, not a wire-triggered rejection: `.inbox` must never carry an
        // `OutstandingRequest` (Task brief: "so an event can't be routed through inbox rules").
        // Checked first since it depends only on `context`, never on anything the peer sent.
        if context.channel == .inbox, context.outstanding != nil {
            throw VerifierUsageError(message: "VerificationContext.outstanding must be nil for channel: .inbox")
        }

        // 1. Gateway-attested is always rejected — no opt-in.
        guard frame.verifiedBy == Self.directVerifiedBy else {
            throw PeerVerificationError(reason: .gatewayAttestedRejected, envelopeId: nil)
        }

        // 2. Resolve within the claimed principal's own keyset. `RegistryError.unavailable`
        // propagates unmodified — a damaged trust file fails closed, it does not read as
        // "unknown key".
        guard let publicKey = try registry.resolve(principal: frame.principal, keyId: frame.keyId) else {
            throw PeerVerificationError(reason: .unknownKey, envelopeId: nil)
        }

        // 3. Verify before any decode — the core security property of this type.
        let input = signingInput(domain: domain, envelopeBytes: frame.envelopeBytes)
        guard publicKey.isValidSignature(frame.signature, for: input) else {
            throw PeerVerificationError(reason: .invalidSignature, envelopeId: nil)
        }

        // 4. The core's own duplicate-key scan over the raw bytes — runs regardless of what the
        // injected `decode` closure does, so a naive transport decoder cannot fail open. Only
        // `.duplicateKey` is a romar-named code; `.invalidEncoding`/`.malformed`/`.tooDeep`
        // propagate unmodified, same precedent as `RegistryError.unavailable` above — romar names
        // no code for "malformed/wrong-encoding envelope", so this fails closed via its own error
        // type rather than being mapped to a `PeerRejectReason` that would misrepresent it.
        do {
            try StrictJSON.rejectDuplicateKeys(frame.envelopeBytes)
        } catch StrictJSONError.duplicateKey {
            throw PeerVerificationError(reason: .duplicateKey, envelopeId: nil)
        }

        // 5. Decode. Only now does any field of the envelope exist to this function.
        let envelope: E
        do {
            envelope = try decode(frame.envelopeBytes)
        } catch FrameDecodeError.missingRequiredField(let field) {
            switch field {
            case "envelopeId": throw PeerVerificationError(reason: .envelopeIdMissing, envelopeId: nil)
            case "ts": throw PeerVerificationError(reason: .tsMissing, envelopeId: nil)
            default: throw FrameDecodeError.missingRequiredField(field) // no romar code for this field
            }
        }
        let envelopeId = envelope.envelopeId

        // 6. Sender binding: the signature's claimed principal must match the envelope's own
        // claimed sender. A signature that genuinely verifies under a *different* principal's
        // registered key (e.g. rune's key, over an envelope claiming to be from clomp) must still
        // be rejected here — a valid signature from a known key is not itself a sender claim.
        guard envelope.fromProfile == frame.principal else {
            throw PeerVerificationError(reason: .principalMismatch, envelopeId: envelopeId)
        }

        // 7. Kind must be one this channel allows.
        guard context.channel.allowedKinds.contains(envelope.kind) else {
            throw PeerVerificationError(reason: .channelKindMismatch, envelopeId: envelopeId)
        }

        // 8. Recipient binding, by channel.
        switch context.channel {
        case .inbox:
            guard envelope.toProfile == context.selfProfile else {
                throw PeerVerificationError(reason: .recipientMismatch, envelopeId: envelopeId)
            }
        case .events:
            // `outstanding == nil` is itself a reject here, never a skipped binding.
            guard let outstanding = context.outstanding,
                  outstanding.addressee == envelope.fromProfile,
                  outstanding.taskId == envelope.taskId,
                  outstanding.correlationId == nil || outstanding.correlationId == envelope.correlationId
            else {
                throw PeerVerificationError(reason: .eventsRequestMismatch, envelopeId: envelopeId)
            }
        }

        // 9. envelopeId must be usable: present (decode already proved that in step 5), and at
        // least romar §5.1's 16-(unicode-scalar) floor — too short to be any real replay-defence
        // id, so it's treated the same as absent. Counted in Unicode scalars, not grapheme
        // clusters (`.count` would undercount a composed character) — matches romar's own
        // Python `len()`, which counts code points.
        guard envelopeId.unicodeScalars.count >= Self.minimumEnvelopeIdLength else {
            throw PeerVerificationError(reason: .envelopeIdMissing, envelopeId: nil)
        }

        // 10. ts: romar's exact grammar, then an actual parse.
        guard Self.matchesRFC3339(envelope.ts), let tsDate = Self.parseRFC3339(envelope.ts) else {
            throw PeerVerificationError(reason: .tsInvalid, envelopeId: envelopeId)
        }

        // 11. Clock skew: future by more than the tolerance is rejected; equal to it passes.
        guard tsDate.timeIntervalSince(context.now) <= Self.clockSkewTolerance else {
            throw PeerVerificationError(reason: .tsInFuture, envelopeId: envelopeId)
        }

        // 12. Deadline rules, by kind, and the retention bound Task 5's ledger needs.
        let retainUntil: Date
        if envelope.kind == "message" {
            // Required only for `message`; absent or unparseable reads the same as missing.
            guard let deadlineString = envelope.deadline,
                  Self.matchesRFC3339(deadlineString),
                  let deadlineDate = Self.parseRFC3339(deadlineString)
            else {
                throw PeerVerificationError(reason: .deadlineMissing, envelopeId: envelopeId)
            }
            guard context.now <= deadlineDate else {
                throw PeerVerificationError(reason: .deadlineExpired, envelopeId: envelopeId)
            }
            guard deadlineDate <= tsDate.addingTimeInterval(Self.deadlineCap) else {
                throw PeerVerificationError(reason: .deadlineOverCap, envelopeId: envelopeId)
            }
            retainUntil = deadlineDate
        } else {
            // Non-message kinds carry no deadline field at all — never required, never rejected
            // for lacking one. Their freshness bound is implicit: `ts + 24h`. romar names no
            // separate code for this case; `deadlineExpired` is the existing code whose meaning —
            // "this envelope's admission window has closed" — already covers it.
            let bound = tsDate.addingTimeInterval(Self.deadlineCap)
            guard context.now <= bound else {
                throw PeerVerificationError(reason: .deadlineExpired, envelopeId: envelopeId)
            }
            retainUntil = bound
        }

        // 13. One atomic check-and-record. `.duplicate` is rejected here (the transport acks it);
        // `.fresh` means admission succeeds.
        let admitted: AdmitResult
        do {
            admitted = try seenSet.admit(
                peer: envelope.fromProfile,
                envelopeId: envelopeId,
                retainUntil: retainUntil,
                maxPerPeer: maxSeenPerPeer,
                now: context.now
            )
        } catch SeenSetStoreError.full {
            throw PeerVerificationError(reason: .seenSetFull, envelopeId: envelopeId)
        } catch SeenSetStoreError.unavailable {
            throw PeerVerificationError(reason: .seenSetUnavailable, envelopeId: envelopeId)
        }
        guard admitted == .fresh else {
            throw PeerVerificationError(reason: .duplicateEnvelopeId, envelopeId: envelopeId)
        }

        return envelope
    }

    private static func matchesRFC3339(_ value: String) -> Bool {
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = rfc3339Regex.firstMatch(in: value, options: [], range: fullRange) else {
            return false
        }
        // Equality (not just "a match exists") guards against ICU's `$` matching before a
        // trailing line terminator even without multiline mode: a string with a trailing "\n"
        // would otherwise match everything up to but not including it.
        return match.range == fullRange
    }

    private static func parseRFC3339(_ value: String) -> Date? {
        if value.contains(".") {
            return isoFormatterFractional.date(from: value)
        }
        return isoFormatterPlain.date(from: value)
    }
}
