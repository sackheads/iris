# Iris as an MCP Provider: Dev-Team Collaboration on the Agent Mesh — Design

**Status:** DRAFT for team review. This document decides nothing. It frames what we are building
— Iris as a *provider* on the agent mesh, with the dev team as the first concrete peer — how the
provider direction differs from the consumer direction we already have on the board (the homelab
A2A client), and the design points where the existing machinery does not fit the new shape
cleanly. The decisions belong to the people named under each point.

**Neighbours (normative — this doc references, it does not re-specify them):**
- `#964` — Iris MCP service + agent confinement (the service this rides on).
- `docs/specs/2026-10-10-sessions-a2a-messaging.md` — session↔session A2A: `Message`/`Part`,
  `attachments`, `iris-artifact://`, `artifact_refs`, retention, the §6 rate limit and #185
  cascade budget.
- `docs/superpowers/plans/2026-11-07-a2a-client.md` — the homelab A2A **client** (Iris as
  client to the homelab gateway), incl. Task 3 file transfer and `Principal.a2aRemote`.
- `docs/specs/2026-11-09-unified-access-boundary-design.md` — the one access boundary that
  already names `mcpGuest` and `a2aRemote` as sibling Principals.

---

## 1. What we are trying to accomplish

In agentic development, work increasingly flows **agent to agent**: a session delegates to a
specialist agent rather than absorbing that specialist's complexity itself. Iris is just another
agent on that mesh. She both **provides** services — the thing that lives on the user's Mac, with
their context, memory, local models, and GUI — and **consumes** them. Those are two directions of
traffic on one bus, not two architectures.

