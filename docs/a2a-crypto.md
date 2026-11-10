# A2A peer-signature crypto core

Iris's half of the agent-to-agent (A2A) trust boundary: who sent a frame, whether its content
reached Iris intact, and whether it's a replay. This is the shared primitive the A2A transport
(#931) and, later, the MCP service (#965) consume — it has no transport and no `Principal` wiring
of its own.

## What it guarantees

- **Who sent it, and that it wasn't tampered with in transit.** Every inbound frame carries an
  Ed25519 signature over its exact bytes (no canonicalization — the signed bytes are the bytes
  that get parsed, nothing is re-serialized in between). The signature is checked *before* the
  envelope is ever decoded ("verify-before-parse"): a forged or corrupted frame never reaches a
  JSON parser at all, let alone application code.
- **Fail-closed, always.** A corrupt or unreadable peer-key registry, a corrupt or unreadable
  replay store, a malformed signed envelope, a signature that resolves to no known key — every one
  of these rejects the frame. None of them is read as "probably fine" or "no error."
  `verifiedBy: "a2a-gateway"` (a relay vouching for someone else's identity) is rejected
  unconditionally; there is no opt-in switch for it in this core.
- **Bounded replay protection.** A frame's `envelopeId` is recorded, per sending peer, before the
  frame is acted on. The same id from the same peer is rejected on a second delivery — and that
  rejection is itself the correct, expected outcome for a legitimate redelivery (the transport acks
  it rather than treating it as new). The record survives an app restart; a peer that floods enough
  distinct ids to fill its bound gets `.full` rather than evicting an older, still-valid id.
- **Keys are Iris's own, never the relay's.** A peer's public key comes from a local, per-profile
  registry that only a person enrolls by hand — never from anything a wire frame claims about
  itself, and never from a gateway's own say-so. Key resolution is scoped to the principal a frame
  claims: a key registered under one principal can never authenticate a different one.
- **Bidirectional, with outbound reliance still gated.** Iris generates and keeps its own Ed25519
  signing key (one per build identity — a dev build and the release build sign as different keys,
  so a peer enrolls the right one) and signs its own outbound frames the same way it verifies
  inbound ones. The signer exists and works today, but Iris does not yet *rely* on it for reply
  integrity toward a peer — that reliance is gated pending romar#403, per this core's own plan.
  Until that gate lifts, treat only the inbound direction (what the rest of this page describes) as
  end-to-end trustworthy; outbound signing is not yet the other half of a closed loop.

## Where the pieces live

- `IrisSigningKey`/`IrisSigningKeyStore` (`Sources/IrisKit/A2A/Crypto/IrisSigningKey.swift`) —
  Iris's own keypair, generated once and kept in the Keychain (service `iris.a2a.signing`).
- `PeerKeyRegistry` (`PeerKeyRegistry.swift`) — the local, per-profile store of other peers'
  public keys, under `config/a2a-peers/`.
- `signingInput`/`PeerSigner` (`PeerSignature.swift`) — the domain-separated bytes that actually
  get signed, and the outbound signer built on `IrisSigningKey`.
- `PeerSignatureVerifier` (`PeerSignatureVerifier.swift`) — the one place an inbound frame is
  checked: signature, structural integrity (no duplicate JSON keys), sender/recipient/kind
  bindings, freshness, and the replay check, all in a fixed order.
- `A2ASeenLedger` (`A2ASeenLedger.swift`) — the persisted, per-peer-bounded replay record, on the
  same GRDB writer every conversation lives on.

## The exact wire contract lives elsewhere

The byte-exact signing construction, the full rejection-reason list, the clock-skew tolerance, the
deadline rules, and the kind/channel table are **romar's contract**, not restated here — this core
implements it, and its tests are checked against a conformance vector vendored verbatim from romar
(`Tests/irisTests/Fixtures/peer-signature-conformance.json`, with provenance in the sibling
`.PROVENANCE.md`), not a from-memory re-reading of the spec. If the byte-exact contract ever needs
checking, read romar's `peer-signature-spec.md`, not this page.

## Enrollment

`PeerKeyRegistry.enroll()` is API-only today — there is no UI for it yet, and no automatic
discovery or path from a wire frame to a newly-trusted key; a future enrollment surface is what
would call it to add a peer's public key by hand, per profile. Likewise,
`IrisSigningKeyStore.publicKeyWireString()` is the capability this core exposes for a future
enrollment surface to display or otherwise hand to a peer — it is not wired into any UI yet, so
"a person enrolls a key" and "a key is shown" both describe what this core makes possible, not
something usable today.

`config/a2a-peers/` is copied along with the rest of `config/` when a dev home is seeded from a
release install (`DevHomeSeeder`) — this is fine, since it holds only public keys, not secrets.
