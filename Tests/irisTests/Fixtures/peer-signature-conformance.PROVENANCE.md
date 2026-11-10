# Provenance — `peer-signature-conformance.json`

Vendored verbatim (byte-for-byte, via `cp`, never hand-edited — JSON has no comment
syntax to carry this inline) from romar's conformance vector.

- **Source:** romar `projects/active/a2a-gateway/peer-signature-conformance.json`
  (referenced by `peer-signature-spec.md` §9)
- **Source commit:** `98dc4e1423fb430243e58f4bddce50d2a96360da` — "feat(a2a): option (c)
  detached-signature peer-identity wire format (romar#396 #398) (#399)". This is the
  commit that introduced the conformance vector; romar#407/#409 refined the spec prose
  but did not touch the fixture (confirmed by iris-planner: it's still the latest commit
  touching that file as of 2026-11-10).
- **Git blob SHA (of this file):** `3efa1ef0d51ea7d66782d8063177196b8914e337`
  — verify with `git hash-object Tests/irisTests/Fixtures/peer-signature-conformance.json`
- **sha256 (of this file):** `d5b5771c3affb77d2beee1c6de8a3de879fd46883254adf1a869e6f27bdec82b`
- **Vendored by:** iris-dev-1, 2026-11-10, from a copy iris-planner staged at
  `~/iris_a2a_conformance_vector.json` (deleted once vendored).
- **CI-fetch alternative, not used:** this is a static vendored copy, not fetched from
  romar at CI time, so it cannot silently drift under us — re-vendoring (new commit SHA,
  new blob/sha256 above) is a deliberate, reviewed act, not something a CI run does for
  itself.
- **Do not hand-edit.** A first staged copy (30100 bytes) had two control bytes mangled
  to literal `^A^_` instead of romar's `\u0001\u001f` JSON escapes — disqualifying for a
  byte-exact conformance fixture — and was replaced before vendoring. If this file is
  ever regenerated, re-verify the git blob SHA against romar's own repo before trusting it.
- **romar's own note field** (copied into the vendored JSON): "romar#396 / #399
  conformance vector (§9). B is the exact envelope bytes signed verbatim (base64-wrapped
  on the wire). Do NOT hand-edit."
- romar's fixture omits an `events_request_mismatch` negative vector; Task 6 of
  `docs/superpowers/plans/2026-11-10-974-h4-crypto-core.md` adds one locally.