This is already the dominant shape elsewhere. `kube-agents` both calls MCP services from other
agents *and* exposes its own; a Claude Code, Antigravity, Gemini Enterprise, or a bespoke agent
(Spotify's `honk`/`zero`, say) can farm GKE work out to `kube-agents` and never touch cluster
management. Iris's specialty in that division of labour is not just the user's machine but the
*human attached to it*: a caller reaches her local-first, native-macOS surface — and, through her,
approvals, the Inbox, and attended GUI — without being a Mac app or having that human (Iris's
framing). That reach is also the main risk: a guest-triggered turn can queue questions for the
user (`inbox_item`), so guest turns need their own attention budget or the dev team can exhaust
the user's attention by accident (§3.5). The homelab A2A client already on the board is Iris as
*consumer*. **This document is Iris as *provider*** — same bus, same peer model, the other
direction of the same relationship.

The first concrete instance, and the one that proves the surface in-house, is **the Iris dev
team**: the Claude Code sessions that build and review Iris, able to message the running app, hand
it a file, and get one back. The motivating case is debugging. The attended-GUI nights (the
composer input-refusal and dark-text bugs, #1055/#1052) burned hours because a human had to relay
every observation by hand, and the relay itself confounded the measurement (switching apps to
report a click deactivated the target window, so the next click never reached `mouseDown`). The
agent on the other side of that relay could have answered directly: "what is your composer's first
responder right now?" is a question the running Iris can answer about itself.

That is the shape of the value, but it splits across **two levels this doc keeps apart** (Iris's
framing — conflating them is what hid half the open questions):

> **The app** — its `AppState`, composer, first responder, windows — is what a *deterministic
> self-report* reads (§3.7). **A role session** — its conversational context and profile — is what
> a *conversation* reaches (messaging, files, qualitative questions; §3.2). Different providers,
> different trust stories.

The caller does not reach into Iris's address space either way. For a qualitative question it asks
a session and the session answers. For a *measurement* — "what is the composer's first responder,
and why is it disabled?" — it reads the app directly, **without starting a turn**, because starting
one changes the very state being measured (the #1055 confound again) and puts a model that can
misreport between the caller and the value (§3.7).

**Non-goal: a general-purpose debugging/introspection port.** We are not adding a wire protocol
that lets a peer drive UI events, step the app, or inspect arbitrary internal state. A real debug
port is a different-order project — a protocol, state serialization, safe event injection, keeping
it coherent while the target mutates under you — and the intelligence we need already lives in the
agent. Asking Iris to report on itself recovers most of the debugging value at a fraction of the
cost. This is a deliberate scoping decision, not a deferral.

**One accommodated exception (Brian, §3.7).** A *narrow, read-only self-report door* — a bounded,
**app-level** diagnostic read answering specific enumerated questions about the app's own state —
is a special case this environment accommodates. It is not the general port the non-goal rules
out: it drives nothing, runs no model, and exposes a defined surface, not arbitrary state. §3.7
holds its shape.

The dev team is the first peer because it is trusted and in-house, but nothing in the surface is
dev-team-specific. Any agent that speaks MCP/A2A could, with the right grant, be a peer; the
confinement and access-boundary design is precisely what makes that safe to open past the dev team
later. One scope caveat (Rune): the provider has **two auth legs** — a *local bearer/loopback* leg
(route 3 → `mcpGuest`, which §3.3 analyzes) and a *remote ed25519* leg (route 4 → `a2aRemote`, with
no loopback channel or local config file). This document specifies only the local leg; v1 is
loopback-only, and "any agent could be a peer" should read "any *local process*" until the remote
ed25519 provider leg is designed. In the unified access boundary's terms, such a peer is an **`mcpGuest`**: the intent is
that it reaches the inter-agent *bus*, not the underlying access. How that confinement actually
binds once a role session processes the guest's text under its own authority is itself an open
question — see design point 3.2.

## 2. Iris as a symmetric mesh peer (what carries over, what must generalize)

We already have a design on the board for Iris *consuming* mesh services (the homelab A2A client
plan). It is tempting to read the provider direction as "the same thing again," and the
message/part model and the object store genuinely are reusable. But a peer that *provides* differs
from one that *consumes* along axes that drive the design — not because provider and consumer are
separate systems (they are the same peer, and a real deployment is usually both at once), but
because traffic direction and trust context change what the machinery has to do. The table below
is those axes, with the existing homelab-consumer design in one column and the dev-team-provider
case in the other; most rows generalize beyond those two specific peers.

| Axis | Iris consuming (homelab A2A, existing) | Iris providing (dev team, this doc) |
|---|---|---|
| **Traffic direction** | Iris calls out — uploads/downloads against the peer's object store | Iris is called — it hosts the loopback MCP endpoint peers connect to |
| **Peer in the first instance** | External homelab agents (Clomp et al.) | Internal Iris dev sessions (generalizes to any granted agent) |
| **Trust basis** | Per-frame ed25519 signature (romar#396, #974 H4); relay is not an identity authority | Static Bearer token (Claude Code's MCP client; no OAuth) |
| **Interaction shape** | Task delegation — a peer delivers a `task`, gets `status-update`/`artifact-update` back | Conversational messaging — `send`/`poll` to a live session, threaded by `contextId` |
| **Delivery target** | A fresh, isolated, off-foreground `a2a-remote` session (`Principal.a2aRemote`), confined and approval-capable, without the role session's conversational context | A role-holding session's inbox *or* `#974`'s isolated lane *or* a read-only app snapshot query, or an isolated lane with a scoped role read — an **open six-shape fork (§3.2)**, since inbox delivery would run under the session's own binding, not a guest floor |
| **Object store** | Peer-hosted, `PUT`/`GET /v1/objects/{taskId}/{sha256}` | Iris-hosted — Iris serves the SHA-addressed object endpoint for the first time |
| **Principal** | `a2aRemote` | `mcpGuest` |

What *should* be shared — as design intent, not as existing code — is the access boundary and the
content model: one `(transport, issuer, id)` → profile resolution, A2A `Message`/`Part`
(`text`/`data`/`file`), the `iris-artifact://<sha256>` content-addressed store, the
SHA-verify-on-read, and the caps. Say "intent" literally: **none of the boundary is built yet.**
`Principal` on main is `main | subagent | evaluator` (the `Principal` enum in `SandboxPolicy`);
`mcpGuest` and
`a2aRemote` live only in the boundary spec, and every guest floor this doc leans on is unbuilt
(Iris's check). The sibling framing is the right target; it is not a thing to reuse today. The
trap is assuming that because the *boundary* is shared in the spec, the *delivery path* is settled
— see design point 3.2.

## 3. Design points (open — this is the part to rope the players in on)

Each point names the seam, the options, and who should weigh in. None is decided here. Several
points were corrected and reshaped by three pre-circulation reviews (2026-11-11): dev-2's
fact-check, Iris's own code-grounded review (against `origin/main` 6d957a74), and dev-1's
independent re-review. The first draft got a number of claims about the existing machinery wrong
from partial reads; those corrections — with code/spec citations — are folded in. Iris reshaped
four: the app-vs-session split (§1), the app-level self-report tool (§3.7), turn-scoped authority
(§3.2), and two seams nobody else caught — the steer path (§3.2) and the reply direction (§3.8).
dev-1 then corrected a taint claim folded from Iris (§3.2) and raised the key-window gap (§3.7).
Then **Clomp's external review** (`clomp42`, `CHANGES_REQUESTED`) traced the open points to code and
surfaced the central §3.2 fork plus the shared-history, principal-gating, and cascade
constraints; **dev-2 verified** each against `6d957a74` (confirming the mechanics, correcting two
overstatements in §3.8 and §2) before they were folded here. Finally **Rune's review** (`rune42808`,
deepseek) made the sharpest point of the chain — the prior passes verified *omissions, not
mechanisms* — and three corrections followed, each re-verified here against `6d957a74`: §3.3 (the
deny-list "control" is inert against `read_file`, and its credential-store enumeration was a dev-2
error this doc had folded); §3.1 (the homelab GET ACL is specified on the romar side as
principal-owned `{taskId}`, not "silent"); and §3.2×§3.8 (shapes 1–2 fail the confidentiality bar
because `mcpGuest` strips *tools* but does not partition *history* — the model is the exfil channel).
Rune also added shapes 5–6 and the honest admission that no shape yet both confines a guest and
delivers §1's role-session value.

### 3.1 How a guest addresses and reads an artifact

*Scope segment and the homelab GET ACL (corrected, Rune).* The a2a-client plan Task 3 produces both
`uploadObject` (PUT) and `downloadObject` (GET, SHA-verified) — the GET path is not missing, only its
ACL *prose* is. And that ACL **is** specified on the romar side: `design-spec.md` §4.4/§5.2 require
the caller's `{taskId}` to be **principal-owned** (`taskId` begins with `{caller.principal}--`, else
`403` / `-32003 TaskNotOwned`). So the homelab object ACL is **bearer + principal-owned `{taskId}`**,
*not* a conversation row — an earlier draft's "the plan is silent, so `{taskId}` scoping is our
inference" was wrong. The messaging lane is the *different* model: no `taskId`, threaded by
`contextId`, artifacts keyed `(sha256, conversationId, msgId)` in `artifact_refs` under the §7.6 B
conversation-row ACL. These are **two ACL models**, and the options below must pick one for Iris's
provider endpoint rather than present option (b)'s "same row-based ACL" as if it matched homelab.

*The read ACL is a conversation row, and a guest is not a conversation.* Messaging §7.6 B: only a
conversation holding an `artifact_refs` row may read an artifact, and "a forwarded message that
carries a hash grants nothing" — the hash is deliberately not a capability. A guest has no
conversation row, so any guest read needs a guest-shaped `artifact_refs` row (or equivalent ACL);
a hash-only HTTP endpoint would break §7.6 B outright.

*Options:* (a) generalize the object path's scope segment to a transport-neutral `{scopeId}`
(taskId in the task lane, a guest row in the messaging lane) with the read ACL gated on the guest
holding the matching row; (b) **add no second HTTP surface at all** — serve `iris-artifact://`
as an MCP `resources/read` over the already-authenticated loopback channel, same row-based ACL
(dev-2's M4). Note #964 today specifies *no* file transfer, and the messaging spec says artifacts
never cross the network in v1, so any object surface is net-new regardless; (c) messaging
artifacts stay in-store only — guests get data parts and small inline files, not large blobs.

*Front-runner (Iris):* option (b). `resources/read` over the already-authenticated channel is the
only option that adds no second network surface; pick it unless someone shows a blob size MCP
can't carry.

*The other direction — guest → Iris ingest (Clomp/dev-2).* Option (b)'s `resources/read` is
server→client (Iris → guest) only; it does **not** cover a guest *handing Iris a file* (§1, "hand it
a file, and get one back"). That ingest path must be specified separately when this folds into #964
— inline `DataPart`/`FilePart` bytes on `send`, or an `artifact_put` MCP tool — and explicitly
**not** a host `{path}` read via `IrisEngine.attachFile`, which authorizes the read against a sending
`Conversation`'s `read_file` scope a guest does not have.

*Weigh in:* whoever owns the a2a-client object store and `artifact_refs`, plus #964.

### 3.2 The delivery path — and which authority the receiving turn runs under

`a2aRemote` delivers a task into a fresh, isolated, off-foreground session (confined, three-tier
path/tool policy, approval-capable — it is *not* stateless; it reads files under auto-allowed
dirs, with `session_search` and raw `fact_store` hard-blocked). The dev-team value differs in
kind: ask a *real* role-holding session about *itself* — the live conversational context the
isolated lane does not carry. #964 routes guests to an existing role session's inbox, not the
`a2a-remote` task runner.

But inbox delivery opens a deeper seam (dev-2's M1, sharpened by Iris): **the guest's text is then
processed by the role session, under *that session's* binding — not an `mcpGuest` floor.** That is a
plain confused deputy, and one of the layers #964 would lean on to contain it is not actually a
floor: `SandboxPolicy.resolve` returns `.host` for every principal the moment the master switch is
off (`SandboxPolicy.resolve`, verified), so a guest-triggered turn in a `main` session with
sandboxing off runs host commands that inherit the process env.

*(An earlier draft also claimed the #818 taint layer was "noise" because #1026 taints every session.
dev-1's re-review corrected that, and Iris confirmed the error was hers: #1026 is two **fixes** for
over-tainting — `05303324`, `c7d923d0` — both already in the `6d957a74` baseline. Taint is therefore
not a demonstrated gap — but nor has the day-old fix been shown to work *as a guest-turn layer*, so
§3.2 leaves taint unrelied-on in either direction; the confused-deputy concern rests on the
sandbox-pin finding and the structural inversion below.)*

*Position to weigh (Iris):* **authority belongs to the turn, not the session.** A turn started by a
guest message runs under (receiving profile ∩ `mcpGuest` floor), with the sandbox **enforced**, not
merely preferred; the session keeps its conversational context but does not lend its full
authority.

**Clomp's review (verified by dev-2) shows that position is only a half-answer, and surfaces the
real fork.** First the frame: `mcpGuest` and the isolated lane are **spec-only** today (`Principal`
is `main | subagent | evaluator`), so what follows constrains the *designed* path, not a live bug.
Two verified problems:
- **Shared history crosses the authority boundary.** A `Conversation` holds one mutable `history`
  array (`appendContentToHistory`, re-read each turn in `processInputBody`); nothing tags authority
  or origin per entry. So (a) an earlier non-guest turn's tool output is already in the history the
  guest-started turn sends to the model, and (b) the guest turn's text and reply persist and are
  read by the *next* turn under full authority. Turn-scoped authority limits which *tools run* — not
  what the model *sees*, nor what the next turn *inherits*. (dev-2: (b) is the existing local-peer
  exposure at a lower trust level — real, not a new class.)
- **Running as `mcpGuest` strips the tools the role session would need.** `send_to_session`,
  `inbox_item`, `list_sessions`, `close_request` are gated on `principal == .main` (`hardStrip` plus
  dispatch guards, no carve-out, verified). A guest-principal turn can neither originate a message
  nor raise an inbox item.

So "authority belongs to the turn" and "run it as `mcpGuest`" cannot both hold. **The fork — six
shapes, none chosen** (dev-2's four, plus two Rune added by separating *authority*-isolation from
*context*-isolation):
1. **Guest turn keeps `Principal.main` with a narrowed binding.** Tool guards pass, but the floor now
   depends on a binding check that does not exist yet, and `history` is still shared and
   unpartitioned.
2. **Guest turn runs as `mcpGuest`.** The floor is real, but `send_to_session`/`inbox_item` are
   stripped — §3.5's attention budget has nothing to meter and §3.8's reply path is unstated.
3. **`#974`'s isolated lane.** Avoids the shared-history problem entirely — but loses the "ask a real
   role session about *itself*" value that §1 is for.
4. **The guest message becomes a read-only query the app answers from a card or snapshot — no turn in
   the role session at all.** This is §3.7's app-level shape; it sidesteps every problem above but
   only serves what a snapshot can answer, not a conversation.
5. **An isolated `mcpGuest` lane *with* a scoped read of the role session** via a bounded read tool —
   the primitives already exist (`read_conversation`, `describe_session`/`list_sessions` for
   deterministic cards) and the doc had ignored them (Rune). Gets the floor *and* a window into the
   role session, read-only.
6. **A guest-owned fork/copy of the role session's history, run under `mcpGuest`.** The guest reasons
   over a snapshot of the session without mutating it or inheriting its authority.

**The confidentiality bar rules out shapes 1 and 2 (Rune).** Running as `mcpGuest` strips *tools*; it
does **not** partition `Conversation.history`. So the guest turn's *model* still receives the full
shared history — prior non-guest turns' tool output, file reads, `read_conversation` output, secrets
— and emits what it saw into the reply. §3.8's "exact-secret scrubbing" catches literal token values
only; a model that paraphrases or summarizes a prior secret is caught by nothing (the boundary spec
itself concedes semantic classes are best-effort). No tool floor, no principal, and no scrubbing
closes that axis: **the model is a covert channel from shared history to the guest's mailbox.** So
shapes 1–2 do not meet the confidentiality bar at all; only a *context-partitioned* shape (3, 4, 5,
or 6) can. Said plainly, and the doc should say it: **as scoped, no shape both confines the guest and
delivers §1's "ask a real role session about itself" — shapes 1–3 each fail for a different reason,
shape 4 can't answer a qualitative question, and shapes 5/6 (partition + a bounded role read) are the
only candidates that might.**

Three must-nots bind whichever shape wins (verified): a guest `Origin` must be a distinct case that
**never coalesces** with `.user`/`.peer` in `drainPendingUserMessages` (which joins same-`Origin`
entries with `\n\n`); a guest-drained turn must **not** run `runReflection` — `startTurn(isPeer:)`
still increments `messageCountSinceReflection` and fires reflection at ≥ 30, which `#974` C7 forbids
for a guest binding (`.systemEvent` drains bypass `startTurn`, so a guest origin could take that
shape); and because **no shape tags history entries with origin/authority** today, a guest's persisted
text is read back by the next full-authority turn *indistinguishable from the user's own words* — a
standing prompt-injection channel the winning shape must close with per-entry origin tagging.

**The steer path — a hard requirement for the designed path (Iris; verified).** When the target is
mid-turn, a peer arrival is queued (`queuePeerArrival`) and can be drained into the *running* turn
as a steer (the `drainPendingInput` → `takePendingSteers` path). The queued text keeps its own peer
label (`peerMidTaskLabel` = "Peer message (mid-task)"), **not** the user's
`User (mid-task):` trust label — so it does not impersonate the user. The hazard is narrower and
real: a turn-scoped principal cannot apply to text injected into a turn already running, so the
steer executes inside a turn the user started under `main` and runs under the **user's
permissions** — which for a guest-origin message would be a privilege escalation. No guest path
exists today, so this is a requirement for the path being designed, not a live hole. **Guest
arrivals must never steer:** they wait for the current turn to end and start their own
guest-principal turn. Not a trade-off — a line the build must hold.

*To settle:* choose among the six shapes above — this is the crux of the whole design — plus the
never-steer rule and the three drain must-nots. The earlier "pin `mcpGuest` → inbox delivery" framing
assumed inbox-into-role-session survives contact with shared history and principal gating; it does
not. Rune's confidentiality argument rules out shapes 1–2, shape 4 can't answer a qualitative
question, so the live contenders for §1's role-session value are **shapes 5–6** (context partition +
a bounded role read) and, for pure diagnostics, shape 4.

*Weigh in:* #964 owner, the unified-boundary author, security review.

### 3.3 Auth strength, token lifetime, and the first grant

`a2aRemote` is per-frame ed25519-signed; compromise the setup and you still need the key to forge
each frame. (Caveat, Rune: "the relay is not an identity authority" is the committed H4 contract, but
romar still ships legacy attestation paths — `door.go`/`iris_relay.go` stamp `verifiedBy:
"a2a-gateway"`, `sig: nil` — so until those are retired, a relayed frame's provenance isn't fully
trustworthy on the wire.) `mcpGuest` is a static Bearer token — leak it once and you are that guest
until the token dies. The floor must encode the weaker identity. Two distinct lifetimes are in play and the
doc must not conflate them: the **token lifetime** (how long a bearer credential is valid — new
here) and #964's **request TTL / last-poll expiry** (which closes outstanding `expects_reply`
requests — not a token lifetime). Per the unified boundary R5, guest-auth itself is #965's design,
and the first grant of a new peer's profile and key is Inbox-gated.

**The bearer token is really a local-process identity (Iris).** A static token for a loopback
endpoint lives in plaintext in Claude Code's config, so the identity it proves is not "the dev
team" — it is "any process running as the user that can read that file," which includes Iris's own
host `run_command`. Iris could connect to her own MCP endpoint as a guest, and #964's guest→guest
ban does not catch Iris→loopback→Iris. Either bind the token to something a process can't simply
read, or state explicitly that this identity means "any local process" and set the `mcpGuest` floor
to match.

**The deny-list "control" is inert against the read path (Rune, verified — this corrects an earlier
fold).** A prior pass proposed adding `~/.claude`, `~/.claude.json`, `**/.mcp.json` to a credential
deny list to close the `Iris→loopback→Iris` exposure. Verified against `6d957a74`, it closes nothing
on the read path: `JobGrant.credentialStores` is consulted **only** by sandbox *mount* creation
(`isCredentialStore`, called from `HomeMount`), and `read_file` is gated by `ReadOnlyCommand`, which
returns `.run` for `read_file` on **any** path — it never consults `credentialStores`. So in §3.2's
own scenario (guest-triggered `main`-session turn, master switch off → `.host`), `read_file` of
`~/.claude.json` is auto-approved and the token stays readable. Two more corrections: the actual
`credentialStores` list (`~/.ssh, ~/.aws, ~/.gnupg, ~/.config/gh, ~/.docker, ~/.kube, …, ~/Library/
Keychains, …`) does **not** contain `~/.netrc` or `~/.git-credentials` (a stale earlier claim here),
and `**/.mcp.json` is a glob the canonical-prefix matcher can't express and a file the mount list
can't admit.

**The real fix (Rune).** Stop leaning on the mount deny list. Either **bind the token** to something a
process can't just read (a Keychain item with a per-item ACL, or an ephemeral token handed to the MCP
server over stdin and never written under `~`), or **declare the identity "any local process"** and
set the `mcpGuest` floor to match (the doc's own alternative). If a deny list is kept at all, it must
be enforced at the `read_file`/`run_command` **data layer**, with a glob-capable, file-aware matcher,
and acknowledged as doing nothing to host `run_command`. (Token lifetime is not novel either: romar's
gateway bearer already models `expiresAt`/`notBefore`/`revoked` + fsnotify reload, romar
`design-spec.md` §6.1 — mirror it.)

*To settle:* bind-the-token vs declare-any-local-process (and the floor that follows); the token
lifetime/revoke path (mirroring romar §6.1); confirmation that nothing a guest profile reaches leans
on signed-frame provenance. Defer the guest-auth mechanism to #965.

*Weigh in:* #965/#964 owners, the unified-boundary author, security review.

### 3.4 Provenance granularity

#964 already requires stamping each message's origin as Iris-native vs guest and forbids
guest→guest, so the principle is not new. The open delta is granularity and reach: a finer issuer
stamp (`mcpGuest:<tokenid>` / `a2aRemote:<peerid>` / `local`), and whether it also lands on
`artifact_refs`, so a guest-origin blob forwarded onward can't later read as Iris-origin.

*Weigh in:* whoever owns `artifact_refs`/retention, security review.

### 3.5 A guest's rate and turn budget

This doc first claimed a "new-`contextId` resets cascade depth" escape; that is wrong (dev-2).
Messaging §6: depth follows causation, *not* `contextId`, and the new-thread escape belongs to the
per-thread design the spec rejected — there is no `contextId` reset today. #185's global budget
has been *replaced* by two limits; `maxSessionCascade` is the hop-depth limit.

The real guest gap: both the hop-depth counter and the token bucket are keyed by a **session
UUID** (`peerDepth(for: sender)`, `peerRateLimiter.take(for: sender)`, capacity 20, one send /
15 s). A guest has no conversation, so a guest send bypasses both unless a per-guest budget is
built. #964 already lists "a per-guest rate/turn budget + a harness stop condition" as required
even for the plain increment, so the principle is settled; what is open is the **values** and the
**key** (per token, not per session UUID). Refinements (Iris): a guest-origin message should start
at **depth ≥ 1**, not 0 — otherwise a guest gets a full cascade budget it never paid for; and
`notePeerArrival` needs a defined depth value for a guest-origin message, which the spec does not
give. The "a guest restarts the app and resets the in-memory depth counter" concern only bites if a
guest *has* a restart path — so call that out as a thing to deny, rather than designing the budget
around it.

**Verified cascade mechanics (Clomp, dev-2).** `resetPeerDepth` fires only from `startTurn` when
`!isPeer` (and from `deleteConversation`) — i.e. only when a human types into *that session's*
composer in `Iris.app`. An external guest never produces that keystroke, so with a fixed guest depth
the counter never climbs, and with an accumulating depth it reaches `maxSessionCascade` (8) and never
resets — wedging the standing role session. Worse, `peerDepths` is keyed by the *receiving* session
UUID, so a guest-driven wedge on `role:reviewer` also blocks the local planner→reviewer chain. Not
forced, though: once the budget is keyed per guest token (which the doc already calls for), the rate
bucket (cap 20, one per 15 s) is the real bound; what stays open is the **depth key and reset rule**
for an external guest whose typing `Iris.app` can't observe. (This wedge is a shapes-1/2 concern — it
needs a turn in the role session sharing `peerDepths[roleId]`; shapes 3–6 that isolate or snapshot
don't inherit it.)

**And the attention budget (Iris, from §1).** The richest thing a guest turn can do is not compute
— it is reach the user: a guest-triggered turn can call `inbox_item` and queue questions for the
person. Guest turns need an attention budget distinct from the compute budget, or the dev team can
exhaust the user's attention by accident. Note the dependency on §3.2's fork: under shape 2
(`mcpGuest` principal) `inbox_item` is stripped entirely, so there is nothing to meter — the
attention budget only exists if the guest turn can reach the Inbox at all. `inboxEmitRateLimiter` is
already a bucket separate from `peerRateLimiter` (`decideInboxEmit`, which also passes the taint
flag), so a tighter per-guest cap has a seam to live on.

*Weigh in:* whoever owns the §6 limiter, `maxSessionCascade`, and the Inbox.

### 3.6 Which lane's caps a guest inherits

The lanes cap files differently (dev-2's M5): the task lane is 128 KiB inline, else upload; the
messaging lane never inlines and caps at 50 MB/file, 200 MB/session/day, 2 GB total. And romar's
object store adds a *third* regime (Rune): 64 MiB/object, 512 MiB/bucket, 7-day TTL — the conformance
baseline for Iris's provider endpoint. A guest over MCP is none of the three by default. Reconcile
them, say which applies to a guest, and — since the guest token is the unit — whether the
per-session/day budgets re-key per token.

*Weigh in:* whoever owns `ArtifactLimits`, #964.

### 3.7 The self-report door — scope settled, shape open

dev-2's M2. "What is your composer's first responder right now?" has **no tool behind it today**:
nothing in the surface reads AppKit/UI or live `AppState`, and `describe_session` returns
session-card data, not that. Answering it needs a new, narrow, main-actor diagnostic tool, gated
per Invariant 6 and guest-reachable.

**Brian's call (settled, 2026-11-11):** a literal self-report / debug door is a special case this
environment accommodates — "unique to this environment." It is not the general debug port the §1
non-goal rules out (which drives events and inspects arbitrary state); this door is read-only and
bounded. So the *scope question is closed yes*; what remains open is the tool's shape.

**Iris's shape proposal — the door is an app-level MCP tool, not an agent tool.** Routing the read
through "ask Iris, Iris answers" puts an LLM turn between the caller and the measurement, which is
wrong twice over:
1. *It reintroduces the #1055 confound.* Starting a turn changes the state being measured —
   turn-in-flight, composer gating, possibly focus and the spinner. The input-refusal bug is
   exactly the class where "a turn is running" changes the answer.
2. *It inserts a model where you want a deterministic reading.* An LLM can misreport a value; a tool
   returning raw values cannot.

So the door is called directly behind the same bearer token — **no session, no turn, no profile**
(which also answers "which profile carries it": none). Shape:
- **Fixed, enumerated queries.** Key/main window; first responder class and identity; composer
  enabled state and *why*; turn-in-flight per session; app activation state. No transcript text, no
  memory, no file contents.
- **A passive event ring buffer.** The #1055 relay problem was about *events* (did `mouseDown`
  arrive, and on what), not a snapshot — a point-in-time read can't say why a click didn't land. A
  bounded ring of recent window/focus/event-routing transitions can.
- **A main-actor timeout.** The read hops to the MainActor; if the main thread is wedged — a bug
  class you'd use this for — the tool must time out and return "main actor unresponsive for N ms,"
  which is itself the diagnosis.

"Ask a role session about itself" still exists for *qualitative* questions; it just is not the
debugging path.

*A key-window subtlety dev-1 raised, and how the shape answers it (Iris).* `isKeyWindow` and
first-responder are only meaningful while the queried app is frontmost — macOS has one key window
system-wide — so a snapshot taken while Iris is backgrounded would report "not key" regardless of
the real bug. The proposed shape handles this *without* assuming Iris stays frontmost: (1) every
snapshot carries the **activation state** (`isActive` / key-window owner), so a backgrounded answer
identifies itself as backgrounded rather than misleading; and (2) the **event ring buffer** records
focus/key transitions as they happen, so reading it after Iris was backgrounded still shows what
occurred while it was frontmost — which is exactly the #1055 case (the click lands while Iris is in
front; the relay comes later). The rule to state: a snapshot is valid only together with the
activation state it reports, and diagnosing what happened while frontmost is the ring buffer's job.
dev-1 also confirmed the tool's premise in code: `describe_session` returns session-card data only —
no AppKit or `AppState` read exists in the surface today.

*Two more shape notes (Clomp #6, verified by dev-2).* (1) The main-actor timeout only works if the
MCP/HTTP entry point is **non-`@MainActor`** — racing `MainActor.run` against a dispatch-timer
deadline (Invariant 4: never `Task.sleep`), since a wedged main actor would otherwise block the
request before the timer fires. No MCP server exists in the tree yet, so this is a build constraint,
not a code fact. (2) To diagnose #1055 *and* #1052 without a second tool revision, the
snapshot/ring-buffer fields should capture `TranscriptFocusAnchor`'s async hop — it installs an
`addLocalMonitorForEvents` that hops via `DispatchQueue.main.async` to `makeFirstResponder`, so the
first responder changes *after* `sendEvent`; record it both synchronously and post-hop — and
`effectiveAppearance` on the window and the composer's `NSTextView` (the #1052 dark-text axis).

*Three ways the door as drawn breaks its own promises (Rune, verified).* (1) The "key/main window"
query emits the **window title**, and the title is derived from unvetted content — `ChatView` sets
`.navigationTitle(WindowTitle.safe(conv.title))`, and `WindowTitle.safe` is documented as *display
hygiene, not a guard* (strips control chars, caps at 80, **no redaction**). Emitting it falsifies the
door's own "no transcript text." (2) The key-window query is **system-wide** (macOS has one), so it
reads whatever is frontmost — often another app (Terminal, a browser, 1Password) — with no bound on
emitting that app's title. (3) The door is deliberately session-less, so neither `PeerRateLimiter`
nor §3.5's budget applies: a guest can flood the MainActor with snapshot/ring reads, and the
main-actor timeout *diagnoses* the wedge rather than *preventing* it. **Fix:** enumerate the exact
emitted fields and bound each (window owner = app bundle-id only, never the title string; responder =
class only, never `stringValue`); give the door its own per-token rate/concurrency budget enforced at
the MCP entry point *before* the MainActor hop; and name the ring buffer's bounds (size, per-entry
cap, retention), which are asserted but unspecified.

*Weigh in:* #964 + security review for the tool's surface and bound; main-actor review for the read.

### 3.8 The reply direction (Iris — a whole axis the other points miss)

Every point above is about what a guest can make Iris *do*. None covers what Iris *sends back*. A
role session holds memory, facts, and user context, and its reply to a guest is **outbound data** —
the same category as `gmail_send_email`. With the trusted in-house dev team that is harmless. But
this doc's own claim is that "nothing in the surface is dev-team-specific" and the floor must hold
for any granted peer — so a reply to a guest needs egress confinement, or the "any granted agent"
generalization leaks the user's context outward.

**Two corrections from dev-2's verification.** First, the earlier "the taint gate *deadlocks* on
guest replies" worry does not hold today: `send_to_session` is not in `OutboundTools.builtIn` (only
`gmail_send_email`, the two Google-workspace writes, `search_web`, and non-read-only MCP tools), so
`outboundGate` returns `.notGated` for it — a deadlock arises *only if* this proposal adds guest
replies to that gated set. Second, and the real gap: `#964`'s `poll` is a **pull** mailbox, so a
reply need not use `send_to_session` at all — yet the doc never states *how* a reply reaches the
mailbox. That path must be specified, and it should be neither `send_to_session` (stripped under
shape 2, §3.2) nor the tool-name-keyed `outboundGate` (whose `outboundAllowedTools` is a `[String]`,
so one exemption would cover every target).

**But egress gating on the reply is not where the confidentiality bar is won (Rune).** The exfil
channel is the *model*, not the tool: a guest turn over unpartitioned shared history can paraphrase a
prior secret into its reply, and output scrubbing catches only literal values. So the real bound is
§3.2's context partitioning (shapes 3–6), not a §3.8 egress gate — the reply-egress decision belongs
*inside* the §3.2 shape choice, not deferred here. What §3.8 still owns once context is partitioned:
per-target (not per-tool-name) egress confinement via `#974`'s `AccessProfile` transport/peer
allowlist, for the "any granted agent" generalization.

*To settle:* fold the reply-egress decision into §3.2's shape choice; specify the pull-mailbox reply
mechanism; per-target egress confinement on it.

*Weigh in:* whoever owns egress/taint gating and the `#964` mailbox, security review.

## 4. What is already solid (leave alone unless a point above forces it)

- The `contextId` / `inReplyTo` "delivered-to-you" ACL for messaging, and the §7.6 B rule that a
  bare hash grants no read.
- The §6 token bucket (capacity 20, one send / 15 s) and the hop-depth limit (`maxSessionCascade`)
  as the *starting* budget — §3.5 re-keys them per guest token, it does not replace them.
- SHA-verify-on-read for objects.
- The launch + daily retention sweep is solid for **conversation-scoped** artifacts. (An earlier
  draft claimed guest objects must write `artifact_refs` rows "or they leak" — that is **backwards**,
  Clomp's trace, verified: `ArtifactStore.sweep` walks every file on disk and *orphan-deletes* the
  ones **without** a row after a 7-day grace, while a row **keeps** the blob, and the only row-delete
  path is `deleteConversation` — keyed by a `Conversation` UUID a guest never has. So writing rows
  for guest transfers would *pin* those blobs until the 2 GB exchange cap fails new attachments, not
  prevent a leak. Guest / standing-role artifacts need a TTL/expiry prune of their own — now an open
  item under §3.1/§3.6, not a solved one.)

## 5. What this doc is not, and the next step

This is not a plan and not a design of record. It is the framing for a design conversation that
pulls in the dev team, the Iris reviewers, and the overseer. Its eight points were hardened before
wider review by three pre-circulation passes (2026-11-11): dev-2's fact-check against the specs,
Iris's code-grounded review (which added the app-vs-session split, the app-level self-report tool,
turn-scoped authority, and the steer-path and reply-direction seams), dev-1's independent re-review
(which corrected the taint claim in §3.2 and raised the key-window gap in §3.7), Clomp's external
review verified by dev-2 (which surfaced the §3.2 fork and the shared-history, principal-gating, and
cascade constraints), and Rune's review (deepseek, re-verified here against `6d957a74`), which showed
the prior passes had verified omissions not mechanisms — correcting §3.3 and §3.1 and establishing
that only a context-partitioned shape meets the confidentiality bar. The intended path:
circulate → reconcile the points → fold the decisions into #964 as the "generalizing the A2A
file/delivery path to `mcpGuest`" section, and raise plan work only after #964 absorbs them. No new
build begins before that.

**The §3.2 shape is decided (Brian, 2026-11-11): Shape 4 → 5, phased.** Phase 1 is Shape 4 — the
app-level self-report door (§3.7) plus the plain messaging/file-exchange surface — which serves the
debugging motivator with no confidentiality exposure and is buildable now. Phase 2 is Shape 5 (a
confined `mcpGuest` lane with a bounded read of the role session), gated on #1066's context
partitioning. Shapes 1–2 are rejected (confidentiality); 3 is a subset of 5, 6 is heavier. This
resolves the doc's central fork; the remaining §3.x items are Phase-appropriate build details.

Two further points are settled, not open. **§3.7's scope** (Brian): a narrow, read-only, app-level
self-report door is accommodated — it *is* Phase 1's door. **The never-steer rule in §3.2** is a hard
security line: guest arrivals must never be consumed as a steer into a turn running under the user's
permissions. (No guest path exists today — a requirement for the designed path, not a live hole.)
