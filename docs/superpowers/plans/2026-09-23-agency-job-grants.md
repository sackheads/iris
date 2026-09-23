# Agency Deliverable 4½: Job Grants — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Status:** READY — spec proposed 2026-09-23 (`a983a4b`), amended twice the same day after an adversarial pre-review (`8f2c044`, `10ba75a`): §0.9 real-path matching and no `..`, §0.10 mounts fixed by the grant and `set_workspace` refused unattended, §0.11 explicit `network: false` is a grant. Plan revised 2026-09-23 against `10ba75a`. Closes #282.

**Goal:** A `mutating` job created with `mounts` and `network` runs its commands in the VM with exactly those directories and that network, may `write_file`/`read_file` unattended inside them, is re-checked against the disk at every fire and click, ends its container when the run ends, and says on `/jobs`, the card and the result sentence what it was granted.

**Architecture:** `JobGrant` (mounts + network bit) stored inside `JobPolicy.grants` (no jobs migration); `ContainerMount` becomes a struct that round-trips through the `source[:target][:ro]` string; both creation tools parse and refuse grants through one `JobGrant.resolve`; `JobRunner.openConversation` stamps `workspacePath`, `sandboxGrant` (new `Conversation` field, migration `v12_sandbox_grant`) and the pin, checks drift and the isolated network before a turn, and ends the session container on close; `CLIContainerRuntime` renders `--network <name> --no-dns` and creates `iris-isolated` on demand; `ToolExecutor.runCommand` passes the grant's mounts and network to `SandboxSessionManager.run`; `AppState.requestApproval`'s background branch asks `JobGrant.allows` after R10 and before the allowlist; `/jobs`, `list_jobs` and the card show the grant.

**Tech Stack:** Swift 6 strict concurrency, GRDB, `apple/container` CLI 1.1.0 (`run --network`, `--no-dns`, `network create --internal`), Swift Testing.

**Spec:** `docs/specs/2026-09-23-agency-job-grants.md` (binding, at `10ba75a`). Every `file:line` below was verified against the worktree (main `b302b55`) on 2026-09-23; lines may drift by a few as earlier tasks land. Prior slices: #252 (D1), #253 (D2), #257/#260/#262/#264 (D3), #279/#280 (D4).

## Global Constraints

The spec's §0 decisions, binding on every task:

- **§0.1** A grant is made once, at creation, through `schedule_job` / `register_directory_watcher` (`mounts`, `network`); the result echoes it; re-scheduling by the same explicit name from the same conversation, or re-registering the same path from the same conversation, replaces it, and omitting `mounts`/`network` on that call removes it. No confirmation card. Job creation from an unattended run stays refused (`IrisEngine.jobCreationTools`).
- **§0.2** A grant is an ordered list of `source[:target][:ro]` entries (read-write unless `:ro`) plus `network: Bool` (default `false`). Nothing else — no per-command allowlists, no secrets.
- **§0.3** Only a `mutating` job may carry a grant; a read-only job asked for one is refused with a sentence.
- **§0.4** For a granted run `run_command` is allowed unattended when — and only when — the conversation resolves as sandboxed. R20/R22 are untouched: no runtime or sandboxing off is refused, never host.
- **§0.5** `write_file`/`read_file` stay on the host and are allowed only inside the grant: `write_file` under a read-write source, `read_file` under any source, by path-component prefix, innermost entry deciding, path resolved against the run's cwd and canonicalised with `IrisPaths.canonicalPath`.
- **§0.6** The first read-write mount is the working directory and the hidden conversation's `workspacePath`; if any entry is read-write the first must be; no read-write mount means `/` as today.
- **§0.7** `network: false` attaches the container to the Iris-owned internal network `iris-isolated` (created on demand with `container network create --internal iris-isolated`) with `--no-dns`; `network: true` uses the default network; a network that cannot be created fails the fire closed with `isolated network unavailable: <detail>` on the row.
- **§0.8** Grants are re-checked at every fire and every approved call: each source must canonicalise to itself and be a directory (`GateEvaluator.mountDrift`'s rule); a miss fails with `grant source unavailable: <path>` and walks the existing retry ladder (three retries; the fourth consecutive failure pauses). `SandboxPolicy.mutatingJobCanRun` is asked as today.
- **§0.9** The grant is matched on the **real path**, never a lexical one: `realpath(3)` of the deepest existing ancestor of the *unstandardised* components, remaining components appended; any `..` component after tilde expansion is refused outright on the allow side. The same helper hardens `isUnderProtectedWriteDir` (R10) for every caller. `IrisPaths.canonicalPath` stays for its deny-side callers.
- **§0.10** A granted run's container mounts are a pure function of its grant: the workspace mount is `grant.workingDirectory`, never the conversation's current `workspacePath`. `set_workspace` is refused for every unattended conversation with `Not run: a background run cannot change its workspace; widen the job's grant instead.`, and `AppState.bindGoalWorkspace` — the one other path that moves a `workspacePath` — leaves a background conversation's alone, so the sentence is true of every path.
- **§0.11** An explicit `network: false` on a mutating job is a grant, mounts or not: `JobGrant(mounts: [], network: false)`, sentence `Grant: no mounts · network off.`; only a call naming neither `mounts` nor `network` leaves the job ungranted. On a read-only job an explicit `false` is nothing to record.
- The names below are the only names: `JobGrant`, `JobGrant.resolve`, `JobGrant.allows(toolName:details:cwd:)`, `JobGrant.nearest(to:cwd:)`, `JobGrant.drift(_:fileManager:)`, `JobGrant.describe()`, `JobGrant.sentence`, `JobPolicy.grants`, `Conversation.sandboxGrant`, `AppState.setSandboxGrant(for:_:)`, `NetworkMode`, `NetworkMode.isolatedNetworkName`, `ContainerRuntime.ensureIsolatedNetwork(named:)`, `JobRunner.grantSourceUnavailableReason(_:)`, `JobRunner.isolatedNetworkUnavailableReason(_:)`, `BlockedCall.grantNearest`, `AppState.outsideGrantDenialNotice`, `EventCard.network`, `JobsCommand.grantLine(job:)`, `IrisPaths.realPath(_:)`, `IrisPaths.realPathForAllow(_:)`, `IrisEngine.unattendedWorkspaceRefusal`.

AGENTS.md invariants, verbatim:

- **1.** "Every new field on a persisted `Codable` type must use `decodeIfPresent` (or be excluded via `CodingKeys`)." Adding a stored property with a default value is not enough — Swift's synthesized `Decodable` throws when a key is missing, which makes that row unreadable. Use `decodeIfPresent(...) ?? default` in a custom `init(from:)`, or add a `CodingKeys` case that excludes the new field entirely.
- **6.** "Gate tool exposure; never broadcast dead-weight declarations on plain turns." Every declared tool consumes prompt tokens on every call and invites unprompted tool eagerness. Unconfigured prerequisites → omit the declaration; workflow triggers → offer only on the triggering turn; lifecycle state → gate declaration on that state. The tool arguments this plan adds ride on two tools that are already declared only when `!isUnattended`; no new tool is declared, the gated tool dispatch (`jobCreationTools` refused unattended) is untouched, and `set_workspace` joins it: not declared to an unattended turn and refused in the dispatcher.
- **7.** "Never mutate process-global state in a test." Suites run concurrently, so a test that writes a global decides behaviour for whatever else is running at that moment. `ConfigManager.shared` — construct an isolated `ConfigManager(store:)` over your own `UserDefaults` suite and inject it; the guard tiers — use the task-scoped seams; the working directory — pass the base in. In this plan additionally: no test touches `RecentWrites.shared`, `SandboxSessionManager.shared`, `IrisDefaults.store`, `~/.iris`, a real container, or the network; every runtime is a fake (`RecordingLauncher`, `MockRuntime`, `GateRuntime`), every store is `ConversationStore.inMemory()`, every home is a temp `IrisPaths`, every clock is injected.
- **9.** "A behaviour change must falsify its own documentation before it lands." Describing the new thing is the easy half, and not the half that fails. The defects that actually ship are *existing* sentences the change made untrue. Two places carry them: `README.md`, and agent-facing strings (`GoalContract.oracleText`, the `description` fields in `ToolExecutor.getTools()` and the tool declarations in `iris.swift` / `SubagentManager.swift`, and the system prompts). **Search, do not compose.**

House rules: Swift Testing only (`@Suite`, `@Test`, `#expect`, `#require`), never XCTest; `scripts/test-filter.sh <SuiteType>` for a focused run and quote the test count when citing one (a filter that matches nothing exits 0, #271); `swift test; echo exit=$?` = 0 before each commit; conventional commits ending in `(#282)` with the `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` trailer; never `git add` `.superpowers/` or `.claude/`.

---

## Task 1: `JobGrant`, `ContainerMount` as a struct, `JobPolicy.grants` **[§1 model]**

Task map (11 tasks, each green on its own): 1 model · 2a grant resolution and sentences · 2b the two tools · 3a the conversation field, migration v12, subagent inheritance · 3b the runner · 4a the container runtime · 4b the session manager, the executor and `set_workspace` · 5a the pure gate and the real-path helper · 5b the approval branch · 6 visibility · 7 docs.

**Files:**
- Create: `Sources/iris/JobGrant.swift`
- Modify: `Sources/iris/ContainerRuntime.swift:15-77` (`enum ContainerMount` → `struct ContainerMount`; the static helpers stay)
- Modify: `Sources/iris/JobPolicy.swift:17-108` (`grants`, `CodingKeys`, `init`, `init(from:)`)
- Test: `Tests/irisTests/JobGrantTests.swift` (new), `Tests/irisTests/JobPolicyTests.swift` (one added case), `Tests/irisTests/ContainerRuntimeTests.swift` (unchanged — `ContainerMount.argument(for:)` keeps its signature)

**Interfaces:**
- Consumes: `ContainerMount.hasReadOnlyFlag(_:)`, `ContainerMount.argument(for:)` (ContainerRuntime.swift:43-76); `JobPolicy`'s lenient decoder shape (JobPolicy.swift:87-98); `JobLedger.policy(from:)` (JobLedger.swift:263-269: NULL/unparsable → `JobPolicy()`).
- Produces:

```swift
/// One host directory made visible inside the container. Was a caseless enum of helpers; the
/// helpers keep their names so every existing caller compiles unchanged.
struct ContainerMount: Codable, Equatable, Hashable, Sendable {
    let source: String
    let target: String
    let readOnly: Bool
    init(source: String, target: String? = nil, readOnly: Bool = false)   // target nil → identity-mapped
    /// Strict: the same refusals `argument(for:)` makes (parts, empty, relative, comma).
    init(parsing entry: String) throws
    /// `source[:target][:ro]`; the target is omitted when it equals the source.
    var entry: String
    var argument: String { get throws }          // type=virtiofs,source=…,target=…[,readonly]
    static func hasReadOnlyFlag(_ entry: String) -> Bool        // unchanged
    static func argument(for entry: String) throws -> String    // unchanged
    // Codable through a single string value — the on-disk form IS `entry`.
}

struct JobGrant: Codable, Equatable, Sendable {
    var mounts: [ContainerMount]      // ordered; sources stored canonical (Task 2a canonicalises)
    var network: Bool                 // default false
    init(mounts: [ContainerMount] = [], network: Bool = false)
    var workingDirectory: String? { mounts.first(where: { !$0.readOnly })?.source }
    var mountEntries: [String] { mounts.map(\.entry) }
    // init(from:): mounts decodeIfPresent ?? [], network decodeIfPresent ?? false;
    // a mount string that will not parse throws, and JobPolicy's decoder turns that into nil.
}

// JobPolicy
var grants: JobGrant?                                   // nil = no grant; encodes as an absent key
init(overlap:catchUp:runTimeoutSeconds:perRunTokenBudget:dailyTokenBudget:maxRunsPerHour:retry:, grants: JobGrant? = nil)
// init(from:): grants = try? c.decodeIfPresent(JobGrant.self, forKey: .grants)   // malformed → nil, the job still loads
```

- [ ] **Step 1: Write the failing tests** — `Tests/irisTests/JobGrantTests.swift`

```swift
import Testing
import Foundation
@testable import iris

/// #282 §1 — the model half of a grant: the mount struct and its string form, the grant, and its
/// lenient home inside `JobPolicy`. Pure codec behaviour; nothing here touches a disk or a runtime.
@Suite("JobGrant model (#282)")
struct JobGrantTests {
    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test("a mount round-trips through its string form, and the target is omitted when identity-mapped")
    func mountRoundTrips() throws {
        let rw = try ContainerMount(parsing: "/Users/me/proj")
        #expect(rw == ContainerMount(source: "/Users/me/proj"))
        #expect(rw.entry == "/Users/me/proj")
        #expect(!rw.readOnly && rw.target == "/Users/me/proj")

        let ro = try ContainerMount(parsing: "/Users/me/.config/gh:/gh:ro")
        #expect(ro == ContainerMount(source: "/Users/me/.config/gh", target: "/gh", readOnly: true))
        #expect(ro.entry == "/Users/me/.config/gh:/gh:ro")
        #expect(try ContainerMount(parsing: "/a:ro").entry == "/a:ro")

        // Codable IS the string: the policy JSON, the result and `/jobs` all show one spelling.
        #expect(try json([rw, ro]) == #"["\/Users\/me\/proj","\/Users\/me\/.config\/gh:\/gh:ro"]"#)
        let back = try JSONDecoder().decode([ContainerMount].self, from: Data(#"["/a","/b:/c:ro"]"#.utf8))
        #expect(back == [ContainerMount(source: "/a"), ContainerMount(source: "/b", target: "/c", readOnly: true)])
    }

    @Test("parsing refuses what argument(for:) refuses, with the same reasons")
    func mountParsingRefusals() {
        for entry in ["", "/a:", "/a:/b:/c", "relative:/x", "/a,b", "/a:/b:rw"] {
            #expect(throws: ContainerRuntimeError.self, Comment(rawValue: entry)) {
                try ContainerMount(parsing: entry)
            }
        }
        #expect(throws: ContainerRuntimeError.invalidMount(entry: "data:/data", reason: "both paths must be absolute; a relative source is read as the name of a volume, not a directory")) {
            try ContainerMount(parsing: "data:/data")
        }
        // And the rendered argument is the one the runtime already tests.
        #expect(try ContainerMount(source: "/a", target: "/b", readOnly: true).argument
                == "type=virtiofs,source=/a,target=/b,readonly")
    }

    @Test("the working directory is the first read-write mount, or nil")
    func workingDirectory() {
        let grant = JobGrant(mounts: [ContainerMount(source: "/p"), ContainerMount(source: "/q", readOnly: true)])
        #expect(grant.workingDirectory == "/p")
        #expect(JobGrant(mounts: [ContainerMount(source: "/q", readOnly: true)]).workingDirectory == nil)
        #expect(JobGrant().workingDirectory == nil)
        #expect(grant.mountEntries == ["/p", "/q:ro"])
    }

    @Test("a grant decodes leniently: absent fields default, and network defaults to false")
    func grantDecodesLeniently() throws {
        let empty = try JSONDecoder().decode(JobGrant.self, from: Data("{}".utf8))
        #expect(empty == JobGrant())
        let mountsOnly = try JSONDecoder().decode(JobGrant.self, from: Data(#"{"mounts":["/p"]}"#.utf8))
        #expect(mountsOnly.network == false && mountsOnly.mounts == [ContainerMount(source: "/p")])
    }

    @Test("a policy carries its grant, and a policy without one encodes exactly as before")
    func policyCarriesGrant() throws {
        let grant = JobGrant(mounts: [ContainerMount(source: "/p"), ContainerMount(source: "/q", readOnly: true)], network: true)
        let policy = JobPolicy(overlap: .queue, grants: grant)
        let text = try json(policy)
        #expect(text.contains(#""grants":{"mounts":["\/p","\/q:ro"],"network":true}"#))
        #expect(try JSONDecoder().decode(JobPolicy.self, from: Data(text.utf8)) == policy)
        // Byte-for-byte the D3 shape for an ungranted job: no `grants` key at all.
        #expect(!(try json(JobPolicy())).contains("grants"))
    }

    @Test("a grant this build cannot read is nil, and the policy around it still decodes")
    func malformedGrantIsNilAndPolicySurvives() throws {
        let junk = try JSONDecoder().decode(JobPolicy.self, from: Data(#"{"overlap":"queue","grants":"junk"}"#.utf8))
        #expect(junk.grants == nil)
        #expect(junk.overlap == .queue, "the rest of the policy is not lost to the grant")
        let badMount = try JSONDecoder().decode(JobPolicy.self, from: Data(#"{"grants":{"mounts":["relative"]}}"#.utf8))
        #expect(badMount.grants == nil, "one unreadable mount drops the whole grant, never half of it")
    }

    @Test("a stored job with an unreadable grant still loads from the ledger, ungranted")
    func ledgerLoadsAJobWithAnUnreadableGrant() throws {
        let store = try ConversationStore.inMemory()
        let job = Job(name: "g", prompt: "p", trigger: .schedule(.interval(seconds: 60)), profile: .mutating)
        try store.ledger.upsert(job)
        try store.writer.write { db in
            try db.execute(sql: "UPDATE jobs SET policy = ? WHERE id = ?",
                           arguments: [#"{"grants":{"mounts":[42]}}"#, job.id.uuidString])
        }
        let back = try #require(try store.ledger.job(id: job.id))
        #expect(back.policy.grants == nil)
        #expect(store.ledger.unreadableJobCount == 0)
    }
}
```

Each test fails today because `ContainerMount` has no `init(parsing:)`/`entry`/instances, `JobGrant` does not exist, and `JobPolicy` has no `grants`. Once green: `mountRoundTrips` turns red if the target is ever encoded when identity-mapped; `policyCarriesGrant`'s last line turns red if `grants` is encoded as `null`; `malformedGrantIsNilAndPolicySurvives` turns red if the decoder uses `try` instead of `try?`; `ledgerLoadsAJobWithAnUnreadableGrant` turns red if `JobLedger.policy(from:)` stops swallowing the decode.

`store.writer` — check it is reachable from tests (`ConversationStore.writer` is used by `JobLedger`; if it is `private`, use `store.ledger.writer` or add an `internal` accessor in `ConversationStore` — one line, no behaviour).

- [ ] **Step 2: Run to verify they fail**

Run: `scripts/test-filter.sh JobGrantTests`
Expected: compile error — `cannot find 'JobGrant' in scope`, `'ContainerMount' cannot be constructed`.

- [ ] **Step 3: Make `ContainerMount` a struct** — `Sources/iris/ContainerRuntime.swift:15-77`. Keep the doc comment; replace `enum ContainerMount {` and add the instance surface. The static helpers stay verbatim.

```swift
struct ContainerMount: Codable, Equatable, Hashable, Sendable {
    let source: String
    let target: String
    let readOnly: Bool

    init(source: String, target: String? = nil, readOnly: Bool = false) {
        self.source = source
        self.target = target ?? source
        self.readOnly = readOnly
    }

    /// Strict, through `argument(for:)`: an entry this refuses is one no container could be
    /// created with, and refusing here means a grant can never store one.
    init(parsing entry: String) throws {
        _ = try Self.argument(for: entry)
        var parts = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let readOnly = Self.hasReadOnlyFlag(entry)
        if readOnly { parts.removeLast() }
        self.init(source: parts[0], target: parts.count == 2 ? parts[1] : nil, readOnly: readOnly)
    }

    /// The one spelling: `source[:target][:ro]`, target omitted when identity-mapped. This is the
    /// tool's input grammar, the stored form and what every surface prints.
    var entry: String {
        var text = source
        if target != source { text += ":\(target)" }
        if readOnly { text += ":ro" }
        return text
    }

    var argument: String {
        get throws { try Self.argument(for: entry) }
    }

    init(from decoder: Decoder) throws {
        try self.init(parsing: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entry)
    }

    // static func hasReadOnlyFlag(_:) and static func argument(for:) — unchanged from :43-76
}
```

`swift build` — every existing caller (`GateEvaluator`, `ScheduleJobArguments`, `CLIContainerRuntime`, the tests) uses only the two statics and compiles unchanged.

- [ ] **Step 4: Create `Sources/iris/JobGrant.swift`**

```swift
import Foundation

/// What a `mutating` job was granted at creation (#282, spec §1): the host directories its
/// container mounts and its host file tools may use, and whether its commands may reach the
/// network. Stored inside `JobPolicy.grants`, so an older build reads a granted job as an
/// ungranted one — the safe direction — and there is no jobs migration.
struct JobGrant: Codable, Equatable, Sendable {
    /// Ordered. The first read-write entry is the working directory (§0.6). Sources are stored
    /// canonical (`IrisPaths.canonicalPath`) by the tools that create a grant.
    var mounts: [ContainerMount]
    /// `false` attaches the container to the host-only `iris-isolated` network with no DNS (§0.7).
    var network: Bool

    init(mounts: [ContainerMount] = [], network: Bool = false) {
        self.mounts = mounts
        self.network = network
    }

    /// The run's working directory and the hidden conversation's `workspacePath`; nil means `/`.
    var workingDirectory: String? { mounts.first(where: { !$0.readOnly })?.source }

    /// The mounts in the runtime's `source[:target][:ro]` grammar.
    var mountEntries: [String] { mounts.map(\.entry) }

    private enum CodingKeys: String, CodingKey { case mounts, network }

    /// Invariant 1 on both keys. A mount that will not parse throws on purpose: half a grant is
    /// not a grant, and `JobPolicy`'s decoder turns the throw into "no grant".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mounts = try c.decodeIfPresent([ContainerMount].self, forKey: .mounts) ?? []
        network = try c.decodeIfPresent(Bool.self, forKey: .network) ?? false
    }
}
```

- [ ] **Step 5: Add `grants` to `JobPolicy`** — `Sources/iris/JobPolicy.swift`

After `var retry: Bool = true` (:44):
```swift
    /// The directories and network a `mutating` job was granted at creation (#282). `nil` for
    /// every job without one, which is every job written before deliverable 4½. Inside the policy
    /// rather than a column of its own so an older build ignores it (and, re-saving, drops it —
    /// the fate of every unknown policy key, and documented).
    var grants: JobGrant?
```
`init` (:67-77) gains `grants: JobGrant? = nil` as the last parameter and `self.grants = grants`. `CodingKeys` (:79-82) gains `case grants`. `init(from:)` (:87-98) gains, after `retry`:
```swift
        // `try?`, not `try`: a grant this build cannot read is no grant, and the job still loads.
        grants = try? c.decodeIfPresent(JobGrant.self, forKey: .grants)
```
Synthesized `encode(to:)` uses `encodeIfPresent` for the optional, so an ungranted policy's JSON is unchanged.

- [ ] **Step 6: Extend `JobPolicyTests`** — add to `roundTrip` (:34-39) a second policy with `grants: JobGrant(mounts: [ContainerMount(source: "/p")])` and assert it round-trips; add to `emptyObjectIsDefault` `#expect(policy.grants == nil)`.

- [ ] **Step 7: Run to verify they pass**

Run: `scripts/test-filter.sh JobGrantTests` then `scripts/test-filter.sh JobPolicyTests` then `scripts/test-filter.sh ContainerRuntimeTests` (the argv suite must be untouched by the struct conversion).
Expected: PASS, 7 + (existing + 0) + existing tests respectively; quote the counts.

- [ ] **Step 8: Full suite and commit**

```bash
swift test; echo exit=$?
git add Sources/iris/JobGrant.swift Sources/iris/ContainerRuntime.swift Sources/iris/JobPolicy.swift Tests/irisTests/JobGrantTests.swift Tests/irisTests/JobPolicyTests.swift
git commit -m "feat(jobs): JobGrant model, ContainerMount as a Codable struct, JobPolicy.grants decoded leniently (#282)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 2a: `JobGrant.resolve`, the refusal sentences, `describe()` **[§1 refusals, §0.3, §0.6, §0.11]**

**Files:**
- Modify: `Sources/iris/JobGrant.swift` (add `resolve`, the sentences, `describe()`, `sentence`)
- Test: `Tests/irisTests/JobGrantTests.swift` (a second suite, `JobGrantResolveTests`)

**Interfaces:**
- Consumes: `ContainerMount(parsing:)`, `JobGrant`, `JobProfile` (Task 1; Job.swift:12); `ContainerMount.argument(for:)` reasons (ContainerRuntime.swift:55-72); `WatchRoot.tooBroad` (WatchRoot.swift:53), `WatchRoot.isMountPoint(_:)` (:111); `IrisPaths.canonicalPath` (IrisPaths.swift:170); `ToolMessage` (ScheduleJobArguments.swift:8-15).
- Produces:

```swift
extension JobGrant {
    /// The grant these arguments describe, `nil` for none, or the sentence saying why there is none.
    /// `mounts` nil/empty and `network` nil → .success(nil). Refusals in §1's order, one sentence each.
    /// §0.11: on `.mutating`, `network == false` with no mounts is `JobGrant(mounts: [], network: false)`;
    /// on `.readOnly` an explicit `false` is `.success(nil)`.
    static func resolve(mounts: [String]?, network: Bool?, profile: JobProfile,
                        fileManager: FileManager = .default, paths: IrisPaths = .default,
                        home: String = NSHomeDirectory(),
                        isVolume: (String) throws -> Bool = { try WatchRoot.isMountPoint($0) }) -> Result<JobGrant?, ToolMessage>
    static let grantNeedsMutating: String
    static func malformed(_ entry: String, _ reason: String) -> String     // "the mount `E` cannot be used — R"
    static func missing(_ source: String) -> String                        // "the mount source S does not exist"
    static func notADirectory(_ source: String) -> String                  // "the mount source S is a file, and a file cannot be mounted — mount its directory instead"
    static func tooBroad(_ source: String) -> String                       // "the mount source S is too broad to grant (the whole filesystem, a volume, or the home directory) — name the directory the job actually works in"
    static func protected(_ source: String) -> String                      // "the mount source S is or contains Iris's own directory (~/.iris), which a job may not mount"
    static let readOnlyFirst: String                                       // checked before `duplicate`
    static func duplicate(_ source: String) -> String                      // "the mount source S is listed twice"
    /// "read-write /p (working directory) · read-only /q → /gh · network off" (+ " · nested: /p/sub under /p, whose mode applies beneath it"); "no mounts · network off" for a mount-less grant
    func describe() -> String
    var sentence: String                                                   // "Grant: " + describe() + "."
}
```

Rules locked here: sources are stored canonical (`IrisPaths.canonicalPath`), targets verbatim, as `GateEvaluator.canonicalMount` does for gates; refusal sentences are grant-worded but the *rules* are the existing ones — grammar through `ContainerMount.argument(for:)`, breadth through `WatchRoot.tooBroad` + `/Volumes/<x>` + `isMountPoint` + `home`, protection through `paths.root` in both directions (the whole of `~/.iris`, per §1); the order is exactly §1's: profile, malformed, missing/file, too broad, protected, read-only-first, duplicate (L4 — duplicate is checked after the loop so it comes after read-only-first).

- [ ] **Step 1: Write the failing tests** — append to `Tests/irisTests/JobGrantTests.swift`

```swift
/// The creation half's pure core (#282 §1, §0.11): what `mounts`/`network` resolve to and every
/// refusal by name, against temp directories only.
@Suite("JobGrant.resolve (#282)")
struct JobGrantResolveTests {
    struct Fixture {
        let base: URL          // <tmp>/iris-grant-<uuid>
        let proj: URL          // base/proj
        let creds: URL         // base/creds
        let irisRoot: URL      // base/dot-iris  (contains config/)
        let home: String       // base/home
        var paths: IrisPaths { IrisPaths(root: irisRoot) }
        func tearDown() { try? FileManager.default.removeItem(at: base) }
    }

    static func fixture() throws -> Fixture {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("iris-grant-\(UUID().uuidString)")
        for name in ["proj", "creds", "dot-iris/config", "home"] {
            try fm.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        return Fixture(base: base, proj: base.appendingPathComponent("proj"),
                       creds: base.appendingPathComponent("creds"),
                       irisRoot: base.appendingPathComponent("dot-iris"),
                       home: base.appendingPathComponent("home").path)
    }

    private func resolve(_ f: Fixture, _ mounts: [String]?, network: Bool? = nil,
                         profile: JobProfile = .mutating) -> Result<JobGrant?, ToolMessage> {
        JobGrant.resolve(mounts: mounts, network: network, profile: profile,
                         paths: f.paths, home: f.home, isVolume: { _ in false })
    }

    private func canonical(_ url: URL) -> String { IrisPaths.canonicalPath(url.path) }

    @Test("a grant resolves with canonical sources, verbatim targets, and the first read-write as working directory")
    func resolvesCanonical() throws {
        let f = try Self.fixture(); defer { f.tearDown() }
        let grant = try #require(try resolve(f, [f.proj.path, "\(f.creds.path):/gh:ro"], network: true).get())
        #expect(grant.mounts == [ContainerMount(source: canonical(f.proj)),
                                 ContainerMount(source: canonical(f.creds), target: "/gh", readOnly: true)])
        #expect(grant.network == true)
        #expect(grant.workingDirectory == canonical(f.proj))
        // Naming neither is nothing granted, on either profile.
        #expect(try resolve(f, nil).get() == nil)
        #expect(try resolve(f, []).get() == nil)
        #expect(try resolve(f, nil, profile: .readOnly).get() == nil)
        // A network bit alone is a grant: commands may reach the network from a mount-less container.
        #expect(try resolve(f, nil, network: true).get() == JobGrant(mounts: [], network: true))
    }

    @Test("an explicit network: false with no mounts is a grant on a mutating job, and nothing on a read-only one (§0.11)")
    func explicitNetworkOffIsAGrant() throws {
        let f = try Self.fixture(); defer { f.tearDown() }
        let off = try #require(try resolve(f, [], network: false).get())
        #expect(off == JobGrant(mounts: [], network: false))
        #expect(off.sentence == "Grant: no mounts · network off.")
        #expect(try resolve(f, nil, network: false).get() == JobGrant(mounts: [], network: false))
        #expect(try resolve(f, nil, network: false, profile: .readOnly).get() == nil,
                "a read-only job asked for nothing it does not already have")
    }

    @Test("each refusal, by name, in the spec's order")
    func refusalsByName() throws {
        let f = try Self.fixture(); defer { f.tearDown() }
        func refusal(_ mounts: [String]?, network: Bool? = nil, profile: JobProfile = .mutating) -> String? {
            if case .failure(let m) = resolve(f, mounts, network: network, profile: profile) { return m.text }
            return nil
        }
        // 1. a grant on a read-only profile — mounts or network alike
        #expect(refusal([f.proj.path], profile: .readOnly) == JobGrant.grantNeedsMutating)
        #expect(refusal(nil, network: true, profile: .readOnly) == JobGrant.grantNeedsMutating)
        // 2. malformed, with ContainerMount's own reasons
        #expect(refusal(["relative/dir"])?.contains("both paths must be absolute") == true)
        #expect(refusal(["\(f.proj.path):/in,puts"])?.contains("comma") == true)
        #expect(refusal(["/a:/b:/c"])?.contains("expected source[:target][:ro]") == true)
        // 3. missing or a file
        let gone = "/tmp/\(UUID().uuidString)"
        #expect(refusal([gone]) == JobGrant.missing(gone))
        let file = f.base.appendingPathComponent("f.txt"); try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(refusal([file.path]) == JobGrant.notADirectory(canonical(file)))
        // 4. too broad: /, a volume root, a mount point, the home directory
        #expect(refusal(["/"]) == JobGrant.tooBroad("/"))
        // Refused whether or not such a volume is mounted: absent it is `missing`, mounted it is
        // the lexical `/Volumes/<x>` rule — either way nothing is granted.
        #expect(refusal(["/Volumes/Data"]) != nil)
        #expect(refusal([f.home]) == JobGrant.tooBroad(IrisPaths.canonicalPath(f.home)))
        let volume = JobGrant.resolve(mounts: [f.creds.path], network: nil, profile: .mutating,
                                      paths: f.paths, home: f.home, isVolume: { _ in true })
        #expect(volume == .failure(ToolMessage(JobGrant.tooBroad(canonical(f.creds)))))
        // 5. Iris's own directory, read-only included, in both directions
        #expect(refusal([f.irisRoot.path + ":ro"]) == JobGrant.protected(canonical(f.irisRoot)))
        #expect(refusal([f.irisRoot.appendingPathComponent("config").path]) == JobGrant.protected(canonical(f.irisRoot.appendingPathComponent("config"))))
        #expect(refusal([f.base.path]) == JobGrant.protected(canonical(f.base)), "a root that contains ~/.iris sees every write into it")
        // 6. read-only first, read-write after — and it outranks a duplicate further down the list
        #expect(refusal(["\(f.creds.path):ro", f.proj.path]) == JobGrant.readOnlyFirst)
        #expect(refusal(["\(f.creds.path):ro", f.proj.path, f.proj.path]) == JobGrant.readOnlyFirst)
        #expect(refusal(["\(f.creds.path):ro"]) == nil, "all read-only is fine: the working directory is /")
        // 7. the same source twice, however spelled
        #expect(refusal([f.proj.path, f.proj.path + "/"]) == JobGrant.duplicate(canonical(f.proj)))
    }

    @Test("nested entries are allowed and the sentence says so")
    func nestedEntries() throws {
        let f = try Self.fixture(); defer { f.tearDown() }
        let sub = f.proj.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let grant = try #require(try resolve(f, [f.proj.path, "\(sub.path):ro"]).get())
        #expect(grant.describe() == "read-write \(canonical(f.proj)) (working directory) · read-only \(canonical(sub)) · network off · nested: \(canonical(sub)) under \(canonical(f.proj)), whose mode applies beneath it")
        let plain = try #require(try resolve(f, [f.proj.path, "\(f.creds.path):/gh:ro"], network: true).get())
        #expect(plain.describe() == "read-write \(canonical(f.proj)) (working directory) · read-only \(canonical(f.creds)) → /gh · network on")
        #expect(plain.sentence == "Grant: \(plain.describe()).")
        #expect(JobGrant(network: true).describe() == "no mounts · network on")
    }
}
```

What turns each red once green: `resolvesCanonical` — storing the spelling instead of `canonicalPath`; `explicitNetworkOffIsAGrant` — the old `guard !entries.isEmpty || wantsNetwork` (H1); `refusalsByName` — dropping any one guard, checking the profile after the mounts, or checking duplicates inside the loop (the both-defects case); `nestedEntries` — losing the nested clause.

- [ ] **Step 2: Run to verify they fail** — `scripts/test-filter.sh JobGrantResolveTests`; Expected: compile error `type 'JobGrant' has no member 'resolve'`.

- [ ] **Step 3: Implement** — append to `Sources/iris/JobGrant.swift`

```swift
extension JobGrant {
    static let grantNeedsMutating = "A grant (mounts or network) is only accepted on a mutating job: a read-only run has no mounts and no network by definition. Pass profile 'mutating', or drop mounts and network."
    static func malformed(_ entry: String, _ reason: String) -> String { "the mount `\(entry)` cannot be used — \(reason)" }
    static func missing(_ source: String) -> String { "the mount source \(source) does not exist" }
    static func notADirectory(_ source: String) -> String {
        "the mount source \(source) is a file, and a file cannot be mounted — mount its directory instead"
    }
    static func tooBroad(_ source: String) -> String {
        "the mount source \(source) is too broad to grant (the whole filesystem, a volume, or the home directory) — name the directory the job actually works in"
    }
    static func protected(_ source: String) -> String {
        "the mount source \(source) is or contains Iris's own directory (~/.iris), which a job may not mount"
    }
    static let readOnlyFirst = "the first mount must be read-write when any later one is, because it is the job's working directory — put the read-write directory first"
    static func duplicate(_ source: String) -> String { "the mount source \(source) is listed twice" }

    /// The grant `mounts`/`network` describe, or the sentence refusing it (spec §1, in its order).
    /// Every question is asked of the *resolved* source, never the spelling — `~/x -> /` is a
    /// mount of the whole disk — and the resolved source is what is stored (§0.8 compares against
    /// it at every fire). Naming neither argument is `.success(nil)`; naming `network: false` on a
    /// mutating job is a grant of "no mounts · network off" (§0.11) — the person said off.
    static func resolve(mounts: [String]?, network: Bool?, profile: JobProfile,
                        fileManager: FileManager = .default, paths: IrisPaths = .default,
                        home: String = NSHomeDirectory(),
                        isVolume: (String) throws -> Bool = { try WatchRoot.isMountPoint($0) }) -> Result<JobGrant?, ToolMessage> {
        let entries = mounts ?? []
        guard !entries.isEmpty || network != nil else { return .success(nil) }
        guard profile == .mutating else {
            // A read-only job that named nothing it does not already have — no mounts, network
            // off — asked for nothing; anything else is the contradiction §0.3 refuses.
            if entries.isEmpty, network == false { return .success(nil) }
            return .failure(ToolMessage(grantNeedsMutating))
        }

        var resolved: [ContainerMount] = []
        for entry in entries {
            let parsed: ContainerMount
            do { parsed = try ContainerMount(parsing: entry) }
            catch ContainerRuntimeError.invalidMount(_, let reason) { return .failure(ToolMessage(malformed(entry, reason))) }
            catch { return .failure(ToolMessage(malformed(entry, "\(error)"))) }   // backstop; parsing only throws invalidMount
            let source = IrisPaths.canonicalPath(parsed.source)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source, isDirectory: &isDirectory) else {
                return .failure(ToolMessage(missing(source)))
            }
            guard isDirectory.boolValue else { return .failure(ToolMessage(notADirectory(source))) }
            if let broad = broadRefusal(source, home: home, isVolume: isVolume) { return .failure(ToolMessage(broad)) }
            let iris = IrisPaths.canonicalPath(paths.root.path).lowercased()
            let lowered = source.lowercased()
            if lowered == iris || lowered.hasPrefix(iris + "/") || iris.hasPrefix(lowered + "/") {
                return .failure(ToolMessage(protected(source)))
            }
            resolved.append(ContainerMount(source: source, target: parsed.target, readOnly: parsed.readOnly))
        }
        // §0.6: the working directory is never in doubt. Before the duplicate check, in §1's order.
        if let first = resolved.first, first.readOnly, resolved.contains(where: { !$0.readOnly }) {
            return .failure(ToolMessage(readOnlyFirst))
        }
        var seen: Set<String> = []
        for mount in resolved where !seen.insert(mount.source).inserted {
            return .failure(ToolMessage(duplicate(mount.source)))
        }
        return .success(JobGrant(mounts: resolved, network: network ?? false))
    }

    /// `WatchRoot.refusal`'s breadth rule, without its sentence: `/`, the listed system roots, any
    /// `/Volumes/<x>`, any mount point, and the home directory. A mount point that will not
    /// answer is refused too (fail closed, as there).
    private static func broadRefusal(_ source: String, home: String, isVolume: (String) throws -> Bool) -> String? {
        let lowered = source.lowercased()
        let broad = (WatchRoot.tooBroad + [home]).map { IrisPaths.canonicalPath($0).lowercased() }
        if broad.contains(lowered) { return tooBroad(source) }
        let components = URL(fileURLWithPath: lowered).pathComponents
        if components.count == 3, components[1] == "volumes" { return tooBroad(source) }
        if (try? isVolume(source)) ?? true { return tooBroad(source) }
        return nil
    }

    /// One line, the same on the result, `/jobs` and the card: each mount's mode, its source (and
    /// target when different), which one is the working directory, the network bit, and the
    /// nesting note when a source lies under another.
    func describe() -> String {
        var parts: [String] = mounts.map { mount in
            var text = (mount.readOnly ? "read-only " : "read-write ") + mount.source
            if mount.target != mount.source { text += " \u{2192} \(mount.target)" }
            if !mount.readOnly, mount.source == workingDirectory { text += " (working directory)" }
            return text
        }
        if parts.isEmpty { parts.append("no mounts") }
        parts.append(network ? "network on" : "network off")
        for inner in mounts {
            if let outer = mounts.first(where: { $0.source != inner.source && inner.source.hasPrefix($0.source + "/") }) {
                parts.append("nested: \(inner.source) under \(outer.source), whose mode applies beneath it")
            }
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    var sentence: String { "Grant: \(describe())." }
}
```

- [ ] **Step 4: Run to verify they pass** — `scripts/test-filter.sh JobGrantResolveTests` (4 tests) and `scripts/test-filter.sh JobGrantTests` (still 7).

- [ ] **Step 5: Full suite and commit**
```bash
swift test; echo exit=$?
git add Sources/iris/JobGrant.swift Tests/irisTests/JobGrantTests.swift
git commit -m "feat(jobs): JobGrant.resolve — the grant's refusals in the spec's order, explicit network:false as a grant, and the one-line description (#282)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 2b: The two tools — arguments, `makeJob`, replace-by-name, `registerWatcher`, the declarations **[§4, §0.1]**

**Files:**
- Modify: `Sources/iris/ScheduleJobArguments.swift:24-45` (two fields), `:49-106` (`parse`), `:124-158` (`makeJob`), `:343-358` (`resultSentence`), `:439-457` (`stringList` becomes internal and takes its refusal as a parameter), plus a new `boolean(_:)` reader
- Modify: `Sources/iris/RegisterWatcherArguments.swift:10-59` (`profile`, `mounts`, `network`)
- Modify: `Sources/iris/ToolExecutor.swift:20-34` (`mutatingJobsAvailable` seam), `:91-105` (declaration), `:245-321` (`registerWatcher`)
- Modify: `Sources/iris/iris.swift:1202-1231` (`schedule_job` declaration: the description sentence, `mounts`, `network`), `:1956-2013` (`scheduleJob`: replace by name)
- Test: `Tests/irisTests/JobGrantTests.swift` (a third suite, `JobGrantToolTests`), `Tests/irisTests/RegisterWatcherTests.swift` (extend), `Tests/irisTests/ToolSurfaceTrimTests.swift:96-127` (extend `descriptionsStateTriggers`)

**Interfaces:**
- Consumes: `JobGrant.resolve(mounts:network:profile:fileManager:paths:home:isVolume:)`, `JobGrant.sentence` (Task 2a); `JobPolicy.grants` (Task 1); `ScheduleJobArguments.text/integer/given/present` (:392-437); `JobScheduler.schedule(_:)` (JobScheduler.swift:511 — an upsert by id, so a replacement keeps the job's runs); `JobLedger.upsert` (`ON CONFLICT(id)`, JobLedger.swift:67-103); `JobGrantResolveTests.fixture()` (Task 2a, reused).
- Produces:

```swift
// ScheduleJobArguments
let mounts: [String]?; let network: Bool?
static func boolean(_ value: JSONValue?) -> Result<Bool?, ToolMessage>      // absent/null/"" → nil; .bool; "true"/"false"/"yes"/"no"/"on"/"off"; else .failure(networkShape)
static let networkShape: ToolMessage = "network must be true or false."
static let mountsShape: ToolMessage = "mounts must be a directory path, or a list of them, each as '/host/dir', '/host/dir:ro' or '/host/dir:/path/in/container'."
static func stringList(_ value: JSONValue?, shape: ToolMessage) -> Result<[String]?, ToolMessage>   // was private, took no shape
/// The tool's own prefix for a grant refusal: "mounts: " when mounts were named, none for a network-only refusal (L4).
static func grantRefusal(_ message: ToolMessage, mountsNamed: Bool) -> ToolMessage
func makeJob(defaultTimeZone:createdIn:existingNames:sandboxAvailable:fileManager:directoryEntryLimit:, paths: IrisPaths = .default, home: String = NSHomeDirectory()) -> Result<Job, ToolMessage>
static func replacedNote(_ name: String) -> String   // "This replaced '<name>' from this conversation; its run history is kept."
// RegisterWatcherArguments
let profile: String?; let mounts: [String]?; let network: Bool?
// ToolExecutor
var mutatingJobsAvailable: (@Sendable () -> Bool)?    // nil = SandboxPolicy.mutatingJobCanRun(); tests set { true }
static let watchProfileNeedsSandbox = "A mutating watch's commands always run in the apple/container VM, and that VM is not available: install the runtime and turn sandboxing on in Settings → Sandboxing, or leave the watch read-only."
// IrisEngine
func scheduleJob(_:conversationId:review:sandboxAvailable:, paths: IrisPaths = .default, home: String = NSHomeDirectory()) async -> String
```

Rules locked here, from spec §4: (1) **the grant is not "say nothing when omitted"** on either tool — a re-registration or a re-schedule stores exactly the grant the call names, nil when it names none; the watcher's other three optional arguments keep their "stored value stands" rule. (2) The effective profile of a re-registered watch is `given ?? existing`; of a new one `given ?? .readOnly`; a `mutating` watch is refused without the VM as `schedule_job` refuses one. (3) `schedule_job` **replaces** only when `name` was given explicitly and a job with that slug was created in the *same* conversation; every other collision still suffixes (`uniqueName`), so `naming` at ScheduleJobArgumentsTests:35 stays true. The replacement keeps the id, `createdAt`, `destinationConversationId`; everything else — schedule, prompt, profile, policy, grant — comes from the new call; `retryAttempt` 0, `pausedReason` nil, `queuedFire` nil.

- [ ] **Step 1: Write the failing tests** — append to `Tests/irisTests/JobGrantTests.swift`

```swift
/// The two tools (#282 §4): parsing, the stored grant, the sentence, replace and remove.
@MainActor
@Suite("JobGrant through the tools (#282)")
struct JobGrantToolTests {
    private func canonical(_ url: URL) -> String { IrisPaths.canonicalPath(url.path) }

    @Test("schedule_job parses mounts and network in the loose shapes a model writes, and refuses the rest")
    func scheduleJobArguments() throws {
        let a = try ScheduleJobArguments.parse(["prompt": .string("p"), "intervalSeconds": .int(60),
                                                "mounts": .string("/p"), "network": .string("true")]).get()
        #expect(a.mounts == ["/p"] && a.network == true)
        let b = try ScheduleJobArguments.parse(["prompt": .string("p"), "intervalSeconds": .int(60),
                                                "mounts": .array([.string("/p"), .string("/q:ro")]), "network": .bool(false)]).get()
        #expect(b.mounts == ["/p", "/q:ro"] && b.network == false)
        let none = try ScheduleJobArguments.parse(["prompt": .string("p"), "intervalSeconds": .int(60),
                                                   "mounts": .array([]), "network": .null]).get()
        #expect(none.mounts == nil && none.network == nil)
        #expect(ScheduleJobArguments.parse(["prompt": .string("p"), "network": .string("maybe")]) == .failure(ScheduleJobArguments.networkShape))
        #expect(ScheduleJobArguments.parse(["prompt": .string("p"), "mounts": .array([.int(3)])]) == .failure(ScheduleJobArguments.mountsShape))
    }

    @Test("makeJob stores the grant on a mutating job and refuses one on a read-only job, before the schedule is looked at")
    func makeJobStoresGrant() throws {
        let f = try JobGrantResolveTests.fixture(); defer { f.tearDown() }
        let args = try ScheduleJobArguments.parse(["prompt": .string("p"), "intervalSeconds": .int(60),
                                                   "profile": .string("mutating"), "mounts": .string(f.proj.path)]).get()
        let job = try args.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: [],
                                   sandboxAvailable: true, paths: f.paths, home: f.home).get()
        #expect(job.policy.grants == JobGrant(mounts: [ContainerMount(source: canonical(f.proj))]))
        #expect(ScheduleJobArguments.resultSentence(for: job).hasSuffix(" Grant: read-write \(canonical(f.proj)) (working directory) · network off."))

        let readOnly = try ScheduleJobArguments.parse(["prompt": .string("p"), "mounts": .string(f.proj.path)]).get()
        #expect(readOnly.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: [], sandboxAvailable: true,
                                 paths: f.paths, home: f.home) == .failure(ToolMessage("mounts: " + JobGrant.grantNeedsMutating)),
                "refused for the grant, not for the missing schedule")
        // A network-only refusal is not about mounts and does not say so (L4).
        let netOnly = try ScheduleJobArguments.parse(["prompt": .string("p"), "network": .bool(true)]).get()
        #expect(netOnly.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: [], sandboxAvailable: true,
                                paths: f.paths, home: f.home) == .failure(ToolMessage(JobGrant.grantNeedsMutating)))
        // §0.11 through the tool: explicit network false, no mounts, mutating → a grant.
        let off = try ScheduleJobArguments.parse(["prompt": .string("p"), "intervalSeconds": .int(60),
                                                  "profile": .string("mutating"), "network": .bool(false)]).get()
        let offJob = try off.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: [], sandboxAvailable: true,
                                     paths: f.paths, home: f.home).get()
        #expect(offJob.policy.grants == JobGrant(mounts: [], network: false))
        #expect(ScheduleJobArguments.resultSentence(for: offJob).hasSuffix(" Grant: no mounts · network off."))
    }

    private func engineHarness() throws -> (ConversationStore, AppState, IrisEngine, UUID) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let conversation = UUID()
        state.createNewConversation(id: conversation)
        state.selectedConversationId = conversation
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)
        return (store, state, engine, conversation)
    }

    @Test("re-scheduling the same explicit name from the same conversation replaces the job and its grant; omitting the grant removes it")
    func rescheduleReplacesAndRemoves() async throws {
        let f = try JobGrantResolveTests.fixture(); defer { f.tearDown() }
        let (store, state, engine, conversation) = try engineHarness()
        func schedule(_ extra: [String: JSONValue]) async -> String {
            var args: [String: JSONValue] = ["prompt": .string("deploy it"), "name": .string("deploy"),
                                             "intervalSeconds": .int(3600), "profile": .string("mutating")]
            for (k, v) in extra { args[k] = v }
            return await engine.scheduleJob(ScheduleJobArguments.parse(args), conversationId: conversation,
                                            sandboxAvailable: true, paths: f.paths, home: f.home)
        }
        let first = await schedule(["mounts": .string(f.proj.path)])
        #expect(first.contains("Scheduled 'deploy'") && first.contains("Grant: read-write"))
        let original = try #require(try store.ledger.jobs().first)
        #expect(original.policy.grants?.mounts.count == 1)

        let second = await schedule(["mounts": .array([.string(f.proj.path), .string("\(f.creds.path):ro")]), "network": .bool(true)])
        let jobs = try store.ledger.jobs()
        #expect(jobs.count == 1, "replaced, not suffixed to deploy-2")
        #expect(jobs[0].id == original.id && jobs[0].createdAt == original.createdAt)
        #expect(jobs[0].policy.grants == JobGrant(mounts: [ContainerMount(source: canonical(f.proj)),
                                                           ContainerMount(source: canonical(f.creds), readOnly: true)], network: true))
        #expect(second.contains(ScheduleJobArguments.replacedNote("deploy")))

        let third = await schedule([:])
        #expect(try store.ledger.jobs().first?.policy.grants == nil, "omitting mounts and network removes the grant")
        #expect(!third.contains("Grant:"))

        // A different conversation asking for the same name still gets a suffix — the name is
        // that conversation's, and a replacement must not reach across.
        let other = state.createNewConversation()
        _ = await engine.scheduleJob(ScheduleJobArguments.parse(["prompt": .string("x"), "name": .string("deploy"),
                                                                 "intervalSeconds": .int(60)]),
                                     conversationId: other, sandboxAvailable: true)
        #expect(Set(try store.ledger.jobs().map(\.name)) == ["deploy", "deploy-2"])
    }
}
```

`RegisterWatcherTests` — `fixture()` (:37-50) gains `executor.mutatingJobsAvailable = { true }` and a parameter `mutatingJobsAvailable: Bool = true` to drive the refusal; add:
```swift
    @Test("a watch takes profile, mounts and network; a grant on a read-only watch is refused; the watched folder is not implicitly granted")
    func watchGrant() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let out = f.base.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let refused = await f.register(["mounts": .string(out.path)])
        #expect(refused == "Not watching \(IrisPaths.canonicalPath(f.notes.path)): mounts: \(JobGrant.grantNeedsMutating)")
        #expect(try f.store.ledger.jobs().isEmpty)

        let conversation = UUID()
        let result = await f.register(["profile": .string("mutating"), "mounts": .string(out.path), "network": .bool(true)],
                                      conversationId: conversation)
        let (job, _) = try f.watch()
        #expect(job.profile == .mutating)
        #expect(job.policy.grants == JobGrant(mounts: [ContainerMount(source: IrisPaths.canonicalPath(out.path))], network: true))
        #expect(job.policy.grants?.mounts.map(\.source).contains(IrisPaths.canonicalPath(f.notes.path)) == false,
                "the watched folder is not in the grant unless named")
        #expect(result.hasSuffix(" Grant: read-write \(IrisPaths.canonicalPath(out.path)) (working directory) · network on."))

        // Re-registering from the same conversation without mounts removes the grant and keeps the profile.
        _ = await f.register([:], conversationId: conversation)
        let again = try f.watch().job
        #expect(again.id == job.id && again.profile == .mutating && again.policy.grants == nil)
    }

    @Test("a mutating watch needs the VM, exactly as a mutating job does")
    func mutatingWatchNeedsSandbox() async throws {
        let f = try fixture(mutatingJobsAvailable: false); defer { f.tearDown() }
        let result = await f.register(["profile": .string("mutating")])
        #expect(result == ToolExecutor.watchProfileNeedsSandbox)
        #expect(try f.store.ledger.jobs().isEmpty)
    }
```
`ToolSurfaceTrimTests.descriptionsStateTriggers` (:96-127) — after the `schedule_job` block:
```swift
        #expect(job.contains("unless the job was created with a grant that covers it"))
        #expect(!job.contains("stops and says so."), "the old absolute sentence is gone")
```

What turns each red once green: `scheduleJobArguments` — dropping a malformed `network` instead of refusing; `makeJobStoresGrant` — resolving the grant after `alias.resolve` (the read-only refusal would become "Give a schedule"), prefixing the network-only refusal, or the H1 guard; `rescheduleReplacesAndRemoves` — falling back to `uniqueName` for a same-conversation explicit name, or keeping the old grant when `mounts` is absent; `watchGrant` — keeping the old grant on re-registration or granting the watched folder implicitly; `mutatingWatchNeedsSandbox` — not consulting the seam; the trim test — Task 7's grep finding the stale sentence.

- [ ] **Step 2: Run to verify they fail** — `scripts/test-filter.sh JobGrantToolTests` and `scripts/test-filter.sh RegisterWatcherTests`; Expected: compile errors (`makeJob(... paths:home:)`, `mutatingJobsAvailable`).

- [ ] **Step 3: `ScheduleJobArguments`** — fields after `catchUp` (:41):
```swift
    /// The grant (#282 §0.1): `nil` is "none asked for". Not the same rule as the policy fields
    /// above — on a re-schedule an absent grant *removes* the stored one.
    let mounts: [String]?
    let network: Bool?
```
In `parse` (:76-80) call the now-internal `stringList(args["gate_mounts"], shape: Self.gateMountsShape)`; then add:
```swift
        let mounts: [String]?
        switch stringList(args["mounts"], shape: Self.mountsShape) {
        case .failure(let message): return .failure(message)
        case .success(let values): mounts = values
        }
        let network: Bool?
        switch boolean(args["network"]) {
        case .failure(let message): return .failure(message)
        case .success(let value): network = value
        }
```
and pass `mounts: mounts, network: network` into the memberwise init (:100-105). Beside `integer` (:409):
```swift
    static let networkShape: ToolMessage = "network must be true or false."
    static let mountsShape: ToolMessage = "mounts must be a directory path, or a list of them, each as '/host/dir', '/host/dir:ro' or '/host/dir:/path/in/container'."

    /// A Bool in the shapes a model sends one: a real Bool, or the words. Absent, null and the
    /// empty string read as "not asked"; anything else is a refusal, because a dropped `network`
    /// would silently attach a job to the wrong network for as long as it exists.
    static func boolean(_ value: JSONValue?) -> Result<Bool?, ToolMessage> {
        guard let value = given(value) else { return .success(nil) }
        switch value {
        case .bool(let flag): return .success(flag)
        case .string(let word):
            switch word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "on": return .success(true)
            case "false", "no", "off": return .success(false)
            default: return .failure(networkShape)
            }
        default: return .failure(networkShape)
        }
    }

    /// "mounts: …" when the call named mounts; a refusal earned by `network` alone is not about
    /// mounts and says nothing of them.
    static func grantRefusal(_ message: ToolMessage, mountsNamed: Bool) -> ToolMessage {
        mountsNamed ? ToolMessage("mounts: \(message.text)") : message
    }
```
`stringList` (:447-457): drop `private`, add `shape: ToolMessage`, replace both `Self.gateMountsShape` with `shape`.

`makeJob` (:124-158): signature gains `paths: IrisPaths = .default, home: String = NSHomeDirectory()`; after the `wantsMutating` refusal (:132) and **before** `resolvedGate`:
```swift
        let grant: JobGrant?
        switch JobGrant.resolve(mounts: mounts, network: network,
                                profile: wantsMutating ? .mutating : .readOnly,
                                fileManager: fileManager, paths: paths, home: home) {
        case .failure(let message):
            return .failure(Self.grantRefusal(message, mountsNamed: !(mounts ?? []).isEmpty))
        case .success(let resolved): grant = resolved
        }
```
and in the policy block (:147-149) `policy.grants = grant`. `resultSentence` (:347-358): `return ([sentence] + notes + [stored.policy.grants?.sentence].compactMap { $0 }).joined(separator: " ")`. Add:
```swift
    /// Said when a same-conversation `schedule_job` re-used an explicit name (§0.1).
    static func replacedNote(_ name: String) -> String {
        "This replaced '\(name)' from this conversation; its run history is kept."
    }
```

- [ ] **Step 4: `IrisEngine.scheduleJob`** (iris.swift:1956-2013) — signature gains `paths: IrisPaths = .default, home: String = NSHomeDirectory()`, forwarded to `makeJob`. Before the `for _ in 0..<2` loop:
```swift
        // §0.1: an explicit name that this conversation already used is a re-schedule, and a
        // re-schedule replaces — the schedule, the prompt, the profile and the grant alike. Another
        // conversation's job of that name is not ours to replace and still gets a suffix.
        var replacing: Job?
        if let name = args.name, let conversationId {
            let slug = Job.slug(from: name)
            replacing = ((try? ledger.jobs()) ?? []).first {
                $0.name == slug && $0.createdInConversationId == conversationId
            }
            if let replacing { taken.remove(replacing.name) }
        }
        var notes = args.notes
        if let replacing { notes.append(ScheduleJobArguments.replacedNote(replacing.name)) }
```
Inside `case .success(let job)`, before the review:
```swift
                var job = job
                if let replacing {
                    job = Job(id: replacing.id, name: job.name, prompt: job.prompt, trigger: job.trigger,
                              profile: job.profile, destinationConversationId: replacing.destinationConversationId,
                              createdInConversationId: replacing.createdInConversationId,
                              createdAt: replacing.createdAt, policy: job.policy)
                }
```
and pass `notes: notes` to `resultSentence`.

- [ ] **Step 5: `RegisterWatcherArguments`** — fields `let profile: String?; let mounts: [String]?; let network: Bool?`; in `parse`, after `overlap`:
```swift
        let mounts: [String]?
        switch ScheduleJobArguments.stringList(args["mounts"], shape: ScheduleJobArguments.mountsShape) {
        case .failure(let message): return .failure(ToolMessage("Error: " + message.text))
        case .success(let values): mounts = values
        }
        let network: Bool?
        switch ScheduleJobArguments.boolean(args["network"]) {
        case .failure(let message): return .failure(ToolMessage("Error: " + message.text))
        case .success(let value): network = value
        }
```
and `profile: ScheduleJobArguments.text(args["profile"])` in the init. Update the doc comment at :6-9: the grant is the exception to "nil means say nothing" (§0.1).

- [ ] **Step 6: `ToolExecutor`** — seam after `homeDirectory` (:28):
```swift
    /// Whether a `mutating` watch would get the VM its commands need (`SandboxPolicy.mutatingJobCanRun`).
    /// nil, the case in the app, asks the real policy when the tool runs; a test sets `{ true }`.
    var mutatingJobsAvailable: (@Sendable () -> Bool)?
    static let watchProfileNeedsSandbox = "A mutating watch's commands always run in the apple/container VM, and that VM is not available: install the runtime and turn sandboxing on in Settings → Sandboxing, or leave the watch read-only."
```
Declaration (:91-105) — three properties:
```swift
                    "profile": Schema(type: "STRING", description: "'readOnly' (default) or 'mutating'. A watch that writes must be mutating; its commands then run in the sandbox VM, which must be available."),
                    "mounts": Schema(type: "ARRAY", description: "Directories the watch's runs may use, as '/host/dir', '/host/dir:ro' or '/host/dir:/path/in/container'. Read-write unless ':ro'; the first read-write one is the working directory. Mutating only. The watched folder is not included unless named here.", items: Schema(type: "STRING")),
                    "network": Schema(type: "BOOLEAN", description: "true lets the runs' commands reach the network from inside the VM; default false. Mutating only.")
```
`registerWatcher` (:245-321): inside the `do`, after `watching` is computed and before the update/create branches:
```swift
            let existing = watching.first(where: { $0.createdInConversationId == conversationId })
            let asked = parsed.profile?.lowercased() == JobProfile.mutating.rawValue.lowercased() ? JobProfile.mutating
                : (parsed.profile == nil ? nil : JobProfile.readOnly)
            let profile = asked ?? existing?.profile ?? .readOnly
            if profile == .mutating, !(mutatingJobsAvailable?() ?? SandboxPolicy.mutatingJobCanRun()) {
                return Self.watchProfileNeedsSandbox
            }
            let grant: JobGrant?
            switch JobGrant.resolve(mounts: parsed.mounts, network: parsed.network, profile: profile,
                                    paths: irisPaths ?? .default, home: homeDirectory ?? NSHomeDirectory()) {
            case .failure(let message):
                return "Not watching \(path): \(ScheduleJobArguments.grantRefusal(message, mountsNamed: !(parsed.mounts ?? []).isEmpty).text)"
            case .success(let resolved): grant = resolved
            }
```
In the update branch add `existing.profile = profile` and `existing.policy.grants = grant` (replaced, never kept — §0.1); in the create branch pass `profile: profile` and `policy: { var p = JobPolicy(overlap: parsed.overlap ?? .queue); p.grants = grant; return p }()`. After the clamp sentence: `if let grant = job.policy.grants { sentences.append(grant.sentence) }`.

- [ ] **Step 7: `schedule_job` declaration** (iris.swift:1204, 1207-1227) — replace `so a job whose work needs approval stops and says so.` with `so a job whose work needs approval stops and says so, unless the job was created with a grant that covers it (mounts and network, below).`; add after `catch_up`:
```swift
                    "mounts": Schema(type: "ARRAY", description: "Directories the job may use, as '/host/dir', '/host/dir:ro' or '/host/dir:/path/in/container'. Read-write unless ':ro'. The first read-write one is the job's working directory. Mutating jobs only. Recorded as the directory each path resolves to; the whole filesystem, the home directory, volume roots and Iris's own directory cannot be mounted.", items: Schema(type: "STRING")),
                    "network": Schema(type: "BOOLEAN", description: "true lets the job's commands reach the network from inside the VM; default false, which attaches the VM to a host-only network. Mutating jobs only.")
```
Invariant 6: both tools remain declared only inside `if !isUnattended` (:1201) / removed for unattended turns (:1168).

- [ ] **Step 8: Run to verify they pass** — `scripts/test-filter.sh JobGrantToolTests`, `scripts/test-filter.sh RegisterWatcherTests`, `scripts/test-filter.sh ToolSurfaceTrimTests`, `scripts/test-filter.sh ScheduleJobArgumentsTests`, `scripts/test-filter.sh GateCreationTests`, `scripts/test-filter.sh SelfWriteHookTests` (no tool names changed). Expected: PASS with counts.

- [ ] **Step 9: Full suite and commit**
```bash
swift test; echo exit=$?
git add Sources/iris/ScheduleJobArguments.swift Sources/iris/RegisterWatcherArguments.swift Sources/iris/ToolExecutor.swift Sources/iris/iris.swift Tests/irisTests/JobGrantTests.swift Tests/irisTests/RegisterWatcherTests.swift Tests/irisTests/ToolSurfaceTrimTests.swift
git commit -m "feat(jobs): schedule_job and register_directory_watcher take mounts and network; replace-by-name from the same conversation, remove-on-omit, the declarations (#282)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 3a: `Conversation.sandboxGrant`, migration v12, subagents inherit **[§2 lifecycle]**

**Files:**
- Modify: `Sources/iris/AppState.swift:73-175` (`Conversation`: field, `CodingKeys`, `init(from:)`), after `:1006-1011` (`setSandboxGrant(for:_:)`)
- Modify: `Sources/iris/ConversationStore.swift:443-463` (register `v12_sandbox_grant` after `v11_watches`), `:672-696` (both upsert statements), `:870-873` and after `:929` (read as supplementary)
- Modify: `Sources/iris/SubagentManager.swift:57-64` (inherit `sandboxGrant`)
- Test: `Tests/irisTests/ConversationStoreTests.swift` (two cases beside `v2DatabaseMigratesToV3` :185-215), `Tests/irisTests/SandboxGrantConversationTests.swift` (new)

**Interfaces:**
- Consumes: `JobGrant` (Task 1); `AppState.setWorkspace(for:path:)` (AppState.swift:997), `markChanged` (:2519); `ConversationStore.supplementary(_:)`/`localSoftLosses` idiom (:860-873, :926-929); `SubagentManager.runSubagent(role:task:effort:parentConversationId:unit:maxIterations:client:appState:recentWrites:)` (SubagentManager.swift:37-41).
- Produces:

```swift
// Conversation
var sandboxGrant: JobGrant?          // nil on every conversation that is not a granted run; decodeIfPresent; column `sandboxGrant TEXT`
// AppState
func setSandboxGrant(for conversationId: UUID, _ grant: JobGrant?)   // markChanged(.metadata)
```

- [ ] **Step 1: Write the failing tests** — `Tests/irisTests/SandboxGrantConversationTests.swift`

```swift
import Testing
import Foundation
@testable import iris

/// #282 §2 — the grant lives on the run's conversation and follows a delegation. In-memory store,
/// injected `RecentWrites`, a fake client: nothing here reaches a singleton or the disk beyond a temp dir.
@MainActor
@Suite("sandboxGrant on the conversation (#282)")
struct SandboxGrantConversationTests {
    private func textResponse(_ text: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: nil)
    }

    @Test("setSandboxGrant stamps and clears, and marks the conversation changed")
    func setAndClear() throws {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let id = state.createNewConversation(isBackground: true, select: false)
        let grant = JobGrant(mounts: [ContainerMount(source: "/p")], network: true)
        state.setSandboxGrant(for: id, grant)
        #expect(state.conversations.first { $0.id == id }?.sandboxGrant == grant)
        state.flushSave()
        #expect(try store.loadAll().conversations.first { $0.id == id }?.sandboxGrant == grant)
        state.setSandboxGrant(for: id, nil)
        #expect(state.conversations.first { $0.id == id }?.sandboxGrant == nil)
    }

    @Test("a subagent a granted run delegates into inherits the grant with the workspace and the background flag")
    func subagentInheritsTheGrant() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-grantsub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let parent = state.createNewConversation(isBackground: true, select: false)
        let grant = JobGrant(mounts: [ContainerMount(source: IrisPaths.canonicalPath(dir.path))], network: true)
        state.setWorkspace(for: parent, path: IrisPaths.canonicalPath(dir.path))
        state.setSandboxGrant(for: parent, grant)

        _ = await SubagentManager.shared.runSubagent(role: "helper", task: "say hi", effort: "easy",
                                                     parentConversationId: parent, maxIterations: 5,
                                                     client: FakeLLMClient(responses: [textResponse("hi")]),
                                                     appState: state, recentWrites: RecentWrites())

        let child = try #require(state.conversations.first { $0.isSubagent })
        #expect(child.isBackground)
        #expect(child.workspacePath == IrisPaths.canonicalPath(dir.path))
        #expect(child.sandboxGrant == grant)
    }
}
```
`AppState.flushSave()` (AppState.swift:2642) is internal and applies the pending batch synchronously (`try store.apply(batch)` at :2651), so the round trip through the column is asserted in place.

`ConversationStoreTests` — add:
```swift
    @Test("v12 adds sandboxGrant; a row without it, and one whose blob will not parse, both load with nil")
    func v12SandboxGrantIsLenient() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-convstore-v11-\(UUID().uuidString)")
        let url = root.appendingPathComponent("conversations.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        do {
            let queue = try DatabaseQueue(path: url.path)
            try ConversationStore.migrator.migrate(queue, upTo: "v11_watches")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO conversations (id, position, title, createdAt, updatedAt, tokenUsage)
                    VALUES (?, 1, 'old chat', datetime('now'), datetime('now'), ?)
                    """, arguments: [id.uuidString, String(decoding: try JSONEncoder().encode(TokenUsage()), as: UTF8.self)])
            }
            try queue.close()
        }
        let store = try ConversationStore.onDisk(at: url)
        var back = try #require(try store.loadAll().conversations.first)
        #expect(back.sandboxGrant == nil)

        back.sandboxGrant = JobGrant(mounts: [ContainerMount(source: "/p"), ContainerMount(source: "/q", readOnly: true)], network: true)
        try store.apply([write(back, .metadata)])
        #expect(try store.loadAll().conversations.first?.sandboxGrant == back.sandboxGrant)

        try store.writer.write { db in
            try db.execute(sql: "UPDATE conversations SET sandboxGrant = 'junk' WHERE id = ?", arguments: [id.uuidString])
        }
        let loaded = try store.loadAll()
        #expect(loaded.conversations.first?.sandboxGrant == nil, "an unreadable grant is no grant")
        #expect(loaded.conversations.count == 1, "and the conversation is kept")
    }

    @Test("Conversation JSON without sandboxGrant decodes (invariant 1)")
    func conversationDecodesWithoutSandboxGrant() throws {
        let data = Data(#"{"id":"\#(UUID().uuidString)","title":"t"}"#.utf8)
        #expect(try JSONDecoder().decode(Conversation.self, from: data).sandboxGrant == nil)
    }
```
Red once green if: the column is missing from the read or either write; a bad blob drops the row; `init(from:)` uses `decode`; `SubagentManager` does not copy `sandboxGrant`.

- [ ] **Step 2: Run to verify they fail** — `scripts/test-filter.sh SandboxGrantConversationTests`; Expected: compile error `no member 'sandboxGrant'`.

- [ ] **Step 3: `Conversation.sandboxGrant` and `AppState.setSandboxGrant`** — AppState.swift. After `jobProfile` (:100):
```swift
    /// #282 — the grant of the job whose run this background conversation holds: the directories
    /// its host file tools may use unattended and its container mounts, and its network bit.
    /// Stamped by `JobRunner.openConversation`, inherited by the subagents a run delegates into,
    /// `nil` everywhere else — and `nil` is "no grant", which is the narrow answer.
    var sandboxGrant: JobGrant?
```
`CodingKeys` (:134) gains `sandboxGrant`; `init(from:)` after `jobProfile` (:155): `sandboxGrant = try container.decodeIfPresent(JobGrant.self, forKey: .sandboxGrant)`. After `setJobProfile` (:1011):
```swift
    /// Stamps a run's grant on its conversation (#282). Persisted, so a transcript reopened after
    /// a relaunch still says what the run was allowed to touch.
    func setSandboxGrant(for conversationId: UUID, _ grant: JobGrant?) {
        if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[idx].sandboxGrant = grant
            markChanged(conversationId, .metadata)
        }
    }
```

- [ ] **Step 4: Migration v12 and the column** — ConversationStore.swift. After `v11_watches` (:462):
```swift
        // #282: the grant of the job whose run a background conversation holds. One JSON column,
        // NULL for every conversation that is not a granted run; an unreadable blob reads as nil,
        // which is "no grant" — the narrow direction — and never costs the row.
        m.registerMigration("v12_sandbox_grant") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "sandboxGrant", .text)
            }
        }
```
In the upsert (:661-696): `let grant = try c.sandboxGrant.map { try json($0, encoder) }`; UPDATE gains `, sandboxGrant = ?` after `jobProfile = ?` with `grant` inserted before `c.id.uuidString`; INSERT gains the column, one more `?`, and `grant` last. Read side, beside `subagentResult` (:870): `let sandboxGrant = supplementary("sandboxGrant")`, and after the `subagentResult` decode block (:926-929):
```swift
                // #282 — supplementary like `subagentResult`: a grant this build cannot read is no
                // grant, which is the narrow answer, and the conversation is kept.
                if let s = sandboxGrant {
                    do { c.sandboxGrant = try decoder.decode(JobGrant.self, from: Data(s.utf8)) }
                    catch { localSoftLosses.append(("sandboxGrant", "\(error)")) }
                }
```

- [ ] **Step 5: `SubagentManager.runSubagent`** (:62-64) — after the workspace copy:
```swift
            // A granted run's delegate works under the same grant, never wider (#282 §2): the same
            // mounts, the same network, the same host-write boundary.
            if let parentGrant = appState.conversations.first(where: { $0.id == parentConversationId })?.sandboxGrant {
                appState.setSandboxGrant(for: subagentId, parentGrant)
            }
```

- [ ] **Step 6: Run to verify they pass** — `scripts/test-filter.sh SandboxGrantConversationTests`, `scripts/test-filter.sh ConversationStoreTests`, `scripts/test-filter.sh SubagentManagerTests`, `scripts/test-filter.sh BackgroundDescendantTests`. Expected: PASS with counts.

- [ ] **Step 7: Full suite and commit**
```bash
swift test; echo exit=$?
git add Sources/iris/AppState.swift Sources/iris/ConversationStore.swift Sources/iris/SubagentManager.swift Tests/irisTests/SandboxGrantConversationTests.swift Tests/irisTests/ConversationStoreTests.swift
git commit -m "feat(jobs): Conversation.sandboxGrant with migration v12, read leniently; a delegated subagent inherits its parent's grant (#282)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 3b: The runner — stamp, drift, the network pre-check, `endSession`, Approve-and-run **[§2, §0.6, §0.8, §0.7]**

**Files:**
- Modify: `Sources/iris/JobGrant.swift` (`drift`)
- Modify: `Sources/iris/JobRunner.swift:109-135` (init: `endSandboxSession`, `ensureIsolatedNetwork` — declared **immediately after `ledger:`**, see M2), `:803-811` (`run` opens with the grant), after `:860-864` (drift + network before the turn), `:1143-1182` (`runApproved`: drift + network, opens with the grant), `:1368-1390` (`openConversation`), `:1412-1413` (the two new reasons), `:1464-1467` (`closeSession`)
- Modify: every `JobRunner(` construction in `Tests/irisTests/` (84 sites, counted 2026-09-23 with `grep -c "JobRunner(state"` plus the one multi-line form: ApproveAndRunTests 17, BackgroundDescendantTests 1, CatchUpTests 2, GateEvaluatorTests 11, JobAdmissionTests 27 — 26 single-line and the multi-line one at :501 —, JobProfileTests 2, JobRetryTests 13, JobRunnerTests 9, TurnBudgetTests 2) gains `endSandboxSession: { _ in }` — M2
- Test: `Tests/irisTests/JobRunnerGrantTests.swift` (new), `Tests/irisTests/JobRunnerTests.swift` (`completedRunEndToEnd` :156-224 gains one assertion)

**Interfaces:**
- Consumes: `Conversation.sandboxGrant`, `AppState.setSandboxGrant` (Task 3a); `JobGrant`, `JobPolicy.grants` (Task 1); `AppState.setWorkspace` (:997), `setJobProfile` (:1006), `createNewConversation` (:805), `registerSubagent` (:872), `finishSession` (:882); `JobRunner.closeFailed` (:1419), `retryDecision` (:1307), `retriesExhaustedReason` (:1289), `backoff` (:1285), `refuse(_:for:)` (:1236), `ApprovalOutcome` (:1069-1072); `GateEvaluator.mountDrift`'s rule (:411-426), re-expressed with the grant's sentence.
- Produces:

```swift
// JobGrant
static func drift(_ grant: JobGrant, fileManager: FileManager = .default) -> String?   // "grant source unavailable: <path>" or nil
// JobRunner
init(state: AppState, engine: IrisEngine, ledger: JobLedger,
     endSandboxSession: (@Sendable (UUID) async -> Void)? = nil,          // nil → SandboxSessionManager.shared.endSession
     ensureIsolatedNetwork: (@Sendable () async -> String?)? = nil,       // nil → { nil } here; Task 4b installs the real check. Returns the failure detail, nil on success.
     now:, calendar:, config:, protectionEnabled:, activity:, usageSource:, sandboxAvailable:, gateEvaluator:, lastGateSignal:, watchdogSlice:)
static func grantSourceUnavailableReason(_ path: String) -> String        // "grant source unavailable: \(path)"
static func isolatedNetworkUnavailableReason(_ detail: String) -> String  // "isolated network unavailable: \(detail)"
private func openConversation(for job: Job, titled: String, sandboxed: Bool, grant: JobGrant?) async -> UUID?
private func closeSession(_ conversationId: UUID, status: String) async   // now also awaits endSandboxSession(conversationId)
```

Two placements argued here. **M2:** the two new parameters sit right after `ledger:` so the 83 existing constructions can gain `endSandboxSession: { _ in }` by one mechanical insertion after `ledger: <expr>` (labelled arguments must follow declaration order); without it every existing runner test would call `SandboxSessionManager.shared.endSession` on close — a dictionary removal, no CLI spawn, but the plan's invariant-7 restatement says no test touches that singleton, so the tests stay off it. **L5:** the runner keeps a network pre-check *and* Task 4b adds one at container create. Both stay, because they answer different things: the runner's is what puts `isolated network unavailable: <detail>` on the **row** (§0.7 "the fire fails closed with the reason on the row", §5 lists it as a fire-time reason) — without it the failure would be a tool-result string inside a turn that may still end `completed`; the create-time one is what keeps a container recreated mid-turn (idle-reaped, or an approved call's) isolated. The cost is one `network ls` per granted fire on top of the create's.

- [ ] **Step 1: Write the failing tests** — `Tests/irisTests/JobRunnerGrantTests.swift`

```swift
import Testing
import Foundation
@testable import iris

/// #282 §2 — what a granted fire does before its turn: stamps the hidden conversation, checks the
/// disk and the network, and ends its container when it is over. Every runtime touch is injected;
/// nothing here starts a container or reaches `SandboxSessionManager.shared` (invariant 7).
@MainActor
@Suite("JobRunner with a grant (#282)")
struct JobRunnerGrantTests {
    private func textResponse(_ text: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: nil)
    }

    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-grantrun-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private func harness(_ responses: [GeminiResponse]) throws -> (ConversationStore, AppState, IrisEngine) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        let user = UUID()
        state.createNewConversation(id: user)
        state.selectedConversationId = user
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: responses),
                                protectionEnabled: false, sessionPeerCount: 0)
        return (store, state, engine)
    }

    private func tempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-grantrun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func grantedJob(_ dir: URL, network: Bool = false, name: String = "deploy",
                            profile: JobProfile = .mutating) -> Job {
        var policy = JobPolicy()
        policy.grants = JobGrant(mounts: [ContainerMount(source: IrisPaths.canonicalPath(dir.path))], network: network)
        return Job(name: name, prompt: "Do it.", trigger: .schedule(.interval(seconds: 60)),
                   profile: profile, policy: policy)
    }

    /// Records which conversations had their session ended.
    private final class Ended: @unchecked Sendable {
        private let lock = NSLock(); private var ids: [UUID] = []
        func add(_ id: UUID) { lock.withLock { ids.append(id) } }
        var all: [UUID] { lock.withLock { ids } }
    }

    private func runner(_ state: AppState, _ engine: IrisEngine, _ store: ConversationStore, config: ConfigManager,
                        now: (@Sendable () -> Date)? = nil, ended: Ended? = nil,
                        network: @escaping @Sendable () async -> String? = { nil }) -> JobRunner {
        JobRunner(state: state, engine: engine, ledger: store.ledger,
                  endSandboxSession: { ended?.add($0) }, ensureIsolatedNetwork: network,
                  now: now ?? Date.init, config: config, sandboxAvailable: { true })
    }

    @Test("the fire stamps the working directory, the grant and the sandbox pin on the hidden conversation")
    func fireStampsWorkspaceGrantAndPin() async throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let (store, state, engine) = try harness([textResponse("done")])
        let job = grantedJob(dir)
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig(); defer { teardown() }
        await runner(state, engine, store, config: config).fire(job: job, origin: .schedule)

        let background = try #require(state.conversations.first { $0.isBackground })
        #expect(background.workspacePath == IrisPaths.canonicalPath(dir.path))
        #expect(background.sandboxGrant == job.policy.grants)
        #expect(background.mainAgentSandbox == .sandboxed)
        #expect(background.jobProfile == .mutating)
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.status == .completed)
    }

    @Test("an ungranted mutating job still gets no workspace and no grant, and never asks for the isolated network")
    func ungrantedFireIsUnchanged() async throws {
        let (store, state, engine) = try harness([textResponse("done")])
        let job = Job(name: "plain", prompt: "p", trigger: .schedule(.interval(seconds: 60)), profile: .mutating)
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig(); defer { teardown() }
        await runner(state, engine, store, config: config, network: { "must not be asked" }).fire(job: job, origin: .schedule)
        let background = try #require(state.conversations.first { $0.isBackground })
        #expect(background.workspacePath == nil && background.sandboxGrant == nil)
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.status == .completed)
    }

    @Test("a hand-edited read-only row carrying a grant is run ungranted: no workspace, no grant, no drift check (L1)")
    func readOnlyRowWithAGrantIsNotStamped() async throws {
        let dir = try tempDirectory()
        let (store, state, engine) = try harness([textResponse("done")])
        let job = grantedJob(dir, profile: .readOnly)
        try store.ledger.upsert(job)
        try FileManager.default.removeItem(at: dir)     // would be drift, if the grant were honoured
        let (config, teardown) = isolatedConfig(); defer { teardown() }
        await runner(state, engine, store, config: config, network: { "must not be asked" }).fire(job: job, origin: .schedule)
        let background = try #require(state.conversations.first { $0.isBackground })
        #expect(background.workspacePath == nil && background.sandboxGrant == nil && background.mainAgentSandbox == nil)
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.status == .completed)
    }

    @Test("a source that moved fails the fire with the exact reason and walks the retry ladder to a pause")
    func driftFailsAndWalksTheLadder() async throws {
        let dir = try tempDirectory()
        let (store, state, engine) = try harness([textResponse("never reached")])
        let job = grantedJob(dir)
        try store.ledger.upsert(job)
        try FileManager.default.removeItem(at: dir)          // the grant was made on a directory that is now gone
        let (config, teardown) = isolatedConfig(); defer { teardown() }
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let r = runner(state, engine, store, config: config, now: { clock })
        let expected = JobRunner.grantSourceUnavailableReason(IrisPaths.canonicalPath(dir.path))
        #expect(expected == "grant source unavailable: \(IrisPaths.canonicalPath(dir.path))")

        for attempt in 0..<JobRunner.backoff.count {
            await r.fire(job: try #require(try store.ledger.job(id: job.id)), origin: .schedule)
            let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
            #expect(run.status == .failed && run.failureReason == expected)
            let stored = try #require(try store.ledger.job(id: job.id))
            #expect(stored.retryAttempt == attempt + 1)
            #expect(stored.nextFireAt == clock.addingTimeInterval(JobRunner.backoff[attempt]))
            #expect(stored.pausedReason == nil)
        }
        // The ladder as it exists: three retries, and the fourth consecutive failure pauses.
        await r.fire(job: try #require(try store.ledger.job(id: job.id)), origin: .schedule)
        #expect(try store.ledger.job(id: job.id)?.pausedReason == JobRunner.retriesExhaustedReason)
        #expect(state.conversations.filter { $0.isBackground }.count == JobRunner.backoff.count + 1)
    }

    @Test("a symlink swapped under a source is drift too, and a source that became a file is drift")
    func driftRules() throws {
        let real = try tempDirectory(); defer { try? FileManager.default.removeItem(at: real) }
        let link = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-grantlink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(JobGrant.drift(JobGrant(mounts: [ContainerMount(source: link.path)]))
                == JobRunner.grantSourceUnavailableReason(link.path))
        #expect(JobGrant.drift(JobGrant(mounts: [ContainerMount(source: IrisPaths.canonicalPath(real.path))])) == nil)
        let file = real.appendingPathComponent("f"); try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(JobGrant.drift(JobGrant(mounts: [ContainerMount(source: IrisPaths.canonicalPath(file.path))]))
                == JobRunner.grantSourceUnavailableReason(IrisPaths.canonicalPath(file.path)))
        #expect(JobGrant.drift(JobGrant(network: true)) == nil, "no mounts, nothing to drift")
    }

    @Test("an isolated network that cannot be created fails the fire closed with the detail on the row")
    func networkFailureFailsClosed() async throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let (store, state, engine) = try harness([textResponse("never reached")])
        let job = grantedJob(dir, network: false)
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig(); defer { teardown() }
        let r = runner(state, engine, store, config: config, network: { "network create exited 1: permission denied" })
        await r.fire(job: job, origin: .schedule)
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .failed)
        #expect(run.failureReason == "isolated network unavailable: network create exited 1: permission denied")
        #expect(try store.ledger.job(id: job.id)?.retryAttempt == 1, "the same ladder as any failure")

        // network: true never asks for the isolated network.
        let open = grantedJob(dir, network: true, name: "open")
        try store.ledger.upsert(open)
        await r.fire(job: open, origin: .schedule)
        #expect(try store.ledger.runs(jobId: open.id, limit: 1).first?.status == .completed)
    }

    @Test("the run's container is ended when the run closes — on completion and on a refused fire")
    func endSessionAtClose() async throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let (store, state, engine) = try harness([textResponse("done")])
        let job = grantedJob(dir)
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig(); defer { teardown() }
        let ended = Ended()
        let r = runner(state, engine, store, config: config, ended: ended)
        await r.fire(job: job, origin: .schedule)
        let first = try #require(state.conversations.first { $0.isBackground })
        #expect(ended.all == [first.id])
        try FileManager.default.removeItem(at: dir)
        await r.fire(job: job, origin: .schedule)
        #expect(ended.all.count == 2, "a fire refused before its turn ends the session it opened too")
    }

    @Test("Approve and run reopens with the same grant, ends its session, and drift refuses the click without spending the approval")
    func approvedCallReopensWithTheGrant() async throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let (store, state, engine) = try harness([])
        let job = grantedJob(dir)
        try store.ledger.upsert(job)
        let target = dir.appendingPathComponent("out.md").path
        let call = BlockedCall(toolName: "write_file", args: ["path": .string(target), "content": .string("hi")],
                               cwd: IrisPaths.canonicalPath(dir.path))
        func blocked(at seconds: TimeInterval) throws -> JobRun {
            let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                             startedAt: Date(timeIntervalSince1970: seconds), transcriptConversationId: nil)
            try store.ledger.begin(run: run)
            try store.ledger.finish(runId: run.id, status: .blockedOnApproval, outcome: nil,
                                    failureReason: "needs approval: write_file", blockedTool: "write_file",
                                    tokens: TokenUsage(), finishedAt: Date(timeIntervalSince1970: seconds + 1))
            try store.ledger.setBlockedCall(runId: run.id, call)
            return run
        }
        let first = try blocked(at: 1_700_000_000)
        let (config, teardown) = isolatedConfig(); defer { teardown() }
        let ended = Ended()
        let r = runner(state, engine, store, config: config, ended: ended)

        let outcome = await r.runApproved(runId: first.id)
        guard case .dispatched(let approvedId) = outcome else { Issue.record("\(outcome)"); return }
        let approved = try #require(state.conversations.first { $0.isBackground && $0.title.contains("approved") })
        #expect(approved.sandboxGrant == job.policy.grants)
        #expect(approved.workspacePath == IrisPaths.canonicalPath(dir.path))
        #expect(approved.mainAgentSandbox == .sandboxed)
        #expect(try store.ledger.run(id: approvedId)?.status == .completed)
        #expect(FileManager.default.fileExists(atPath: target), "the approved write landed on the host")
        #expect(ended.all == [approved.id])

        let again = try blocked(at: 1_700_000_100)
        try FileManager.default.removeItem(at: dir)
        let refused = await r.runApproved(runId: again.id)
        #expect(refused == .refused(JobRunner.grantSourceUnavailableReason(IrisPaths.canonicalPath(dir.path))))
        #expect(try store.ledger.run(id: again.id)?.approvedAt == nil)
    }
}
```

What turns each red once green: `fireStampsWorkspaceGrantAndPin` — `openConversation` not calling `setWorkspace`/`setSandboxGrant`; `ungrantedFireIsUnchanged` — asking the network closure for an ungranted job; `readOnlyRowWithAGrantIsNotStamped` — passing `job.policy.grants` without the profile guard (L1); `driftFailsAndWalksTheLadder` — skipping `JobGrant.drift` in `run`, or closing the row `interrupted`; `driftRules` — comparing the spelling; `networkFailureFailsClosed` — ignoring the closure's detail or asking it for `network: true`; `endSessionAtClose` — `closeSession` not awaiting `endSandboxSession`; `approvedCallReopensWithTheGrant` — `runApproved` opening without the grant or marking approved before the drift check.

`JobRunnerTests.completedRunEndToEnd` (:174) — after the `mainAgentSandbox == nil` line add `#expect(background.sandboxGrant == nil && background.workspacePath == nil, "a readOnly job has no grant and no workspace")`.

- [ ] **Step 2: Run to verify they fail** — `scripts/test-filter.sh JobRunnerGrantTests`; Expected: compile errors (`endSandboxSession:`, `JobGrant.drift`).

- [ ] **Step 3: `JobGrant.drift`** — append to `Sources/iris/JobGrant.swift`
```swift
extension JobGrant {
    /// Why this grant cannot be honoured *now*, or nil (spec §0.8): every source must still
    /// canonicalise to itself and be a directory — `GateEvaluator.mountDrift`'s rule, with the
    /// grant's sentence. The stored source is already canonical, so any difference is a change made
    /// since the grant was given.
    static func drift(_ grant: JobGrant, fileManager: FileManager = .default) -> String? {
        for mount in grant.mounts {
            guard IrisPaths.canonicalPath(mount.source) == mount.source else {
                return JobRunner.grantSourceUnavailableReason(mount.source)
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: mount.source, isDirectory: &isDirectory), isDirectory.boolValue else {
                return JobRunner.grantSourceUnavailableReason(mount.source)
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: `JobRunner`** — init (:109-135): the two new parameters go **directly after `ledger:`**:
```swift
    init(state: AppState, engine: IrisEngine, ledger: JobLedger,
         endSandboxSession: (@Sendable (UUID) async -> Void)? = nil,
         ensureIsolatedNetwork: (@Sendable () async -> String?)? = nil,
         now: @escaping @Sendable () -> Date = Date.init,
         …
         watchdogSlice: TimeInterval = JobRunner.defaultWatchdogSlice) {
        …
        self.endSandboxSession = endSandboxSession ?? { await SandboxSessionManager.shared.endSession($0) }
        self.ensureIsolatedNetwork = ensureIsolatedNetwork ?? { nil }   // Task 4b installs the real network check
```
with two stored `let`s. Reasons beside `sandboxUnavailableReason` (:1413):
```swift
    /// A granted fire whose source moved, or is no longer a directory (§0.8). Read back by `/jobs`.
    static func grantSourceUnavailableReason(_ path: String) -> String { "grant source unavailable: \(path)" }
    /// A `network: false` fire whose host-only network could not be created (§0.7).
    static func isolatedNetworkUnavailableReason(_ detail: String) -> String { "isolated network unavailable: \(detail)" }
```
`openConversation` (:1368-1390) gains `grant: JobGrant?`; after `setJobProfile`:
```swift
            // §0.6, §2: the first read-write mount is the run's working directory — it feeds `-w`,
            // relative paths in `write_file`, the AGENTS.md loader and the per-workspace sandbox
            // file — and the grant itself is what the approval gate and the executor read.
            if let grant {
                if let workingDirectory = grant.workingDirectory { state.setWorkspace(for: id, path: workingDirectory) }
                state.setSandboxGrant(for: id, grant)
            }
```
`run` (:803-811): first line `let grant = job.profile == .mutating ? job.policy.grants : nil` (L1 — a grant on a read-only row is inert: never stamped, never checked); open with `grant: grant`. After the R12 block (:860-864):
```swift
        // §0.8: the grant is a claim about the disk made once, and the disk moves. Asked before
        // the container exists; a miss is a failed row on the ordinary ladder.
        if let grant {
            if let drift = JobGrant.drift(grant) {
                await closeFailed(run: run, job: job, origin: origin, conversationId: conversationId,
                                  reason: drift, at: now(), note: note)
                return
            }
            // §0.7: "network off" is a network that has to exist. This is the check that puts the
            // reason on the row; the session manager asks again at create so a container rebuilt
            // mid-turn is isolated too.
            if !grant.network, let detail = await ensureIsolatedNetwork() {
                await closeFailed(run: run, job: job, origin: origin, conversationId: conversationId,
                                  reason: Self.isolatedNetworkUnavailableReason(detail), at: now(), note: note)
                return
            }
        }
```
`runApproved` (:1153-1164, after the profile block and before `markApproved`):
```swift
        // §0.8 again, at click time: the grant is re-checked before the approval is spent.
        let grant = job.profile == .mutating ? job.policy.grants : nil
        if let grant {
            if let drift = JobGrant.drift(grant) { return await refuse(drift, for: job) }
            if !grant.network, let detail = await ensureIsolatedNetwork() {
                return await refuse(Self.isolatedNetworkUnavailableReason(detail), for: job)
            }
        }
```
and (:1179-1182) `openConversation(for: job, titled: …, sandboxed: …, grant: grant)`. `closeSession` (:1464-1467):
```swift
    private func closeSession(_ conversationId: UUID, status: String) async {
        // The run's container goes with the run (§2): before this, a job's container stood until
        // the idle reaper or the next launch's sweep, holding its mounts open the whole time.
        await endSandboxSession(conversationId)
        guard let state else { return }
        await MainActor.run { state.finishSession(id: conversationId, status: status) }
    }
```

- [ ] **Step 5: M2 — keep the existing runner tests off `SandboxSessionManager.shared`.** Every `JobRunner(` construction in `Tests/irisTests` passes `ledger: <expr>` third; 83 are on one line and one — `JobAdmissionTests.swift:501`, `JobRunner(` then a newline before `state:` — spans lines, which is why the pattern allows whitespace after the paren:
```bash
perl -0pi -e 's/(JobRunner\(\s*state:\s*[^,]+,\s*engine:\s*[^,]+,\s*ledger:\s*[^,\)\n]+)/$1, endSandboxSession: { _ in }/g' Tests/irisTests/{ApproveAndRunTests,BackgroundDescendantTests,CatchUpTests,GateEvaluatorTests,JobAdmissionTests,JobProfileTests,JobRetryTests,JobRunnerTests,TurnBudgetTests}.swift
grep -c "endSandboxSession: { _ in }" Tests/irisTests/*.swift | grep -v ":0"
# expect: ApproveAndRunTests 17, BackgroundDescendantTests 1, CatchUpTests 2, GateEvaluatorTests 11,
#         JobAdmissionTests 27, JobProfileTests 2, JobRetryTests 13, JobRunnerTests 9, TurnBudgetTests 2 — 84 in all
```
Read the diff, and look at `JobAdmissionTests.swift:501` by eye: its `ledger: store.ledger, config: config,` line must now read `ledger: store.ledger, endSandboxSession: { _ in }, config: config,`. `endSession` on an unknown id is a dictionary removal, so this is hygiene rather than a fix — but it is done in this commit, the one that introduces the call, so no test ever reaches the singleton.

- [ ] **Step 6: Run to verify they pass** — `scripts/test-filter.sh JobRunnerGrantTests` (8), `scripts/test-filter.sh JobRunnerTests`, `scripts/test-filter.sh ApproveAndRunTests`, `scripts/test-filter.sh JobRetryTests`, `scripts/test-filter.sh JobAdmissionTests`, `scripts/test-filter.sh GateEvaluatorTests`. Expected: PASS with counts.

- [ ] **Step 7: Full suite and commit**
```bash
swift test; echo exit=$?
git add Sources/iris/JobGrant.swift Sources/iris/JobRunner.swift Tests/irisTests/JobRunnerGrantTests.swift Tests/irisTests/JobRunnerTests.swift Tests/irisTests/ApproveAndRunTests.swift Tests/irisTests/BackgroundDescendantTests.swift Tests/irisTests/CatchUpTests.swift Tests/irisTests/GateEvaluatorTests.swift Tests/irisTests/JobAdmissionTests.swift Tests/irisTests/JobProfileTests.swift Tests/irisTests/JobRetryTests.swift Tests/irisTests/TurnBudgetTests.swift
git commit -m "feat(jobs): a granted mutating fire stamps workspace, grant and pin, re-checks the grant and the isolated network before its turn, ends its container on close; Approve-and-run reopens with the grant (#282)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 4a: `NetworkMode`, the create argv, `ensureIsolatedNetwork`, the three fakes **[§2 the container, §0.7]**

**Files:**
- Modify: `Sources/iris/ContainerRuntime.swift:3-13` (`ContainerRuntimeError.networkFailed`), `:79-92` (protocol), `:94-109` (extension: the 4-argument `createDetached` convenience), `:421-469` (`CLIContainerRuntime.createDetached`, `ensureIsolatedNetwork`)
- Modify: `Tests/irisTests/SandboxSessionManagerTests.swift:6-53` (`MockRuntime` gains the two members), `Tests/irisTests/SandboxTimeoutTests.swift:396-420` (`HeldCreateRuntime` gains them), `Tests/irisTests/GateEvaluatorTests.swift:8-40` (`GateRuntime` gains them) — the protocol change does not compile without them
- Test: `Tests/irisTests/ContainerRuntimeTests.swift` (extend)

**Interfaces:**
- Consumes: `JobGrant` (Task 1); `ContainerMount.argument(for:)`; `CLIContainerRuntime.Launch` (:424), `housekeepingTimeoutSeconds` (:436); `RecordingLauncher(result:)`, `.argv/.timeouts/.lastArgv` (ContainerRuntimeTests.swift:7-29).
- Produces:

```swift
enum NetworkMode: Equatable, Sendable {
    case `default`
    case isolated(name: String)
    static let isolatedNetworkName = "iris-isolated"
    static let isolated = NetworkMode.isolated(name: isolatedNetworkName)
    /// `.isolated` for a granted run without the network bit, `.default` otherwise (an ungranted run is unchanged).
    static func forGrant(_ grant: JobGrant?) -> NetworkMode
}
// ContainerRuntimeError
case networkFailed(String)
// ContainerRuntime (protocol)
func createDetached(name: String, image: String, mounts: [String], workdir: String, network: NetworkMode) async throws
/// `container network ls --format json`; when `name` is absent, `container network create --internal <name>`.
/// A create whose stderr says `already exists` is success. Throws `networkFailed` on a failed listing or any other failed create.
func ensureIsolatedNetwork(named name: String) async throws
// extension ContainerRuntime
func createDetached(name: String, image: String, mounts: [String], workdir: String) async throws   // → network: .default; every existing caller keeps compiling
```

Measured on this machine, 2026-09-23, `container` CLI 1.1.0 (spec §2): `container network ls --format json` prints an array of objects with a top-level `id` and a `configuration.name`, both `"default"` for the built-in network; a second `container network create --internal iris-isolated` exits non-zero with `Error: network iris-isolated already exists` on stderr. The parser reads both keys (M1); the create treats that stderr as success, so two racing fires cannot fail each other; a listing that fails is `networkFailed` — a network that cannot be vouched for is not one to attach a job to.

Create argv for a granted run reads exactly: `run -d --name iris-<id> --mount type=virtiofs,source=/p,target=/p --mount type=virtiofs,source=/q,target=/q,readonly --network iris-isolated --no-dns -w /p <image> sleep infinity`; `network: true` renders neither flag.

- [ ] **Step 1: Write the failing tests** — `ContainerRuntimeTests`, after `spaceInPath` (:70-79):

```swift
    @Test("a granted job's create argv: mounts in order, then --network iris-isolated --no-dns, then -w")
    func grantedCreateArgv() async throws {
        let launcher = RecordingLauncher()
        try await CLIContainerRuntime(launch: launcher.launch).createDetached(
            name: "iris-g", image: "img",
            mounts: ["/Users/me/proj", "/Users/me/.config/gh:ro"], workdir: "/Users/me/proj",
            network: .isolated)
        #expect(launcher.lastArgv == [
            "run", "-d", "--name", "iris-g",
            "--mount", "type=virtiofs,source=/Users/me/proj,target=/Users/me/proj",
            "--mount", "type=virtiofs,source=/Users/me/.config/gh,target=/Users/me/.config/gh,readonly",
            "--network", "iris-isolated", "--no-dns",
            "-w", "/Users/me/proj", "img", "sleep", "infinity",
        ])
    }

    @Test("network on is the default network: no --network, no --no-dns; the four-argument form is the same")
    func defaultNetworkArgv() async throws {
        let launcher = RecordingLauncher()
        let rt = CLIContainerRuntime(launch: launcher.launch)
        try await rt.createDetached(name: "iris-n", image: "img", mounts: ["/p"], workdir: "/p", network: .default)
        #expect(!launcher.lastArgv.contains("--network") && !launcher.lastArgv.contains("--no-dns"))
        try await rt.createDetached(name: "iris-n", image: "img", mounts: ["/p"], workdir: "/p")
        #expect(launcher.argv[0] == launcher.argv[1])
    }

    /// The shape `container network ls --format json` prints (measured 2026-09-23, CLI 1.1.0).
    private static let listWithDefaultOnly = #"[{"id":"default","configuration":{"name":"default","mode":"nat"}}]"#
    private static let listWithIsolated = #"[{"id":"default","configuration":{"name":"default"}},{"id":"iris-isolated","configuration":{"name":"iris-isolated"}}]"#

    @Test("ensureIsolatedNetwork lists, creates once when absent, and never creates when present under either key")
    func ensureIsolatedNetworkCreatesOnce() async throws {
        let absent = RecordingLauncher(result: (Self.listWithDefaultOnly, "", 0))
        try await CLIContainerRuntime(launch: absent.launch).ensureIsolatedNetwork(named: "iris-isolated")
        #expect(absent.argv == [["network", "ls", "--format", "json"],
                                ["network", "create", "--internal", "iris-isolated"]])
        #expect(absent.timeouts.allSatisfy { $0 == CLIContainerRuntime.housekeepingTimeoutSeconds })

        let present = RecordingLauncher(result: (Self.listWithIsolated, "", 0))
        try await CLIContainerRuntime(launch: present.launch).ensureIsolatedNetwork(named: "iris-isolated")
        #expect(present.argv == [["network", "ls", "--format", "json"]])

        // Only `configuration.name` carries it (a CLI that drops the top-level id): still found.
        let byName = RecordingLauncher(result: (#"[{"configuration":{"name":"iris-isolated"}}]"#, "", 0))
        try await CLIContainerRuntime(launch: byName.launch).ensureIsolatedNetwork(named: "iris-isolated")
        #expect(byName.argv.count == 1)
    }

    @Test("a create that loses a race is success; any other failed create, or a failed listing, is networkFailed")
    func ensureIsolatedNetworkRaceAndFailure() async {
        // Per-call scripting: the listing says the network is absent, then the create loses the
        // race — exit 1 with the CLI's "already exists" on stderr — which is success.
        let raced = RecordingLauncher(results: [(Self.listWithDefaultOnly, "", 0),
                                                ("", "Error: network iris-isolated already exists", 1)])
        await #expect(throws: Never.self) {
            try await CLIContainerRuntime(launch: raced.launch).ensureIsolatedNetwork(named: "iris-isolated")
        }
        #expect(raced.argv.count == 2)

        let denied = RecordingLauncher(results: [(Self.listWithDefaultOnly, "", 0), ("", "Error: permission denied", 1)])
        await #expect(throws: ContainerRuntimeError.networkFailed("Error: permission denied")) {
            try await CLIContainerRuntime(launch: denied.launch).ensureIsolatedNetwork(named: "iris-isolated")
        }

        // A listing that fails is a network nobody can vouch for: no create is attempted.
        let unlisted = RecordingLauncher(results: [("", "boom", 1)])
        await #expect(throws: ContainerRuntimeError.networkFailed("boom")) {
            try await CLIContainerRuntime(launch: unlisted.launch).ensureIsolatedNetwork(named: "iris-isolated")
        }
        #expect(unlisted.argv == [["network", "ls", "--format", "json"]])
    }
```
`RecordingLauncher` (ContainerRuntimeTests.swift:7-29) answers every call with one scripted result today; add a queue form beside `init(result:)` — the next scripted result per call, the last one repeating:
```swift
    private var queue: [(stdout: String, stderr: String, exitCode: Int32)] = []

    /// One result per call, in order; the last repeats once the queue is spent.
    init(results: [(stdout: String, stderr: String, exitCode: Int32)]) {
        self.queue = results
        self.scripted = results.last ?? ("", "", 0)
    }

    var launch: CLIContainerRuntime.Launch {
        { [self] args, timeout in
            lock.withLock {
                calls.append((args, timeout))
                if queue.count > 1 { return queue.removeFirst() }
                return queue.first ?? scripted
            }
        }
    }
```
(`launch` replaces the existing computed property; with `init(result:)` the queue is empty and `scripted` answers as before.)

Fakes: `MockRuntime` (SandboxSessionManagerTests.swift:6-53):
```swift
    private var networksPerCreate: [NetworkMode] = []
    private(set) var networksEnsured: [String] = []
    var nextNetworkError: Error?
    func createDetached(name: String, image: String, mounts: [String], workdir: String, network: NetworkMode) async throws {
        // …the existing body, plus:
        lock.withLock { networksPerCreate.append(network) }
    }
    func ensureIsolatedNetwork(named name: String) async throws {
        if let scripted = lock.withLock({ () -> Error? in let e = nextNetworkError; nextNetworkError = nil; return e }) { throw scripted }
        lock.withLock { networksEnsured.append(name) }
    }
    var createdNetworks: [NetworkMode] { lock.withLock { networksPerCreate } }
```
`HeldCreateRuntime` (SandboxTimeoutTests.swift:396) and `GateRuntime` (GateEvaluatorTests.swift:26): `createDetached` gains `network: NetworkMode` (ignored), plus `func ensureIsolatedNetwork(named: String) async throws {}` — a gate never asks for the isolated network.

Red today: nothing compiles. Once green: `grantedCreateArgv` turns red if the flags land after `-w` or `--no-dns` is dropped; `defaultNetworkArgv` if `.default` renders a flag; `ensureIsolatedNetworkCreatesOnce` if either key is not read or the create is unconditional; `ensureIsolatedNetworkRaceAndFailure` if "already exists" is not treated as success or a failed listing is swallowed.

- [ ] **Step 2: Run to verify they fail** — `scripts/test-filter.sh ContainerRuntimeTests`; Expected: compile error `extra argument 'network'`.

- [ ] **Step 3: Implement** — `ContainerRuntime.swift`. Error case after `invalidMount` (:12): `case networkFailed(String)`. After the `ContainerMount` struct:
```swift
/// Which network a container is attached to (#282 §0.7). The CLI has no "none": `run --network`
/// takes a name, so "off" is an Iris-owned internal network with no route out and no DNS.
enum NetworkMode: Equatable, Sendable {
    case `default`
    case isolated(name: String)

    static let isolatedNetworkName = "iris-isolated"
    static let isolated = NetworkMode.isolated(name: isolatedNetworkName)

    /// A granted run without the network bit is isolated; a granted run with it, and every run
    /// with no grant at all, keeps the default network — an ungranted job's container is exactly
    /// what it was before grants existed.
    static func forGrant(_ grant: JobGrant?) -> NetworkMode {
        guard let grant, !grant.network else { return .default }
        return .isolated
    }
}
```
Protocol (:80-92): replace the `createDetached` requirement with the five-argument one and add
```swift
    /// Makes sure the host-only network `name` exists: `container network ls`, then
    /// `container network create --internal <name>` when it is missing. Throws `networkFailed`.
    func ensureIsolatedNetwork(named name: String) async throws
```
Extension (:94-109) gains
```swift
    /// The pre-grant form: the default network. Every caller that is not a granted run.
    func createDetached(name: String, image: String, mounts: [String], workdir: String) async throws {
        try await createDetached(name: name, image: image, mounts: mounts, workdir: workdir, network: .default)
    }
```
`CLIContainerRuntime.createDetached` (:452-469) gains `network: NetworkMode` and, between the mounts loop and `-w`:
```swift
        if case .isolated(let networkName) = network {
            // `--no-dns` too: an internal network has no resolver to offer, and the default DNS
            // would be a route out that the network itself does not have.
            args += ["--network", networkName, "--no-dns"]
        }
```
New methods:
```swift
    /// Measured 2026-09-23 (CLI 1.1.0): `network ls --format json` is an array of objects with a
    /// top-level `id` and a `configuration.name`; a duplicate `network create` exits non-zero
    /// with `Error: network <name> already exists` on stderr. That stderr is success here — two
    /// fires racing to create the same network must not fail each other — and a listing that fails
    /// is a network nobody can vouch for, so it fails closed.
    func ensureIsolatedNetwork(named name: String) async throws {
        let listed = try await launch(["network", "ls", "--format", "json"], Self.housekeepingTimeoutSeconds)
        guard listed.exitCode == 0 else {
            throw ContainerRuntimeError.networkFailed((listed.stdout + listed.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if Self.networkNames(in: listed.stdout).contains(name) { return }
        let created = try await launch(["network", "create", "--internal", name], Self.housekeepingTimeoutSeconds)
        guard created.exitCode == 0 || created.stderr.contains("already exists") else {
            throw ContainerRuntimeError.networkFailed((created.stdout + created.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Both spellings the CLI uses for a network's name.
    private static func networkNames(in json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var names: Set<String> = []
        for entry in arr {
            if let id = entry["id"] as? String { names.insert(id) }
            if let name = (entry["configuration"] as? [String: Any])?["name"] as? String { names.insert(name) }
        }
        return names
    }
```
Then the three fakes and `RecordingLauncher(results:)` exactly as shown in Step 1.

- [ ] **Step 4: Run to verify they pass** — `scripts/test-filter.sh ContainerRuntimeTests`, `scripts/test-filter.sh SandboxSessionManagerTests`, `scripts/test-filter.sh SandboxTimeoutTests`, `scripts/test-filter.sh GateEvaluatorTests`. Expected: PASS with counts (the last three unchanged in count — only the fakes moved).

- [ ] **Step 5: Full suite and commit**
```bash
swift test; echo exit=$?
git add Sources/iris/ContainerRuntime.swift Tests/irisTests/ContainerRuntimeTests.swift Tests/irisTests/SandboxSessionManagerTests.swift Tests/irisTests/SandboxTimeoutTests.swift Tests/irisTests/GateEvaluatorTests.swift
git commit -m "feat(sandbox): NetworkMode — --network iris-isolated --no-dns on create, ensureIsolatedNetwork reading id and configuration.name and tolerating a lost create race (#282)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 4b: The session manager, the executor's grant plumbing, `set_workspace` refused unattended **[§2, §0.4, §0.10]**

**Files:**
- Modify: `Sources/iris/SandboxSessionManager.swift:10-18` (`Session.network`), `:50-68` (`run` signature; the doc comment that says "Nothing in the app passes any yet"), `:86,130` (`ensureSession` threading), `:213-269` (`ensureSession`/`create`/`attemptCreate` take `network`), `:284-299` (`creationError` renders `networkFailed`)
- Modify: `Sources/iris/JobGrant.swift` (`extraMountEntries`)
- Modify: `Sources/iris/ToolExecutor.swift:30-34` (`sandboxSession` seam widened), `:160-170` (`execute` gains `grant:`), `:323-338` (`runCommand`: mounts from the grant)
- Modify: `Sources/iris/iris.swift:1169-1180` (`set_workspace` declared only when `!isUnattended`), `:2409-2428` (read `sandboxGrant` in the hop; refuse `set_workspace` unattended beside `jobCreationTools`), `:3054,3059` (pass the grant), `:3079-3112` (`executeApprovedCall` reads it), `:3204,3249` (`executeToolWithHooks` gains `grant:`), `:2177-2178` (the refusal sentence beside `unattendedJobCreationRefusal`)
- Modify: `Sources/iris/JobRunner.swift` (the `ensureIsolatedNetwork` default from Task 3b becomes the real one)
- Modify: `Sources/iris/AppState.swift:1032-1034` (`bindGoalWorkspace` leaves a background conversation's `workspacePath` alone)
- Test: `Tests/irisTests/SandboxSessionManagerTests.swift` (two cases), `Tests/irisTests/SandboxTimeoutTests.swift:525-545` (seam closure restated; two new cases), `Tests/irisTests/UnattendedWorkspaceTests.swift` (new, three tests)

**Interfaces:**
- Consumes: `NetworkMode`, `ContainerRuntime.ensureIsolatedNetwork(named:)`, `createDetached(... network:)`, `MockRuntime.networksEnsured/createdNetworks/nextNetworkError` (Task 4a); `JobGrant.workingDirectory`, `mountEntries` (Task 1); `Conversation.sandboxGrant` (Task 3a); `SandboxSessionManager.mountList(workspace:extra:)` (:167-169); `IrisEngine.unattendedJobCreationRefusal` (iris.swift:2177) and the refusal site (:2417-2419); `UnattendedJobCreationTests.dispatchResult(for:)` idiom (:41-60).
- Produces:

```swift
// SandboxSessionManager
func run(command: String, conversationId id: UUID, workspace: String?, extraMounts: [String] = [],
         network: NetworkMode = .default, timeoutSeconds: Int? = nil) async -> String
static func isolatedNetworkError(_ detail: String) -> String   // "Error: isolated network unavailable: \(detail). Nothing was run."
// JobGrant
/// The entries to hand `run` as `extraMounts`: every mount except the identity-mapped read-write
/// one whose source is `workingDirectory` (mountList adds that one itself).
func extraMountEntries() -> [String]
// ToolExecutor
var sandboxSession: (@Sendable (_ command: String, _ conversationId: UUID, _ workspace: String?,
                                _ extraMounts: [String], _ network: NetworkMode, _ timeoutSeconds: Int) async -> String)?
func execute(name: String, args: [String: JSONValue], cwd: String? = nil, conversationId: UUID? = nil,
             useSandbox: Bool = false, grant: JobGrant? = nil) async -> String
// IrisEngine
static let unattendedWorkspaceRefusal = "Not run: a background run cannot change its workspace; widen the job's grant instead."
private func executeToolWithHooks(name:args:cwd:conversationId:useSandbox:isUnattended:origin:, grant: JobGrant? = nil) async -> String
// AppState
func bindGoalWorkspace(for:contract:paths:) -> String?   // returns nil, binds nothing, for a background conversation
```

**C2 / §0.10, the rule this task enforces:** with a grant present, the container's mount set is a pure function of the grant — `workspace: grant.workingDirectory` (never `cwd`), `extraMounts: grant.extraMountEntries()`, `network: NetworkMode.forGrant(grant)` — and `-w` follows (`workspace ?? "/"`). Without a grant, `runCommand` is exactly as today. A conversation whose `workspacePath` was somehow moved therefore changes nothing in the VM; and `set_workspace` is refused for every unattended conversation in the dispatcher (the refusal is the point that has an effect) and not declared to one (invariant 6). `AppState.bindGoalWorkspace` (AppState.swift:1032; called from `GoalContractPanel`, an attended surface, and reachable through a goal contract locked in a background conversation) is the one other writer of `workspacePath`; it gets the same guard so "a background run cannot change its workspace" is true of every path, not only the tool. Note on an explicit target: a first read-write entry whose target differs from its source is mounted twice — identity by `mountList`, and again at its target as an extra — which the CLI allows and which is harmless; `extraMountEntries` strips only the identity-mapped one.

- [ ] **Step 1: Write the failing tests** — `SandboxSessionManagerTests`:
```swift
    @Test("an isolated session ensures the network before its create, and a changed network recreates")
    func isolatedNetworkIsEnsuredAndPinned() async {
        let rt = MockRuntime()
        let m = mgr(rt)
        let id = UUID()
        _ = await m.run(command: "a", conversationId: id, workspace: "/ws", network: .isolated)
        #expect(rt.networksEnsured == ["iris-isolated"])
        #expect(rt.createdNetworks == [.isolated])
        _ = await m.run(command: "b", conversationId: id, workspace: "/ws", network: .isolated)
        #expect(rt.createdCount == 1 && rt.networksEnsured.count == 1, "the network is ensured per create, not per command")
        _ = await m.run(command: "c", conversationId: id, workspace: "/ws", network: .default)
        #expect(rt.createdCount == 2 && rt.removedNames.count == 1, "a different network is a different container")
        #expect(rt.createdNetworks == [.isolated, .default])
    }

    @Test("a network that cannot be created runs nothing and says why")
    func networkFailureRunsNothing() async {
        let rt = MockRuntime()
        rt.nextNetworkError = ContainerRuntimeError.networkFailed("permission denied")
        let m = mgr(rt)
        let out = await m.run(command: "a", conversationId: UUID(), workspace: "/ws", network: .isolated)
        #expect(out == SandboxSessionManager.isolatedNetworkError("permission denied"))
        #expect(rt.execCount == 0 && rt.createdCount == 0)
    }
```
`SandboxTimeoutTests` — the seam closure at :531 becomes `{ _, _, _, _, _, timeoutSeconds in`; add:
```swift
    private final class CapturedSession: @unchecked Sendable {
        private let lock = NSLock()
        private var workspace: String?; private var mounts: [String] = []; private var network: NetworkMode = .default
        func set(_ w: String?, _ m: [String], _ n: NetworkMode) { lock.withLock { workspace = w; mounts = m; network = n } }
        var value: (workspace: String?, mounts: [String], network: NetworkMode) { lock.withLock { (workspace, mounts, network) } }
    }

    private func capturingExecutor() -> (ToolExecutor, CapturedSession) {
        let captured = CapturedSession()
        var executor = ToolExecutor()
        executor.sandboxSession = { _, _, workspace, extraMounts, network, _ in
            captured.set(workspace, extraMounts, network); return "Success"
        }
        return (executor, captured)
    }

    @Test("the sandboxed branch mounts exactly the grant: its working directory, the rest as extras, its network")
    func sandboxedBranchMountsTheGrant() async {
        let (executor, captured) = capturingExecutor()
        let grant = JobGrant(mounts: [ContainerMount(source: "/p"), ContainerMount(source: "/q", target: "/gh", readOnly: true)])
        _ = await executor.execute(name: "run_command", args: ["command": .string("x")], cwd: "/p",
                                   conversationId: UUID(), useSandbox: true, grant: grant)
        #expect(captured.value.workspace == "/p")
        #expect(captured.value.mounts == ["/q:/gh:ro"], "the working directory is mounted by mountList; only the rest ride as extras")
        #expect(captured.value.network == .isolated)

        _ = await executor.execute(name: "run_command", args: ["command": .string("x")], cwd: "/p",
                                   conversationId: UUID(), useSandbox: true, grant: JobGrant(mounts: grant.mounts, network: true))
        #expect(captured.value.network == .default)

        // No read-write mount: the working directory is `/` (§0.6), whatever cwd says.
        let ro = JobGrant(mounts: [ContainerMount(source: "/q", readOnly: true)])
        _ = await executor.execute(name: "run_command", args: ["command": .string("x")], cwd: "/somewhere",
                                   conversationId: UUID(), useSandbox: true, grant: ro)
        #expect(captured.value.workspace == nil && captured.value.mounts == ["/q:ro"])

        _ = await executor.execute(name: "run_command", args: ["command": .string("x")], cwd: "/ws",
                                   conversationId: UUID(), useSandbox: true)
        #expect(captured.value.workspace == "/ws" && captured.value.mounts.isEmpty && captured.value.network == .default, "no grant, no change")
    }

    @Test("a granted conversation whose workspacePath was moved still mounts only the grant (§0.10)")
    func movedWorkspaceDoesNotMoveTheMount() async {
        let (executor, captured) = capturingExecutor()
        let grant = JobGrant(mounts: [ContainerMount(source: "/Users/me/proj")])
        // `cwd` is what the dispatcher hands over from `conversation.workspacePath`; here it has
        // been pointed at home. The container must not see it.
        _ = await executor.execute(name: "run_command", args: ["command": .string("cat ~/.ssh/id_rsa")], cwd: "/Users/me",
                                   conversationId: UUID(), useSandbox: true, grant: grant)
        #expect(captured.value.workspace == "/Users/me/proj")
        #expect(captured.value.mounts.isEmpty)
    }
```
`Tests/irisTests/UnattendedWorkspaceTests.swift` (new; the `dispatchResult` idiom from `UnattendedJobCreationTests`):
```swift
import Testing
import Foundation
@testable import iris

/// #282 §0.10 — a background run cannot move its own boundary. `set_workspace` is not declared to
/// an unattended turn (invariant 6) and is refused in the dispatcher if called anyway.
@MainActor
@Suite("set_workspace is refused unattended (#282)")
struct UnattendedWorkspaceTests {
    private func engine(_ app: AppState, client: any LLMClientProtocol) -> IrisEngine {
        IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                   retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
    }

    @Test("a background turn is not offered set_workspace; an ordinary turn still is")
    func notDeclaredInTheBackground() async {
        for background in [true, false] {
            let app = AppState()
            app.conversations.removeAll()
            let id = app.createNewConversation(isBackground: background, select: false)
            let client = CapturingLLMClient(reply: "ok")
            await engine(app, client: client).processInput("hello", source: "UI", conversationId: id)
            let declared = client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
            #expect(declared.contains("set_workspace") == !background)
        }
    }

    @Test("a background conversation's set_workspace is refused with the sentence and its workspacePath is unchanged")
    func refusedInTheDispatcher() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-unattended-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = AppState()
        app.conversations.removeAll()
        let id = app.createNewConversation(isBackground: true, select: false)
        app.setWorkspace(for: id, path: "/Users/me/proj")
        let call = FunctionCall(name: "set_workspace", args: ["path": .string(dir.path)])
        let part = Part(text: nil, functionCall: call, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        let client = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "understood")]))], usageMetadata: nil),
        ])
        await engine(app, client: client).processInput("go", source: "UI", conversationId: id)
        let results = app.conversations.first { $0.id == id }?.history.flatMap { $0.parts }
            .compactMap { $0.functionResponse?.response["result"]?.stringValue } ?? []
        #expect(results.contains(IrisEngine.unattendedWorkspaceRefusal))
        #expect(app.conversations.first { $0.id == id }?.workspacePath == "/Users/me/proj")
    }

    @Test("binding a goal workspace in a background conversation binds nothing and leaves workspacePath unchanged")
    func goalBindingLeavesABackgroundWorkspaceAlone() throws {
        let paths = IrisPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-unattended-goal-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let app = AppState()
        app.conversations.removeAll()
        let id = app.createNewConversation(isBackground: true, select: false)
        app.setWorkspace(for: id, path: "/Users/me/proj")
        let bound = app.bindGoalWorkspace(for: id, contract: GoalContract(objective: "Write a hangman game", criteria: []),
                                          paths: paths)
        #expect(bound == nil)
        #expect(app.conversations.first { $0.id == id }?.workspacePath == "/Users/me/proj")
        #expect(!FileManager.default.fileExists(atPath: paths.workspacesDir.path), "no directory is created for a binding that does not happen")

        // The attended case is untouched: `GoalWorkspaceBindingTests.createsAndBinds` still holds.
        let attended = app.createNewConversation()
        #expect(app.bindGoalWorkspace(for: attended, contract: GoalContract(objective: "Write a hangman game", criteria: []),
                                      paths: paths) != nil)
    }
}
```
Red once green: `isolatedNetworkIsEnsuredAndPinned` — `Session` not storing `network`; `networkFailureRunsNothing` — `attemptCreate` ignoring the ensure error; `sandboxedBranchMountsTheGrant` / `movedWorkspaceDoesNotMoveTheMount` — `runCommand` passing `expandedCwd` when a grant is present, or forgetting the network; `notDeclaredInTheBackground` — the declaration left unconditional; `refusedInTheDispatcher` — the refusal missing from `executeFunctionCall`; `goalBindingLeavesABackgroundWorkspaceAlone` — the `isBackground` guard missing from `bindGoalWorkspace`.

- [ ] **Step 2: Run to verify they fail** — `scripts/test-filter.sh SandboxTimeoutTests`; Expected: compile error on the six-parameter closure / `grant:`.

- [ ] **Step 3: `SandboxSessionManager`** — `Session` gains `var network: NetworkMode`; `run` gains `network: NetworkMode = .default`; the disagreement test (:65) becomes `s.mountedWorkspace != workspace || s.mounts != mounts || s.network != network`, the loop's guard (:88) likewise; `ensureSession`/`create`/`attemptCreate` take and forward `network`; `attemptCreate` begins with
```swift
        if case .isolated(let networkName) = network {
            try await runtime.ensureIsolatedNetwork(named: networkName)
        }
```
both `createDetached` calls pass `network: network`, both `Session(...)` inits store it. Rewrite the doc comment at :52-58: "`extraMounts` are mounted alongside the workspace … A granted job's `run_command` passes its grant's mounts here and its network mode (#282); a gate still builds a container of its own." `creationError` (:284) gains
```swift
        if case ContainerRuntimeError.networkFailed(let detail) = error { return Self.isolatedNetworkError(detail) }
```
with `static func isolatedNetworkError(_ detail: String) -> String { "Error: isolated network unavailable: \(detail). Nothing was run." }`.

- [ ] **Step 4: `JobGrant.extraMountEntries`** — append to `JobGrant.swift`:
```swift
extension JobGrant {
    /// The entries to hand `SandboxSessionManager.run` as `extraMounts`: every mount except the
    /// identity-mapped read-write one that is the working directory — `mountList` adds that one
    /// itself, and two `--mount` flags for one directory is what it would otherwise be.
    func extraMountEntries() -> [String] {
        mounts.filter { !(!$0.readOnly && $0.target == $0.source && $0.source == workingDirectory) }.map(\.entry)
    }
}
```

- [ ] **Step 5: `ToolExecutor`** — the seam (:34) takes the six parameters; `execute` (:170) gains `grant: JobGrant? = nil` and forwards it; `runCommand` (:323-338) gains `grant: JobGrant? = nil` and its sandboxed branch becomes
```swift
            let deadline = Int(timeoutSeconds)
            // §0.10: with a grant, the container's mounts are the grant's and nothing else — the
            // working directory from the grant, never from the conversation's workspace, which a
            // run must not be able to move. Without one, the workspace as today.
            let workspace = grant.map(\.workingDirectory) ?? cwd.map { ($0 as NSString).expandingTildeInPath }
            let extraMounts = grant?.extraMountEntries() ?? []
            let network = NetworkMode.forGrant(grant)
            if let sandboxSession {
                return await sandboxSession(command, conversationId, workspace, extraMounts, network, deadline)
            }
            guard SandboxingManager.shared.isContainerInstalled else { return "Error: sandboxing is on but …" /* unchanged */ }
            return await SandboxSessionManager.shared.run(command: command, conversationId: conversationId,
                                                          workspace: workspace, extraMounts: extraMounts,
                                                          network: network, timeoutSeconds: deadline)
```
(`grant.map(\.workingDirectory)` is `String??` flattened by `??` — write it as `let workspace: String? = grant != nil ? grant!.workingDirectory : cwd.map { … }` if the optional chaining reads badly; the point is that a grant with no read-write mount yields `nil`, i.e. `/`, not the cwd.)

- [ ] **Step 6: `IrisEngine`** — beside `unattendedJobCreationRefusal` (:2177):
```swift
    /// §0.10: the grant is the boundary, and nothing a run does may move it.
    static let unattendedWorkspaceRefusal = "Not run: a background run cannot change its workspace; widen the job's grant instead."
```
The hop at :2409-2412 returns `(isUnattended, jobProfile, sandboxGrant)`; directly after the `jobCreationTools` refusal (:2417-2419):
```swift
        if functionCall.name == "set_workspace", isUnattended {
            return Self.unattendedWorkspaceRefusal
        }
```
The declaration at :1169-1180 is wrapped in `if !isUnattended { … }` (the same gate the job tools use at :1201). `AppState.bindGoalWorkspace` (AppState.swift:1034), after the `guard let idx`:
```swift
        // §0.10: a background run cannot change its workspace by any path — the tool is refused,
        // and a goal locked in such a conversation binds nothing. The grant is the boundary.
        guard !conversations[idx].isBackground else { return nil }
``` The two `executeToolWithHooks` calls at :3054 and :3059 pass `grant: sandboxGrant`; `executeToolWithHooks` (:3204) gains `grant: JobGrant? = nil` and passes it to `executor.execute` (:3249); `executeApprovedCall` (:3079) reads `let grant = await MainActor.run { localState?.conversations.first(where: { $0.id == conversationId })?.sandboxGrant }` and passes `grant: grant` at :3109. `JobRunner`'s default (Task 3b) becomes
```swift
        self.ensureIsolatedNetwork = ensureIsolatedNetwork ?? {
            do { try await CLIContainerRuntime().ensureIsolatedNetwork(named: NetworkMode.isolatedNetworkName); return nil }
            catch ContainerRuntimeError.networkFailed(let detail) { return detail }
            catch { return "\(error)" }
        }
```

- [ ] **Step 7: Run to verify they pass** — `scripts/test-filter.sh SandboxSessionManagerTests`, `scripts/test-filter.sh SandboxTimeoutTests`, `scripts/test-filter.sh UnattendedWorkspaceTests` (3), `scripts/test-filter.sh UnattendedJobCreationTests`, `scripts/test-filter.sh GoalWorkspaceBindingTests`, `scripts/test-filter.sh ToolSurfaceTrimTests`, `scripts/test-filter.sh JobRunnerGrantTests`. Expected: PASS with counts.

- [ ] **Step 8: Full suite and commit**
```bash
swift test; echo exit=$?
git add Sources/iris/SandboxSessionManager.swift Sources/iris/JobGrant.swift Sources/iris/ToolExecutor.swift Sources/iris/iris.swift Sources/iris/JobRunner.swift Sources/iris/AppState.swift Tests/irisTests/SandboxSessionManagerTests.swift Tests/irisTests/SandboxTimeoutTests.swift Tests/irisTests/UnattendedWorkspaceTests.swift
git commit -m "feat(sandbox): a granted run's container mounts are a pure function of its grant, with its network; set_workspace is refused and undeclared unattended, and a goal binds no workspace in a background conversation (#282)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 5a: The real-path helper, the pure gate, `grantNearest` on the call **[§0.9, §3 pure `allows`, §5 nearest]**

**Files:**
- Modify: `Sources/iris/IrisPaths.swift:151-182` (`realPath`, `realPathForAllow`; `isUnderProtectedWriteDir` hardened; `canonicalPath` untouched)
- Modify: `Sources/iris/JobGrant.swift` (`covering`, `allows`, `nearest`)
- Modify: `Sources/iris/JobRun.swift:102-137` (`BlockedCall.grantNearest`, lenient)
- Modify: `Sources/iris/JobRunner.swift:968-972` (pass the nearest), `:1607-1620` (`failureReason(... blockedNearest:)`)
- Test: `Tests/irisTests/IrisPathsTests.swift` (extend), `Tests/irisTests/JobGrantGateTests.swift` (new; the pure suite), `Tests/irisTests/JobRunnerTests.swift` (one pure `failureReason` case)

**Interfaces:**
- Consumes: `ToolExecutor.resolvePath(_:cwd:)` (ToolExecutor.swift:464-469); `IrisPaths.protectedWriteDirs` (:149); `realpath(3)` from Darwin; `BlockedCall` (JobRun.swift:102-137); `JobRunner.failureReason` (:1607).
- Produces:

```swift
// IrisPaths
/// §0.9 — the component-wise real path: tilde expanded, then `realpath(3)` of the deepest existing
/// ancestor of the UNSTANDARDISED components (so a `..` after a symlink is resolved after the link,
/// as the kernel does), remaining components appended; a `..` among the missing tail pops lexically
/// (a directory that does not exist cannot be a symlink). A relative path is made absolute against
/// the process cwd, as `canonicalPath` does today; the allow side never passes one (see below).
static func realPath(_ rawPath: String) -> String
/// The allow-side form: nil when the path is not absolute after tilde expansion or any component is `..`.
static func realPathForAllow(_ rawPath: String) -> String?
func isUnderProtectedWriteDir(_ rawPath: String) -> Bool     // now both sides through realPath, still case-insensitive
// JobGrant
/// The innermost mount whose real source is `realPath` or a component ancestor of it. `/proj` does not cover `/project`.
func covering(_ realPath: String) -> ContainerMount?
/// §3, pure: run_command → true; write_file → under a read-write source; read_file → under any source;
/// everything else → false. `details` resolved against `cwd`, then `realPathForAllow` (nil → false).
func allows(toolName: String, details: String, cwd: String?) -> Bool
/// The granted source sharing the longest component prefix with the resolved path; ties → the earlier entry;
/// nil only when the grant has no mounts; a `..` path is still placed by its real path, so the card can say where the grant is.
func nearest(to details: String, cwd: String?) -> String?
// BlockedCall
let grantNearest: String?     // set only for a denial inside a granted run; decodeIfPresent; init default nil
// JobRunner
static func failureReason(status:messages:blockedTool:blockedReason:, blockedNearest: String? = nil) -> String?
// "needs approval: write_file outside the grant (nearest: /Users/me/proj)" when blockedNearest is set
```

Why both sides go through the helper: `realpath(3)` returns `/private/tmp/x` where Foundation's `resolvingSymlinksInPath` (and so `canonicalPath`, which stores sources) returns `/tmp/x` (L2). `covering` and `nearest` therefore resolve each stored source with `realPathForAllow` too and compare real to real; `isUnderProtectedWriteDir` resolves `protectedWriteDirs` the same way. Both sides being real paths also settles case: `realpath(3)` canonicalises case on APFS (measured: `/tmp/SYMTEST/MOUNT/proj` → `/private/tmp/symtest/mount/proj`), so a differently-cased spelling of a granted directory is allowed because it *is* that directory, and `allows` needs no case-fold of its own; `isUnderProtectedWriteDir` keeps its explicit case-fold as before (a deny, and the carve-out tests already assume a case-insensitive volume). Also load-bearing: `ToolExecutor.writeFile` writes `atomically: true` (ToolExecutor.swift:486), so a dangling symlink as the final component is *replaced* by a regular file inside the mount rather than followed, and a dangling intermediate link fails with ENOENT — neither escapes; a link swapped between the check and the write remains the accepted residual. The reproduced case (pre-review C1): `link → <iris root>` inside a mount; `<mount>/link/../x` is refused by the `..` rule on the allow side and, on the deny side, resolved to `<parent of iris root>/x` by `realPath`; `<mount>/link/config/permissions.json` resolves to the real `<iris root>/config/permissions.json` → protected, and outside every mount.

- [ ] **Step 1: Write the failing tests** — `IrisPathsTests`, appended:

```swift
    /// A temp tree: mount/ with mount/link → iris/ (a fake ~/.iris holding config/), and mount/proj/.
    private func linkTree() throws -> (base: URL, mount: URL, iris: URL, link: URL) {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-realpath-\(UUID().uuidString)")
        let mount = base.appendingPathComponent("mount"), iris = base.appendingPathComponent("iris")
        try fm.createDirectory(at: mount.appendingPathComponent("proj"), withIntermediateDirectories: true)
        try fm.createDirectory(at: iris.appendingPathComponent("config"), withIntermediateDirectories: true)
        let link = mount.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: iris)
        return (base, mount, iris, link)
    }

    private func real(_ url: URL) -> String {
        let p = realpath(url.path, nil)!; defer { free(p) }; return String(cString: p)
    }

    @Test("realPath follows a symlink before the .. that follows it, as the kernel does (§0.9)")
    func realPathIsComponentWise() throws {
        let t = try linkTree(); defer { try? FileManager.default.removeItem(at: t.base) }
        // canonicalPath collapses lexically and lands inside the mount; realPath lands where the write would.
        #expect(IrisPaths.canonicalPath(t.link.path + "/../x") == IrisPaths.canonicalPath(t.mount.path) + "/x")
        #expect(IrisPaths.realPath(t.link.path + "/../x") == real(t.base) + "/x")
        #expect(IrisPaths.realPath(t.link.path + "/config/permissions.json") == real(t.iris) + "/config/permissions.json")
        // A missing tail is appended; a `..` inside the missing tail pops lexically.
        #expect(IrisPaths.realPath(t.mount.path + "/proj/new/dir/f") == real(t.mount) + "/proj/new/dir/f")
        #expect(IrisPaths.realPath(t.mount.path + "/proj/new/../f") == real(t.mount) + "/proj/f")
        // /private is the real spelling of /tmp; both sides of every comparison go through here.
        #expect(IrisPaths.realPath("/tmp/x").hasPrefix("/private/tmp/"))
    }

    @Test("realPathForAllow refuses .. and relative paths, and otherwise equals realPath")
    func realPathForAllowRefuses() throws {
        let t = try linkTree(); defer { try? FileManager.default.removeItem(at: t.base) }
        #expect(IrisPaths.realPathForAllow(t.link.path + "/../x") == nil)
        #expect(IrisPaths.realPathForAllow(t.mount.path + "/proj/../proj/f") == nil, "any .., not only one after a link")
        #expect(IrisPaths.realPathForAllow("relative/f") == nil)
        #expect(IrisPaths.realPathForAllow("~/../x") == nil)
        #expect(IrisPaths.realPathForAllow(t.link.path + "/config/x") == IrisPaths.realPath(t.link.path + "/config/x"))
        #expect(IrisPaths.realPathForAllow(t.mount.path + "/proj/./f") == real(t.mount) + "/proj/f", "a . is not a ..")
    }

    @Test("isUnderProtectedWriteDir sees through link/.. and through the link itself (R10 hardened)")
    func protectedWriteDirSeesThroughLinks() throws {
        let t = try linkTree(); defer { try? FileManager.default.removeItem(at: t.base) }
        let paths = IrisPaths(root: t.iris)
        #expect(paths.isUnderProtectedWriteDir(t.link.path + "/config/permissions.json"))
        #expect(paths.isUnderProtectedWriteDir(t.link.path + "/../iris/config/permissions.json"),
                "the reproduced escape: lexically inside the mount, really inside config")
        #expect(!paths.isUnderProtectedWriteDir(t.mount.path + "/proj/permissions.json"))
        #expect(paths.isUnderProtectedWriteDir(t.iris.path.uppercased() + "/config/x") == paths.isUnderProtectedWriteDir(t.iris.path + "/config/x"),
                "still case-insensitive on the deny side")
    }
```
`JobGrantGateTests.swift` (new; the pure suite — the `requestApproval` suite is Task 5b's, in the same file):
```swift
import Testing
import Foundation
@testable import iris

/// #282 §3, §0.9 — the pure gate. Temp directories only.
@Suite("JobGrant.allows (#282)")
struct JobGrantAllowsTests {
    struct Tree {
        let base: URL; let proj: URL; let project: URL; let ro: URL; let inner: URL; let home: URL
        var grant: JobGrant {
            JobGrant(mounts: [ContainerMount(source: IrisPaths.canonicalPath(proj.path)),
                              ContainerMount(source: IrisPaths.canonicalPath(ro.path), readOnly: true),
                              ContainerMount(source: IrisPaths.canonicalPath(inner.path), readOnly: true)])
        }
        func tearDown() { try? FileManager.default.removeItem(at: base) }
    }

    /// proj/ (rw) with proj/locked/ (ro, nested), project/ (a sibling sharing a prefix), ro/ (ro),
    /// and a fake home holding `.iris/config`. Sources are stored the way Task 2a stores them
    /// (`canonicalPath`, i.e. `/tmp/...`), while `allows` compares real paths (`/private/tmp/...`).
    static func tree() throws -> Tree {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-gate-\(UUID().uuidString)")
        for name in ["proj/locked", "project", "ro", "home/.iris/config"] {
            try fm.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        return Tree(base: base, proj: base.appendingPathComponent("proj"), project: base.appendingPathComponent("project"),
                    ro: base.appendingPathComponent("ro"), inner: base.appendingPathComponent("proj/locked"),
                    home: base.appendingPathComponent("home"))
    }

    static func c(_ url: URL, _ tail: String = "") -> String {
        IrisPaths.canonicalPath(tail.isEmpty ? url.path : url.appendingPathComponent(tail).path)
    }
    private func c(_ url: URL, _ tail: String = "") -> String { Self.c(url, tail) }

    @Test("write_file inside a read-write mount, at the boundary, outside, one directory up, and through ..")
    func writeInsideBoundaryOutside() throws {
        let t = try Self.tree(); defer { t.tearDown() }
        let g = t.grant
        #expect(g.allows(toolName: "write_file", details: c(t.proj, "out.md"), cwd: nil))
        #expect(g.allows(toolName: "write_file", details: c(t.proj, "new/dir/out.md"), cwd: nil), "a file under a directory that does not exist yet still resolves to the mount")
        #expect(!g.allows(toolName: "write_file", details: c(t.project, "out.md"), cwd: nil), "/proj does not cover /project")
        #expect(!g.allows(toolName: "write_file", details: c(t.base, "out.md"), cwd: nil), "one directory above the mount")
        #expect(!g.allows(toolName: "write_file", details: c(t.proj) + "/../out.md", cwd: nil), ".. is refused outright")
        #expect(!g.allows(toolName: "write_file", details: c(t.proj) + "/../proj/out.md", cwd: nil), "even a .. that would land inside")
        #expect(g.allows(toolName: "write_file", details: c(t.proj), cwd: nil), "the mount itself")
        #expect(g.allows(toolName: "write_file", details: "/private" + c(t.proj, "out.md"), cwd: nil), "the real spelling of the same directory")
    }

    @Test("a relative path resolves against the working directory before it is judged")
    func relativeAgainstCwd() throws {
        let t = try Self.tree(); defer { t.tearDown() }
        #expect(t.grant.allows(toolName: "write_file", details: "out.md", cwd: c(t.proj)))
        #expect(!t.grant.allows(toolName: "write_file", details: "../out.md", cwd: c(t.proj)))
        #expect(!t.grant.allows(toolName: "write_file", details: "out.md", cwd: c(t.base)))
        #expect(!t.grant.allows(toolName: "write_file", details: "out.md", cwd: nil), "no cwd: nothing to resolve against, refused")
    }

    @Test("a symlink from inside a mount to a protected directory resolves outside and is refused, with or without a .. (§0.9)")
    func symlinkToProtected() throws {
        let t = try Self.tree(); defer { t.tearDown() }
        let link = t.proj.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: t.home.appendingPathComponent(".iris"))
        for tool in ["write_file", "read_file"] {
            #expect(!t.grant.allows(toolName: tool, details: link.path + "/config/permissions.json", cwd: nil), Comment(rawValue: tool))
            #expect(!t.grant.allows(toolName: tool, details: link.path + "/../.iris/config/permissions.json", cwd: nil), Comment(rawValue: tool))
        }
        // The lexical form of that last path is inside the mount — which is exactly the trap.
        #expect(IrisPaths.canonicalPath(link.path + "/../.iris/config/permissions.json").hasPrefix(c(t.proj)))
    }

    @Test("read under a read-only mount is allowed; write under it is refused; the innermost entry wins")
    func readOnlyAndInnermost() throws {
        let t = try Self.tree(); defer { t.tearDown() }
        let g = t.grant
        #expect(g.allows(toolName: "read_file", details: c(t.ro, "key"), cwd: nil))
        #expect(!g.allows(toolName: "write_file", details: c(t.ro, "key"), cwd: nil))
        #expect(!g.allows(toolName: "write_file", details: c(t.inner, "x"), cwd: nil))
        #expect(g.allows(toolName: "read_file", details: c(t.inner, "x"), cwd: nil))
        #expect(g.allows(toolName: "write_file", details: c(t.proj, "lockedfile"), cwd: nil), "a sibling name that merely starts with 'locked' is still under proj")
        #expect(g.covering(IrisPaths.realPath(c(t.inner, "x")))?.source == c(t.inner))
        #expect(g.covering(IrisPaths.realPath(c(t.project, "x"))) == nil)
    }

    @Test("run_command is true; every other tool is false; a mountless grant allows only run_command")
    func runCommandAndTheRest() throws {
        let t = try Self.tree(); defer { t.tearDown() }
        #expect(t.grant.allows(toolName: "run_command", details: "rm -rf /", cwd: nil))
        for tool in ["create_skill", "update_memory", "save_fact", "gmail_send_email", "register_directory_watcher", "set_workspace"] {
            #expect(!t.grant.allows(toolName: tool, details: c(t.proj, "x"), cwd: nil), Comment(rawValue: tool))
        }
        let netOnly = JobGrant(network: true)
        #expect(netOnly.allows(toolName: "run_command", details: "curl x", cwd: nil))
        #expect(!netOnly.allows(toolName: "write_file", details: c(t.proj, "x"), cwd: nil))
        #expect(netOnly.nearest(to: c(t.proj, "x"), cwd: nil) == nil)
    }

    @Test("nearest names the granted directory sharing the longest prefix with the path")
    func nearestDirectory() throws {
        let t = try Self.tree(); defer { t.tearDown() }
        #expect(t.grant.nearest(to: c(t.base, "out.md"), cwd: nil) == c(t.proj), "a tie between proj and ro goes to the earlier entry")
        #expect(t.grant.nearest(to: c(t.ro, "sub/x"), cwd: nil) == c(t.ro))
        #expect(t.grant.nearest(to: c(t.proj, "locked/deeper/x"), cwd: nil) == c(t.inner))
        #expect(t.grant.nearest(to: "/nowhere/x", cwd: nil) == c(t.proj), "nothing shared beyond / still names something")
        #expect(t.grant.nearest(to: c(t.proj) + "/../x", cwd: nil) == c(t.proj), "a refused .. path is still told where the grant is")
    }
}
```
`JobRunnerTests` — beside `failureReasonNamesTheBlockedTool` (:121):
```swift
    @Test("a call blocked outside a grant names the nearest granted directory")
    func failureReasonNamesTheNearestGrantedDirectory() {
        #expect(JobRunner.failureReason(status: .blockedOnApproval, messages: [], blockedTool: "write_file",
                                        blockedNearest: "/Users/me/proj")
                == "needs approval: write_file outside the grant (nearest: /Users/me/proj)")
        #expect(JobRunner.failureReason(status: .blockedOnApproval, messages: [], blockedTool: "write_file")
                == "needs approval: write_file")
    }
```

What turns each red once green: `realPathIsComponentWise` — standardising before resolving (the old `canonicalPath` shape); `realPathForAllowRefuses` — dropping the `..`/absolute guard; `protectedWriteDirSeesThroughLinks` — `isUnderProtectedWriteDir` left on `canonicalPath`; `writeInsideBoundaryOutside` — a `hasPrefix` without the `/`, resolving only one side to a real path (the `/private` case), or accepting `..`; `relativeAgainstCwd` — resolving without `cwd`, or accepting a relative path with none; `symlinkToProtected` — comparing lexical paths; `readOnlyAndInnermost` — taking the first match instead of the longest; `runCommandAndTheRest` — a `default: true`; `nearestDirectory` — choosing the last tie, or returning nil for a `..` path; the runner case — `failureReason` ignoring `blockedNearest`.

- [ ] **Step 2: Run to verify they fail** — `scripts/test-filter.sh IrisPathsTests` and `scripts/test-filter.sh JobGrantAllowsTests`; Expected: compile errors (`realPath`, `allows`).

- [ ] **Step 3: `IrisPaths.realPath` / `realPathForAllow`; harden `isUnderProtectedWriteDir`** — IrisPaths.swift, beside `canonicalPath` (:167-182):
```swift
    /// The path the kernel would act on (#282 §0.9): tilde expanded, then `realpath(3)` of the
    /// deepest existing ancestor of the *unstandardised* components — so a symlink is followed
    /// before a `..` that follows it, which is the one thing `canonicalPath` gets wrong — with
    /// the remaining components appended. A `..` among the missing tail pops lexically: a
    /// directory that does not exist cannot be a symlink. `canonicalPath` stays for the callers
    /// that store and display paths; this is for deciding.
    static func realPath(_ rawPath: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: expanded).path
        let components = absolute.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            .filter { $0 != "." }
        let fm = FileManager.default
        var existing = components.count
        var prefix = "/" + components.joined(separator: "/")
        while existing > 0, !fm.fileExists(atPath: prefix) {
            existing -= 1
            prefix = "/" + components[0..<existing].joined(separator: "/")
        }
        var resolved: String
        if let real = Darwin.realpath(prefix, nil) {
            resolved = String(cString: real)
            free(real)
        } else {
            resolved = prefix
        }
        for component in components[existing...] {
            if component == ".." {
                resolved = (resolved as NSString).deletingLastPathComponent
            } else {
                resolved = (resolved as NSString).appendingPathComponent(component)
            }
        }
        return resolved
    }

    /// `realPath` for an *allow*: nil when the path is not absolute after tilde expansion or any
    /// component is `..` (§0.9) — a model never needs either inside a grant, and refusing them
    /// costs nothing a person could not have phrased without them.
    static func realPathForAllow(_ rawPath: String) -> String? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        guard !expanded.split(separator: "/").contains("..") else { return nil }
        return realPath(expanded)
    }
```
`isUnderProtectedWriteDir` (:159-165): replace both `Self.canonicalPath(…)` with `Self.realPath(…)`; the comment gains "Real paths, not `canonicalPath`: that one collapses `..` before following a symlink, and `link/../config` with `link → ~/.iris` is inside `config` on disk and outside it lexically (#282 §0.9)."

- [ ] **Step 4: `JobGrant.allows`/`covering`/`nearest`** — append to `JobGrant.swift`
```swift
extension JobGrant {
    private static func isUnder(_ path: String, _ source: String) -> Bool {
        path == source || path.hasPrefix(source.hasSuffix("/") ? source : source + "/")
    }

    /// Each mount with its source taken to the real path, so a source stored as `/tmp/x` meets a
    /// candidate that resolved to `/private/tmp/x`. A source that will not resolve covers nothing.
    private var realMounts: [(mount: ContainerMount, real: String)] {
        mounts.compactMap { mount in IrisPaths.realPathForAllow(mount.source).map { (mount, $0) } }
    }

    func covering(_ realPath: String) -> ContainerMount? {
        realMounts.filter { Self.isUnder(realPath, $0.real) }.max { $0.real.count < $1.real.count }?.mount
    }

    /// The path a file-tool call would actually touch, or nil when it cannot be judged for an allow
    /// (relative with no cwd, or any `..`).
    private static func allowPath(_ details: String, cwd: String?) -> String? {
        IrisPaths.realPathForAllow(ToolExecutor.resolvePath(details, cwd: cwd))
    }

    /// Pure (spec §3). `run_command` is the container's question — asked by the R20 check ahead
    /// of the approval gate and by `executeApprovedCall` — so the grant answers yes and nothing
    /// here ever puts a command on the host. Everything that is not the three named tools is `false`.
    func allows(toolName: String, details: String, cwd: String?) -> Bool {
        switch toolName {
        case "run_command":
            return true
        case "write_file":
            guard let path = Self.allowPath(details, cwd: cwd), let mount = covering(path) else { return false }
            return !mount.readOnly
        case "read_file":
            guard let path = Self.allowPath(details, cwd: cwd) else { return false }
            return covering(path) != nil
        default:
            return false
        }
    }

    /// For the card: the granted directory closest to where the call wanted to go, so the person
    /// can widen the grant once rather than click every time. A path refused for a `..` is still
    /// placed, by its real path, so the card can say where the grant is.
    func nearest(to details: String, cwd: String?) -> String? {
        let real = realMounts
        guard !real.isEmpty else { return nil }
        let target = URL(fileURLWithPath: IrisPaths.realPath(ToolExecutor.resolvePath(details, cwd: cwd))).pathComponents
        func shared(_ path: String) -> Int {
            zip(URL(fileURLWithPath: path).pathComponents, target).prefix { $0 == $1 }.count
        }
        var best = real[0]
        for candidate in real.dropFirst() where shared(candidate.real) > shared(best.real) { best = candidate }
        return best.mount.source
    }
}
```

- [ ] **Step 5: `BlockedCall.grantNearest` and `failureReason`** — JobRun.swift: `let grantNearest: String?` after `at`; init gains `grantNearest: String? = nil`; `CodingKeys` gains it; `init(from:)`: `grantNearest = try c.decodeIfPresent(String.self, forKey: .grantNearest)`. JobRunner.swift: `failureReason` (:1607) gains `blockedNearest: String? = nil`; the `.approval` arm returns `"needs approval: \(tool)" + (blockedNearest.map { " outside the grant (nearest: \($0))" } ?? "")`; the call at :970-972 passes `blockedNearest: blockedCall?.grantNearest`.

- [ ] **Step 6: Run to verify they pass** — `scripts/test-filter.sh IrisPathsTests`, `scripts/test-filter.sh JobGrantAllowsTests` (6), `scripts/test-filter.sh JobRunnerTests`, `scripts/test-filter.sh PermissionCarveOutTests`, `scripts/test-filter.sh PermissionManagerTests`, `scripts/test-filter.sh GateEvaluatorTests` (`mountRefusal` calls `isUnderProtectedWriteDir`), `scripts/test-filter.sh WatchRootTests`. Expected: PASS with counts.

- [ ] **Step 7: Full suite and commit**
```bash
swift test; echo exit=$?
git add Sources/iris/IrisPaths.swift Sources/iris/JobGrant.swift Sources/iris/JobRun.swift Sources/iris/JobRunner.swift Tests/irisTests/IrisPathsTests.swift Tests/irisTests/JobGrantGateTests.swift Tests/irisTests/JobRunnerTests.swift
git commit -m "feat(jobs): the grant is matched on the component-wise real path with no '..'; R10 sees through link/..; the blocked call carries the nearest granted directory (#282)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 5b: The approval branch, the notices, the `approvalOffer` correction **[§3 gate order, §0.4, §0.5, §5 notice]**

**Files:**
- Modify: `Sources/iris/AppState.swift:2192-2219` (the background branch), `:2356-2372` (`outsideGrantDenialNotice`, `recordBackgroundDenial`)
- Modify: `Sources/iris/JobRunner.swift:1044-1063` (`approvalOffer`)
- Modify: `Sources/iris/EventCard.swift:300-308` (`displayCopy` passes `grantNearest` through — nit)
- Test: `Tests/irisTests/JobGrantGateTests.swift` (second suite, through `requestApproval`), `Tests/irisTests/ApproveAndRunTests.swift:~330-370` (`verdictFollowsTheExecutorsSandboxRule` restated), `Tests/irisTests/BackgroundApprovalTests.swift` (unchanged; restated by name below)

**Interfaces:**
- Consumes: `JobGrant.allows`, `nearest`, `BlockedCall.grantNearest`, `IrisPaths.realPath` (Task 5a); `Conversation.sandboxGrant` (Task 3a); `PermissionManager.isAllowed(... isBackground:)` (:32-64), `isProtectedWrite(toolName:path:)` (:73-75); `AppState.recordBackgroundDenial` (:2368), `unattendedDenialNotice` (:2358), `profileDenialNotice` (:2363); `JobGrantAllowsTests.tree()` / `c(_:_:)` (Task 5a, reused).
- Produces:

```swift
// AppState
static let outsideGrantDenialNotice = "Not run: `%@` needs approval — outside the grant (nearest: %@) — and this is an unattended run."
// the background branch of requestApproval, in this order: R10 (explicit, first) → grant → allowlist → record
// JobRunner.approvalOffer: inSandbox: call.toolName == "run_command"
// EventCard.displayCopy(of:) keeps grantNearest
```

The branch after this task (spec §3, verbatim shape):
```
if conversation.isBackground:
    if permissions.isProtectedWrite(toolName, resolvedPath) → record(.approval) → false     (R10, absolute, first; resolvedPath via resolvePath(cwd:), judged by realPath inside)
    if let grant = conversation.sandboxGrant, grant.allows(toolName, details, workspace) → true
    if permissions.isAllowed(..., isBackground: true) → true
    record BlockedCall(.approval, grantNearest: grant?.nearest(...)) → false
```
R10 used to be reached *through* `isAllowed` (PermissionManager.swift:39-40); it is now asked explicitly first so a grant can never be consulted about a protected write, whatever a hand-edited policy row holds — and, since Task 5a, `isProtectedWrite` sees through `link/..`. `isAllowed`'s own copy stays (deny-side, harmless twice).

- [ ] **Step 1: Write the failing tests** — append to `Tests/irisTests/JobGrantGateTests.swift`:

```swift
/// The gate in its place (#282 §3): `AppState.requestApproval`'s background branch. The permission
/// layer is pointed at a temp `IrisPaths`, never `~/.iris`.
@MainActor
@Suite("JobGrant through requestApproval (#282)")
struct JobGrantApprovalTests {
    private typealias Tree = JobGrantAllowsTests.Tree
    private func c(_ url: URL, _ tail: String = "") -> String { JobGrantAllowsTests.c(url, tail) }

    private func background(_ t: Tree, grant: JobGrant?) -> (AppState, UUID) {
        let app = AppState()
        app.permissions = PermissionManager(paths: IrisPaths(root: t.home.appendingPathComponent(".iris")))
        let cid = app.createNewConversation(isBackground: true, select: false)
        app.setWorkspace(for: cid, path: c(t.proj))
        app.setSandboxGrant(for: cid, grant)
        return (app, cid)
    }

    @Test("a granted background conversation runs a write inside the grant without a denial or a dialog")
    func grantedWriteIsAllowed() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let (app, cid) = background(t, grant: t.grant)
        let ok = await app.requestApproval(toolName: "write_file", details: "out.md",
                                           args: ["path": .string("out.md")], workspace: c(t.proj), conversationId: cid)
        #expect(ok)
        #expect(app.pendingApprovals.isEmpty && app.takeBackgroundDenials(for: cid).isEmpty)
        #expect(app.conversations.first { $0.id == cid }?.messages.isEmpty == true)
    }

    @Test("R10 is asked first: a grant that somehow covers a protected directory still cannot write into it")
    func protectedWriteBeatsTheGrant() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        // Never creatable through the tools (Task 2a refuses ~/.iris), so built by hand.
        let rogue = JobGrant(mounts: [ContainerMount(source: c(t.home, ".iris"))])
        let (app, cid) = background(t, grant: rogue)
        let target = c(t.home, ".iris/config/permissions.json")
        let ok = await app.requestApproval(toolName: "write_file", details: target,
                                           args: ["path": .string(target)], workspace: c(t.proj), conversationId: cid)
        #expect(!ok)
        let denial = try #require(app.takeBackgroundDenials(for: cid).first)
        #expect(denial.reason == .approval && denial.grantNearest == nil, "a protected write is refused as R10, not as 'outside the grant'")
    }

    @Test("the reproduced escape — link/../ into ~/.iris from inside a read-write mount — is recorded as R10, for both tools (§0.9)")
    func linkDotDotIsRecordedAsProtected() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let link = t.proj.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: t.home.appendingPathComponent(".iris"))
        let (app, cid) = background(t, grant: t.grant)
        let escape = link.path + "/../.iris/config/permissions.json"
        #expect(!(await app.requestApproval(toolName: "write_file", details: escape, args: ["path": .string(escape)],
                                            workspace: c(t.proj), conversationId: cid)))
        let denial = try #require(app.takeBackgroundDenials(for: cid).first)
        #expect(denial.grantNearest == nil, "refused by R10, before the grant is read")
        #expect(app.conversations.first { $0.id == cid }?.messages.last?.content
                == String(format: AppState.unattendedDenialNotice, "write_file"))
        // A read through the same link with no `..` is outside every mount by real path: refused,
        // and named as outside the grant (reads are not R10's business).
        let read = link.path + "/config/permissions.json"
        #expect(!(await app.requestApproval(toolName: "read_file", details: read, args: ["path": .string(read)],
                                            workspace: c(t.proj), conversationId: cid)))
        #expect(app.takeBackgroundDenials(for: cid).first?.grantNearest == c(t.proj))
    }

    @Test("a miss falls to the allowlist, and a miss the allowlist does not cover is recorded with the nearest directory")
    func missFallsToAllowlistThenRecords() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let (app, cid) = background(t, grant: t.grant)
        let outside = c(t.base, "elsewhere.md")
        let rules = t.proj.appendingPathComponent(".iris")
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        try JSONEncoder().encode([PermissionRule(toolName: "write_file", details: outside)])
            .write(to: rules.appendingPathComponent("permissions.json"))
        #expect(await app.requestApproval(toolName: "write_file", details: outside, workspace: c(t.proj), conversationId: cid))

        let other = c(t.base, "other.md")
        #expect(!(await app.requestApproval(toolName: "write_file", details: other, args: ["path": .string(other)],
                                            workspace: c(t.proj), conversationId: cid)))
        let denial = try #require(app.takeBackgroundDenials(for: cid).first)
        #expect(denial.grantNearest == c(t.proj))
        let notice = String(format: AppState.outsideGrantDenialNotice, "write_file", c(t.proj))
        #expect(app.conversations.first { $0.id == cid }?.messages.last?.content == notice)
    }

    @Test("an ungranted background conversation is exactly as before: denied, recorded, the old notice")
    func ungrantedUnchanged() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let (app, cid) = background(t, grant: nil)
        let target = c(t.proj, "x.md")
        #expect(!(await app.requestApproval(toolName: "write_file", details: target, workspace: c(t.proj), conversationId: cid)))
        #expect(app.takeBackgroundDenials(for: cid).first?.grantNearest == nil)
        #expect(app.conversations.first { $0.id == cid }?.messages.last?.content
                == String(format: AppState.unattendedDenialNotice, "write_file"))
    }

    @Test("a read-only profile refuses a granted call before approval is ever asked (R13 untouched)")
    func readOnlyProfileRefusesFirst() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.permissions = PermissionManager(paths: IrisPaths(root: t.home.appendingPathComponent(".iris")))
        let target = c(t.proj, "x.md")
        let call = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
            Part(functionCall: FunctionCall(name: "write_file", args: ["path": .string(target), "content": .string("hi")]))]))],
                                  usageMetadata: nil)
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: [call]),
                                protectionEnabled: false, sessionPeerCount: 0)
        let cid = state.createNewConversation(isBackground: true, select: false)
        state.setJobProfile(for: cid, .readOnly)
        state.setSandboxGrant(for: cid, t.grant)          // a contradiction Task 2a refuses at creation; the profile still wins
        await engine.processInput("go", source: "job:x", conversationId: cid)
        let denial = try #require(state.takeBackgroundDenials(for: cid).first)
        #expect(denial.reason == .profile)
        #expect(!FileManager.default.fileExists(atPath: target))
    }
}
```

What turns each red once green: `grantedWriteIsAllowed` — the grant step after the record; `protectedWriteBeatsTheGrant` — the grant step before R10; `linkDotDotIsRecordedAsProtected` — R10 still on `canonicalPath`, or the explicit R10 check missing (the grant would then judge `link/..` and refuse it as "outside", with a nearest); `missFallsToAllowlistThenRecords` — omitting `grantNearest` from the recorded call or the allowlist step; `ungrantedUnchanged` — using the new notice for every denial; `readOnlyProfileRefusesFirst` — moving `profileRefusal` after the approval gate.

`ApproveAndRunTests.verdictFollowsTheExecutorsSandboxRule` (:~330-370) → renamed `verdictFollowsTheToolsActualPath`: the first block expects the **host** context — `#expect(!writeSpy.lastPrompt.contains(inVM), "a write_file runs on the host whatever the profile; the verdict is asked about the host")`; the `run_command` and `send_mail` blocks are unchanged. Red if `approvalOffer` keeps `job.profile == .mutating ||`.

Kept green and restated by name (run them, quote the counts): `BackgroundApprovalTests` (5 — the fail-closed branch with no grant), `PermissionCarveOutTests` and `PermissionManagerTests` (R10), `JobProfileTests` (R13), `SelfWriteHookTests.everyDeclaredToolIsClassified`, `ToolSurfaceTrimTests`, `UnattendedWorkspaceTests` (Task 4b).

- [ ] **Step 2: Run to verify they fail** — `scripts/test-filter.sh JobGrantApprovalTests`; Expected: `grantedWriteIsAllowed` fails (`ok == false`), `missFallsToAllowlistThenRecords` fails on `grantNearest`, the rest compile and pass or fail on the notice.

- [ ] **Step 3: `AppState.requestApproval`** (:2210-2219) becomes
```swift
        if let id = conversationId, let conversation = conversations.first(where: { $0.id == id }), conversation.isBackground {
            // R10 first and on its own (#282 §3): a write into a protected directory is refused
            // before any grant is consulted, whatever a stored grant happens to say. The path is
            // resolved against the run's directory; `isProtectedWrite` judges it by real path (§0.9).
            let resolvedPath = ToolExecutor.resolvePath(details, cwd: workspace)
            if permissions.isProtectedWrite(toolName: toolName, path: resolvedPath) {
                recordBackgroundDenial(call: BlockedCall(toolName: toolName, args: args, cwd: workspace, reason: .approval), in: id)
                return false
            }
            // §0.4, §0.5: inside the grant, no human is needed. A `run_command` reaching here has
            // already passed the R20 check in the dispatcher, so "yes" is a sandboxed yes.
            if let grant = conversation.sandboxGrant, grant.allows(toolName: toolName, details: details, cwd: workspace) {
                return true
            }
            if permissions.isAllowed(toolName: toolName, details: details, workspace: workspace, isBackground: true) {
                return true
            }
            recordBackgroundDenial(call: BlockedCall(toolName: toolName, args: args, cwd: workspace, reason: .approval,
                                                     grantNearest: conversation.sandboxGrant?.nearest(to: details, cwd: workspace)),
                                   in: id)
            return false
        }
```
Beside `unattendedDenialNotice` (:2358):
```swift
    /// The same line for a granted run's call that fell outside the grant (#282 §5): it names the
    /// nearest granted directory so the person can widen once.
    static let outsideGrantDenialNotice = "Not run: `%@` needs approval — outside the grant (nearest: %@) — and this is an unattended run."
```
`recordBackgroundDenial` (:2368-2372):
```swift
        let notice: String
        if call.reason == .profile { notice = String(format: Self.profileDenialNotice, call.toolName) }
        else if let nearest = call.grantNearest { notice = String(format: Self.outsideGrantDenialNotice, call.toolName, nearest) }
        else { notice = String(format: Self.unattendedDenialNotice, call.toolName) }
        appendMessage(role: .system, content: notice, to: conversationId)
```

- [ ] **Step 4: `approvalOffer` and `displayCopy`** — JobRunner.swift:1059: `let sandboxed = call.toolName == "run_command"`, comment rewritten: a `write_file` runs on the host at the granted path whatever the profile (§3), so the verdict is asked about the host; only a command is the container's. EventCard.swift:306-307: `BlockedCall(toolName: call.toolName, args: args, cwd: call.cwd, reason: call.reason, at: call.at, grantNearest: call.grantNearest)` — the card's display copy keeps what the row knows.

- [ ] **Step 5: Run to verify they pass** — `scripts/test-filter.sh JobGrantApprovalTests` (6), `scripts/test-filter.sh ApproveAndRunTests`, `scripts/test-filter.sh BackgroundApprovalTests`, `scripts/test-filter.sh PermissionCarveOutTests`, `scripts/test-filter.sh JobProfileTests`, `scripts/test-filter.sh SelfWriteHookTests`, `scripts/test-filter.sh EventCardTests`. Expected: PASS with counts.

- [ ] **Step 6: Full suite and commit**
```bash
swift test; echo exit=$?
git add Sources/iris/AppState.swift Sources/iris/JobRunner.swift Sources/iris/EventCard.swift Tests/irisTests/JobGrantGateTests.swift Tests/irisTests/ApproveAndRunTests.swift
git commit -m "feat(jobs): the approval gate allows a granted run's file tools inside the grant after R10 and before the allowlist; the outside-the-grant notice; Vibecop is asked about the path a tool actually takes (#282)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 6: Visibility — `/jobs` grant line and column, `list_jobs`, the card's `network`, the reasons on the surfaces **[§5]**

**Files:**
- Modify: `Sources/iris/JobsCommand.swift:138-187` (`render`: grant paragraphs beneath the table, beside the watch lines), `:244-262` (`policySummary`: `grant`), new `grantLine(job:)`
- Modify: `Sources/iris/iris.swift:3461-3506` (`jobsListJSON`: `grants`), `:3433-3439` (`list_jobs` description names `grants`)
- Modify: `Sources/iris/EventCard.swift:16-96` (`let network: Bool`, init default `false`), `:102-142` (`decodeIfPresent ?? false`), `:372-391` (`metadataLine`, `transcriptLine`)
- Modify: `Sources/iris/JobRunner.swift:1001-1017`, `:1223-1226`, `:1435-1440` (pass `network:` at the three card sites)
- Test: `Tests/irisTests/JobsCommandTests.swift` (extend), `Tests/irisTests/JobToolsTests.swift` (extend `listJobsFigures` idiom), `Tests/irisTests/EventCardTests.swift` (extend; `card(...)` helper :15-35 gains `network: Bool = false`), `Tests/irisTests/JobRunnerGrantTests.swift` (one card assertion)

**Interfaces:**
- Consumes: `JobGrant.describe()` (Task 2a), `JobPolicy.grants` (Task 1), `JobRunner.grantSourceUnavailableReason` / `isolatedNetworkUnavailableReason` (Task 3b), `BlockedCall.grantNearest` (Task 5a); `JobsCommand.failureLine` (:325-333) prints `run.failureReason`, so the fire-time reasons reach `/jobs` with no new code — the test pins that.
- Produces:

```swift
// JobsCommand
static func policySummary(for job: Job) -> String        // gains "grant" after "mutating": "mutating · grant · overlap queue"
static func grantLine(job: Job) -> String?               // "`deploy` — read-write /Users/me/proj (working directory) · read-only /Users/me/.config/gh · network on"; nil when ungranted
// jobsListJSON: per-job "grants": {"mounts":[...strings...],"network":Bool} or null
// EventCard
let network: Bool                                        // default false; decodeIfPresent ?? false; passed at the three runner card sites as `grant?.network == true` where `grant` is the profile-guarded grant of Task 3b
var metadataLine: String                                 // "… tokens" + " · network" when network, before the watch figures
var transcriptLine: String                               // + " (network)" when network
```

- [ ] **Step 1: Write the failing tests** — `JobsCommandTests`, after `watchLineWithBothHalves`:

```swift
    private func granted(_ name: String = "deploy", network: Bool = true) -> Job {
        var j = job(name)
        j.profile = .mutating
        j.policy.grants = JobGrant(mounts: [ContainerMount(source: "/Users/me/proj"),
                                            ContainerMount(source: "/Users/me/.config/gh", readOnly: true)], network: network)
        return j
    }

    @Test("a granted job shows `grant` in the policy column and one paragraph beneath the table")
    func grantLineAndColumn() throws {
        let j = granted()
        #expect(JobsCommand.policySummary(for: j) == "mutating · grant")
        let expected = "`deploy` — read-write /Users/me/proj (working directory) · read-only /Users/me/.config/gh · network on"
        #expect(JobsCommand.grantLine(job: j) == expected)
        #expect(JobsCommand.grantLine(job: job()) == nil)

        let usage = JobsCommand.UsageSnapshot(perJob: [:], global: JobsCommand.GlobalUsage(tokensToday: 10, dailyBudget: 100))
        let out = JobsCommand.render(jobs: [j, granted("second", network: false)], lastRuns: [:], usage: usage,
                                     unacknowledged: [], unreadableJobs: 0, now: Date())
        let table = try #require(out.range(of: "| deploy |"))
        let line = try #require(out.range(of: expected))
        let second = try #require(out.range(of: "`second` — read-write /Users/me/proj (working directory) · read-only /Users/me/.config/gh · network off"))
        let footer = try #require(out.range(of: "Tokens today, all jobs:"))
        #expect(table.lowerBound < line.lowerBound && line.lowerBound < second.lowerBound && second.lowerBound < footer.lowerBound)
        #expect(out.contains("\n\n" + expected + "\n\n"), "its own paragraph, not a run-on line")
    }

    @Test("the two fire-time refusals reach the failure line as written")
    func grantReasonsOnTheFailureLine() {
        let j = granted()
        let drift = run(j, status: .failed, failureReason: JobRunner.grantSourceUnavailableReason("/Users/me/proj"))
        let net = run(j, status: .failed, failureReason: JobRunner.isolatedNetworkUnavailableReason("permission denied"))
        #expect(JobsCommand.failureLine(drift).hasSuffix(" · grant source unavailable: /Users/me/proj"))
        #expect(JobsCommand.failureLine(net).hasSuffix(" · isolated network unavailable: permission denied"))
    }
```
`JobToolsTests`, after `listJobsFigures`:
```swift
    @Test("list_jobs returns grants as stored, null when absent, and the policy string says grant")
    func listJobsCarriesGrants() throws {
        var g = job("deploy")
        g.profile = .mutating
        g.policy.grants = JobGrant(mounts: [ContainerMount(source: "/p"), ContainerMount(source: "/q", target: "/gh", readOnly: true)], network: true)
        let json = IrisEngine.jobsListJSON([g, job("plain")], lastStatuses: [:], usage: .empty, unreadableJobs: 0)
        let body = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let rows = try #require(body["jobs"] as? [[String: Any]])
        let grants = try #require(rows[0]["grants"] as? [String: Any])
        #expect(grants["mounts"] as? [String] == ["/p", "/q:/gh:ro"])
        #expect(grants["network"] as? Bool == true)
        #expect((rows[0]["policy"] as? String)?.contains("grant") == true)
        #expect(rows[1]["grants"] is NSNull)
    }
```
`EventCardTests` — `card(...)` gains `network: Bool = false` passed through; add:
```swift
    @Test("a card without network decodes false, and network rides the metadata and transcript lines")
    func networkOnTheCard() throws {
        let plain = card()
        #expect(!plain.network)
        let old = try #require(EventCard.decode(plain.encodedContent().replacingOccurrences(of: "\"network\":false,", with: "")))
        #expect(!old.network, "an older card has no key and reads false")

        let net = card(network: true)
        let base = "\(net.elapsedText) · \(SessionActivity.formatTokenCount(4_200)) tokens"
        #expect(net.metadataLine == "\(base) · network")
        #expect(card(network: true, watchSummary: WatchSummary(changed: 4)).metadataLine == "\(base) · network · 4 changes")
        #expect(net.transcriptLine.hasSuffix(" swept 3 PRs (network)"))
        #expect(try #require(EventCard.decode(net.encodedContent())).network)
    }
```
(`encodedContent` sorts keys, so `"network":false,` is the exact substring; if `network` sorts last the trailing comma differs — adjust the replaced substring to `,"network":false` after one look at the JSON.)
`JobRunnerGrantTests.fireStampsWorkspaceGrantAndPin` — add: the Activity card for the run has `network == false`; add a second fire of `grantedJob(dir, network: true, name: "open")` and assert its card has `network == true`.

Red once green if: `policySummary` forgets `grant`; `grantLine` is emitted inside the table; `jobsListJSON` encodes `grants` as the policy string; `EventCard.init(from:)` uses `decode`; a card site omits `network:`.

- [ ] **Step 2: Run to verify they fail** — `scripts/test-filter.sh JobsCommandTests`; Expected: compile error `grantLine`.

- [ ] **Step 3: `JobsCommand`** — `policySummary` (:246): after the `mutating` line `if job.policy.grants != nil { parts.append("grant") }`. New:
```swift
    /// The grant paragraph beneath the table (spec §5): what a granted job may touch, in the words
    /// the result sentence used when it was created, so the two never disagree.
    static func grantLine(job: Job) -> String? {
        guard let grant = job.policy.grants else { return nil }
        return "`\(job.name)` — \(grant.describe())"
    }
```
`render` (:160-170): the `watchLines` array becomes `let extraLines = jobs.compactMap { job -> String? in if case .fsEvent = job.trigger { return watchLine(...) }; return nil } + jobs.compactMap(grantLine(job:))` — watch lines first, then grant lines, each its own paragraph, all before the daily footer.

- [ ] **Step 4: `jobsListJSON`** (:3474-3497) — add `"grants": job.policy.grants.map(jsonObject) ?? NSNull(),`; the `list_jobs` description (:3438) gains `, and \`grants\` — the directories and network a mutating job was created with, null when it has none` after `\`gateKind\` and \`profile\``.

- [ ] **Step 5: `EventCard.network`** — `let network: Bool` after `watchSummary` (:60) with the comment "whether the run's commands could reach the network — a granted job's `network: true`; false for every card written before grants and for every ungranted run"; init gains `network: Bool = false`; `init(from:)`: `network = try container.decodeIfPresent(Bool.self, forKey: .network) ?? false` (the synthesized `CodingKeys` picks the new property up). `metadataLine` (:372-376):
```swift
        var line = "\(elapsedText) · \(SessionActivity.formatTokenCount(totalTokens)) tokens"
        if network { line += " · network" }
        if let watchMetadataText { line += " · \(watchMetadataText)" }
        return line
```
`transcriptLine` (:380-391): after the watch clause `if network { line += " (network)" }`. Runner: the three `EventCard(...)` sites pass `network: grant?.network == true`, where `grant` is the profile-guarded local from Task 3b (`run` and `runApproved` have the local; `closeFailed` computes it from its `job` the same way: `job.profile == .mutating && job.policy.grants?.network == true`).

- [ ] **Step 6: Run to verify they pass** — `scripts/test-filter.sh JobsCommandTests`, `scripts/test-filter.sh JobToolsTests`, `scripts/test-filter.sh EventCardTests`, `scripts/test-filter.sh JobRunnerGrantTests`, `scripts/test-filter.sh EventDeliveryTests`. Expected: PASS with counts.

- [ ] **Step 7: Full suite and commit**
```bash
swift test; echo exit=$?
git add Sources/iris/JobsCommand.swift Sources/iris/iris.swift Sources/iris/EventCard.swift Sources/iris/JobRunner.swift Tests/irisTests/JobsCommandTests.swift Tests/irisTests/JobToolsTests.swift Tests/irisTests/EventCardTests.swift Tests/irisTests/JobRunnerGrantTests.swift
git commit -m "feat(jobs): the grant on /jobs (column and paragraph), in list_jobs, and network on the run card (#282)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Task 7: Docs falsification and the spec status line **[§7 docs, invariant 9]**

**Files:**
- Modify: `docs/jobs.md` (:15-21, :39-40, :133-193 including the deletion of :161-166, :288-300, :492-521, :523-575; new **Grants** section after Profiles), `README.md:20`, `docs/agency/agency.md:81-84, :89`, `docs/specs/2026-09-21-agency-runtime.md:14, :114, :151`, `docs/specs/2026-09-21-agency-model-and-ledger.md:271`, `docs/specs/2026-09-23-agency-job-grants.md:3` (status), `Sources/iris/Job.swift:3-11` (the `JobProfile` doc comment), `Sources/iris/ScheduleJobArguments.swift:111-120` (the `makeJob` doc comment), verify `Sources/iris/iris.swift:1204` (Task 2b) and `Sources/iris/SandboxSessionManager.swift:50-58` (Task 4b)
- Test: none new; `ToolSurfaceTrimTests.descriptionsStateTriggers` (Task 2b) and `UnattendedWorkspaceTests` (Task 4b) already pin the agent-facing changes.

- [ ] **Step 1: Search, do not compose.** Run and read every hit against the new behaviour:
```bash
grep -rn -i "behind the user's allowlist\|behind the allowlist\|no workspace and therefore no mount\|needs approval, and this is an unattended run\|stops and says so\|extraMounts\|Nothing in the app passes any yet\|Sandbox always\|never drops isolation\|deliverables 1 to 4\|unique name\|as they always do\|deterministic allowlist\|give itself a workspace\|set_workspace\|mounts: \[String\]" README.md docs/jobs.md docs/agency/agency.md docs/specs/2026-09-21-agency-runtime.md docs/specs/2026-09-21-agency-model-and-ledger.md Sources/iris/*.swift
```

- [ ] **Step 2: Fix each sentence the change made untrue.** The table below is the result of that grep at `10ba75a`, plus the three sentences the pre-review found (M3); every row is a sentence that is false once Tasks 1–6 land, with its fix. A hit not in the table (e.g. `GateEvaluator.swift:190` "stops and says so", which is about a `gate_path` walk) was read and is not falsified.

| Where | Existing sentence | Why it is now untrue | Fix |
| --- | --- | --- | --- |
| `docs/jobs.md:15` | "This document covers deliverables 1 to 4 of `#187`" | 4½ is in it | "…1 to 4½ … and `docs/specs/2026-09-23-agency-job-grants.md`" |
| `docs/jobs.md:39-40` | "Every job needs a unique name. If the requested name … is already taken, `-2`, `-3`, … is appended until it isn't." | a same-conversation explicit name now replaces | Append: "— unless you gave the name explicitly and the job with that name was created in this conversation, in which case `schedule_job` **replaces** it: schedule, prompt, profile and grant, keeping its id and run history. Omitting `mounts` and `network` on that call removes the grant." |
| `docs/jobs.md:159-161` | "a read-only run's sandboxed command cannot write to the host *because its conversation has no workspace and therefore no mount* … Anyone who gives read-only runs a workspace has to come back to this paragraph." | still true for read-only (a grant is refused on one), but the mount story has changed: a granted run's mount is fixed by the grant, not by any workspace | Append: "A grant is refused on a read-only job for exactly this reason (see Grants), and a granted `mutating` run's mounts are fixed by its grant — its working directory is the grant's first read-write entry, and nothing the run does can move it." |
| `docs/jobs.md:161-166` | "It does not carry over to `mutating`, which has `set_workspace` and can therefore give itself a workspace mid-turn, after which a command gets that directory bind-mounted read-write — no wider than the allowlist or the approval that let the command run at all (in an attended chat that same command runs on the host), and the card's `in <cwd>` line says where." | §0.10: `set_workspace` is refused and undeclared for every unattended run, a goal locked in a background conversation binds no workspace (`bindGoalWorkspace` guard, Task 4b), and a granted run's mount is the grant's | **Delete the paragraph.** In its place: "A background run cannot change its workspace at all: `set_workspace` is not offered to it and is refused if called (`Not run: a background run cannot change its workspace; widen the job's grant instead.`), and a goal locked in a background conversation binds no workspace either. An ungranted `mutating` run therefore has no mount; a granted one has exactly the grant's." |
| `docs/jobs.md:156-158` | "`set_workspace` is deliberately *not* on the list [for read-only]: a workspace is what gives a sandboxed `run_command` a read-write bind mount" | still true, and now true of every unattended run, not only read-only | Append "— and since deliverable 4½ no unattended run of either profile may call it." |
| `docs/jobs.md:176-179` | "`write_file`, `read_file` and the rest of the native tools execute on the host as they do in any run, behind the user's allowlist and the same fail-closed approval." | a grant also lets them through | "…on the host as they do in any run, behind the user's allowlist **or the job's grant** and the same fail-closed approval." |
| `docs/jobs.md:190-191` | "Everything outside the user's allowlist still fails closed inside the VM: unattended means unattended whatever the profile." | the grant is a second door | "Everything outside the user's allowlist **and the job's grant** still fails closed…" |
| `docs/jobs.md:288-300` (Watches, self-write filter) | "files written by `run_command`, on the host or in the container" — true, but silent about granted jobs | a granted job that writes into a watched folder via a command would loop | Append: "A granted job that writes into a watched folder should therefore use `write_file`, which the filter sees; a command's writes in the container it cannot." |
| `docs/jobs.md:494-497` | "A tool call from a background conversation is checked against the deterministic allowlist … and anything else is denied on the spot" | the grant is consulted between R10 and the allowlist | "…is checked, after the protected-directory rule, against the job's grant — `run_command` always, `write_file` under a read-write granted directory, `read_file` under any — then against the deterministic allowlist; anything else is denied on the spot. A call refused outside a grant says so on the card: `needs approval: write_file outside the grant (nearest: /Users/me/proj)`." |
| `docs/jobs.md:523-575` (Approve and run) | describes the approved call's conversation without the grant | the approved call reopens with the grant and is refused on drift | Add one sentence: "An approved call of a granted job runs with the same grant — the same mounts, network and working directory — and is refused, with the approval left unspent, if a granted directory has since moved (`grant source unavailable: <path>`)." |
| `docs/jobs.md` new section **Grants** after Profiles | — | §1–§5 need a home | Write: what a grant is (`mounts`, `network`), the refusals in order, the working-directory rule, the mutating-only rule, what the grant allows unattended (§3's list and what it does not change: memory/skill tools, save_fact, MCP, self-write filter), re-check at every fire and click with the two reasons, `network off` = `iris-isolated` internal network with `--no-dns` and the fail-closed create, replace/remove on re-schedule and re-register, the watched folder is not implicit, the `/jobs` column and paragraph, `list_jobs.grants`, the card's `network`, the container ends with the run, and that an older build reads a granted job as ungranted and re-saving under it drops the grant. |
| `README.md:20` | "the other tools run on the host behind the allowlist, as they always do" | a grant also lets them through | "…on the host behind the allowlist **or the job's grant**, as they always do). A `mutating` job can be created with a grant — `mounts` (read-write unless `:ro`; the first read-write one is its working directory) and `network` (off by default: the VM sits on a host-only network) — under which its commands run with those directories mounted and its `write_file`/`read_file` are allowed unattended inside them, re-checked against the disk at every fire; `/jobs` shows the grant and the card says `network` when a run had it." |
| `Sources/iris/iris.swift:1204` | "so a job whose work needs approval stops and says so." | a covered call runs | Done in Task 2b (`unless the job was created with a grant that covers it`); verify with the grep. |
| `Sources/iris/Job.swift:3-11` | "tools execute on the host behind the user's allowlist, as they do in any run" | grant | "…behind the user's allowlist or the job's grant (#282)…" |
| `Sources/iris/ScheduleJobArguments.swift:114-118` | "the rest of its tools run on the host behind the user's allowlist, as in any run" | grant | "…behind the user's allowlist or the job's grant, as in any run" |
| `Sources/iris/SandboxSessionManager.swift:52-58` | "Nothing in the app passes any yet — … `run_command` mounts only the workspace" | a granted `run_command` passes them | Rewritten in Task 4b; verify with the grep that the sentence is gone. |
| `docs/specs/2026-09-21-agency-runtime.md:14` (§0.2) | "executes host-side … bounded by the user's `permissions.json` allowlist and the background fail-closed branch" | grant | Append "— and, since deliverable 4½ (`2026-09-23-agency-job-grants.md`), by the job's grant, which allows `write_file`/`read_file` inside its mounts". |
| `docs/specs/2026-09-21-agency-runtime.md:114` (amendment 11) | "`ContainerRuntime.createDetached` and `SandboxSessionManager.run` take `mounts: [String]` and `timeoutSeconds:`" | both take `network: NetworkMode` too | Append "— and, since 4½, `network: NetworkMode` (`.default` or `.isolated(name:)`, rendered `--network <name> --no-dns`)". |
| `docs/specs/2026-09-21-agency-runtime.md:151` (Correction 10) | "the other tools take the host path under `permissions.json` and the unattended fail-closed branch" | grant | Append "Amended by 4½: a granted job's file tools are also allowed inside the grant's mounts; the VM rule is still a rule about commands." |
| `docs/specs/2026-09-21-agency-model-and-ledger.md:271` | quotes the notice "needs approval, and this is an unattended run" | a granted run's miss uses the outside-the-grant notice | Append "(for a call outside a granted run's grant the line names the nearest granted directory — 4½)". |
| `docs/agency/agency.md:81-84` | deliverables list 4 → 5 | 4½ exists | Insert "4½. **Job grants.** `mounts` and `network` on a mutating job; the file tools allowed inside the grant; the isolated network; re-checked every fire. — landed: see `docs/specs/2026-09-23-agency-job-grants.md` and `docs/jobs.md` (Grants)". |
| `docs/agency/agency.md:89` | "A waiver widens the tool allowlist inside the container; it never drops isolation." | the waiver has a shape now | Append "The waiver is the job's grant (`2026-09-23-agency-job-grants.md`): directories and a network bit, never the host." |
| `docs/specs/2026-09-23-agency-job-grants.md:3` | "Status: **proposed**" | landed | "Status: **implemented** (PR <n>, 2026-09-…)." |

- [ ] **Step 3: Re-run the grep from Step 1.** Expected: every remaining hit is one the table marks "verify" or "not falsified" (`set_workspace` hits in `iris.swift` are the declaration gate and the refusal from Task 4b; `docs/jobs.md:546` and `iris.swift:3132` "runs in the container or not at all" are about commands and stay true). `swift build` (doc comments only, but the two `.swift` edits must compile).

- [ ] **Step 4: Full suite and commit**
```bash
swift test; echo exit=$?
git add docs/jobs.md README.md docs/agency/agency.md docs/specs/2026-09-21-agency-runtime.md docs/specs/2026-09-21-agency-model-and-ledger.md docs/specs/2026-09-23-agency-job-grants.md Sources/iris/Job.swift Sources/iris/ScheduleJobArguments.swift
git commit -m "docs(jobs): grants — the Grants section, the Profiles paragraph, README, the runtime spec amendment, agency.md deliverable 4½; spec status implemented (#282)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Verification (spec §7, on screen, before the PR opens)

Launch the branch with `scripts/run-dev.sh` (a bare `swift run` hangs on a Keychain prompt). Fresh conversations; clean up the jobs and the temp folder afterwards. Record the create argv from the runner's log and both curl results in the PR body. Paths below are as Iris stores and prints them: `canonicalPath` strips `/private`, so the grant, the argv, the card and `/jobs` all say `/tmp/grant-demo` (L2); only the R10/grant *decision* uses the `/private` real path, and nothing prints that.

1. `mkdir -p /tmp/grant-demo`; in a chat: "Schedule a mutating job named grant-demo every 10 minutes with mounts /tmp/grant-demo and network off that writes hello.md into its working directory and then runs `git init && git status`." Then `/jobs run grant-demo`. Expect: one **completed** run, no approval card, `/tmp/grant-demo/hello.md` on the host, `.git` under it, and the runner's log line with `run -d --name iris-… --mount type=virtiofs,source=/tmp/grant-demo,target=/tmp/grant-demo --network iris-isolated --no-dns -w /tmp/grant-demo …`.
2. Re-schedule the same name with a prompt that runs `curl -sS -m 10 https://example.com | head -c 80` and `network: false`; `/jobs run` → the run's transcript shows curl failing (no route / could not resolve). Re-schedule with `network: true`; `/jobs run` → curl succeeds, and the card's metadata line ends `· network`.
3. Re-schedule with a prompt that writes `/tmp/outside.md` (one directory above the mount) → the run ends **blocked on approval**; `get_job_run` (or the `/jobs` failure line, when the run left no reply) shows the row's `failureReason` as `needs approval: write_file outside the grant (nearest: /tmp/grant-demo)`, and the transcript line is the outside-the-grant notice (L3: the card's one line is the model's last words when it said any, so assert on the row).
4. Register a watch on `/tmp/grant-demo` from another conversation, then `/jobs run grant-demo` with the hello.md prompt → the watch's `/jobs` line counts one own write and no watch run fires.
5. `rm -rf /tmp/grant-demo`; `/jobs run grant-demo` four times → each row `failed · grant source unavailable: /tmp/grant-demo`, the fourth leaves the job `paused: failed 3 times; paused` (the ladder as it exists).
6. `/jobs` → the policy column shows `mutating · grant` and the paragraph `` `grant-demo` — read-write /tmp/grant-demo (working directory) · network on `` beneath the table; `container list -a` shows no `iris-<conversation>` container left behind after each run.
7. (§0.10) In the granted job's prompt ask it to "set the workspace to /Users/me first" → the transcript shows `Not run: a background run cannot change its workspace; widen the job's grant instead.` and the run's `-w` in the log is still `/tmp/grant-demo`.

One PR, or two if the diff says so (behaviour: Tasks 1–5b; surface and docs: Tasks 6–7), per spec §7.

---

## Self-review

- **Spec coverage:** §0.1 grant at creation, echo, replace/remove, no card, unattended creation still refused → T2a (`resolve`), T2b (`replacedNote`, `scheduleJob` replacement, `registerWatcher` replacement; `jobCreationTools` untouched). §0.2 mounts + network only → T1/T2a. §0.3 mutating only → T2a (`grantNeedsMutating`, first refusal), T2b (both tools). §0.4 `run_command` allowed only when sandboxed → T5a (`allows` true), T5b (`readOnlyProfileRefusesFirst`; R20 in the dispatcher and `executeApprovedCall` untouched). §0.5 host file tools inside the grant → T5a/T5b. §0.6 working directory → T2a (`readOnlyFirst`), T3b (`setWorkspace`), T4b (`workspace: grant.workingDirectory`, `extraMountEntries`). §0.7 isolated network, ungranted unchanged, network-only grant → T4a (`NetworkMode`, argv, `ensureIsolatedNetwork`), T4b (`SandboxSessionManager`), T3b (fail closed on the row), T2a (`network: true` alone). §0.8 re-check at fire and click, the ladder as it exists → T3b (`drift`, `runApproved`, the four-fire test). **§0.9** real path, no `..`, R10 hardened → T5a (`IrisPaths.realPath`/`realPathForAllow`, `isUnderProtectedWriteDir`, `covering`/`allows`/`nearest`, `IrisPathsTests` on the reproduced case, `symlinkToProtected` for both tools), T5b (`linkDotDotIsRecordedAsProtected` through `requestApproval`). **§0.10** mounts a pure function of the grant, `set_workspace` refused unattended with the exact sentence, no other path moves a background `workspacePath` → T4b (`runCommand`, `movedWorkspaceDoesNotMoveTheMount`, `unattendedWorkspaceRefusal`, declaration gate, the `bindGoalWorkspace` guard, `UnattendedWorkspaceTests` ×3), T7 (docs/jobs.md:161-166 deleted, the replacement names both paths). **§0.11** explicit `network: false` is a grant on mutating, nothing on read-only → T2a (`resolve` guard, `explicitNetworkOffIsAGrant`), T2b (`makeJobStoresGrant`'s `offJob`). §1 model, lenient decode, `ContainerMount` struct, refusal order → T1, T2a. §2 container (`extraMounts`, `network`, argv, the measured `network ls` shape and `already exists`), lifecycle (`endSession`, approve-and-run with the grant, subagent inheritance), drift → T3a, T3b, T4a, T4b. §3 gate order (R10 explicit first), pure `allows`, case-sensitive allow, `set_workspace` refusal, `approvalOffer` correction → T5a, T5b, T4b. §4 tool surface, declarations, description sentence, result sentence, replacement rules, mutating watch needs the VM, `list_jobs.grants` → T2b, T6. §5 `/jobs`, card `network`, outside-the-grant notice on the `BlockedCall`, fire-time reasons → T5a, T5b, T6. §6 tests: `JobGrantTests` (T1), `JobGrantResolveTests`/`JobGrantToolTests` (T2a/T2b), `JobGrantAllowsTests`/`JobGrantApprovalTests` (T5a/T5b) including `<mount>/link/../x` both ways and `set_workspace`/moved-workspace (T4b), `JobRunnerGrantTests` (T3b), `ContainerRuntimeTests` (T4a: `id`/`configuration.name`, once, `already exists`, failed listing), rendering (T6), restated by name (T5b). §7 delivery → Verification (now seven steps); docs → T7 with the M3 rows. §8 out of scope: nothing here adds secrets, container-side file tools, grants on read-only jobs, per-command allowlists or a grant editor.
- **Pre-review findings, where each landed:** C1 → §0.9 → T5a/T5b; C2 → §0.10 → T4b (+ T7 rows, Verification 7); H1 → §0.11 → T2a/T2b; M1 → T4a (measured keys, `already exists`, failed listing); M2 → T3b Step 5 and the parameter placement after `ledger:`; M3 → T7 (three rows); L1 → T3b (`grant` profile-guarded at both sites, `readOnlyRowWithAGrantIsNotStamped`); L2 → Verification; L3 → Verification step 3; L4 → T2a (order) and T2b (`grantRefusal`); L5 → T3b (both checks kept, argued); nits → T5b (`displayCopy`), T2a (the backstop `catch` is labelled as one).
- **Departures forced by the code, each stated in its task:** `ContainerMount` was a caseless enum — T1; `schedule_job` never replaced by name — T2b; grant-worded refusals over gate/watch-worded ones — T2a; the grant is the one watcher argument replaced rather than kept when omitted — T2b; `realpath(3)` spells `/private/tmp` where `canonicalPath` spells `/tmp` and canonicalises case, so both sides of every allow comparison go through the helper, display stays `/tmp`, and `allows` has no case rule of its own — T5a; `bindGoalWorkspace` is the second writer of `workspacePath`, guarded on `isBackground` so §0.10's sentence is true of every path — T4b; the runner's `ensureIsolatedNetwork` default is `{ nil }` in T3b and real in T4b so each task builds green; the two new `JobRunner` parameters sit after `ledger:` so all 84 existing constructions (one of them multi-line) take one mechanical insertion — T3b; `EventCard`'s `CodingKeys` is synthesized — T6; the outside-the-grant text travels as `BlockedCall.grantNearest` — T5a.
- **Placeholder scan:** no TBD/TODO/"similar to"; every code step shows its code; every referenced symbol is defined in a task or exists at the cited line (`store.writer` is internal, checked by the pre-review; the `RecordingLauncher(results:)` initialiser and the `ConversationStoreTests` `write(_:_:)` helper are named where they are added or used).
- **Type consistency:** `JobGrant.resolve(mounts:network:profile:fileManager:paths:home:isVolume:)` (T2a) is what `makeJob` and `registerWatcher` call (T2b) with `ScheduleJobArguments.grantRefusal(_:mountsNamed:)` wrapping the refusal; `JobGrant.drift(_:fileManager:)` (T3b) returns `JobRunner.grantSourceUnavailableReason` (T3b); `JobRunner.init(state:engine:ledger:endSandboxSession:ensureIsolatedNetwork:…)` (T3b) is the order every test and the perl insertion use; `NetworkMode.forGrant(_:)` (T4a) and `extraMountEntries()` (T4b) are what `runCommand` passes into the six-parameter `sandboxSession` seam and `SandboxSessionManager.run(... network:)` (T4b); `IrisPaths.realPathForAllow(_:)` / `realPath(_:)` (T5a) are what `allows`/`covering`/`nearest` and `isUnderProtectedWriteDir` use; `BlockedCall(... grantNearest:)` (T5a) is what `requestApproval` records (T5b), `failureReason(... blockedNearest:)` reads (T5a) and `displayCopy` keeps (T5b); `JobGrant.describe()` (T2a) feeds `sentence`, `grantLine(job:)` (T6) and nothing else; `EventCard(network:)` (T6) is passed at the three runner sites from the profile-guarded `grant` (T3b); `openConversation(for:titled:sandboxed:grant:)` (T3b) at both call sites; `IrisEngine.unattendedWorkspaceRefusal` (T4b) is what `UnattendedWorkspaceTests` asserts and the T7 row quotes; `RecordingLauncher(results:)` (T4a Step 1) is the form `ensureIsolatedNetworkRaceAndFailure` uses; `AppState.flushSave()` (existing, :2642) is the seam `setAndClear` (T3a) calls; `bindGoalWorkspace(for:contract:paths:)` keeps its signature and returns nil for a background conversation (T4b), which `goalBindingLeavesABackgroundWorkspaceAlone` asserts.
