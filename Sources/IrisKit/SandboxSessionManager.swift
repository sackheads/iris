import CryptoKit
import Foundation

/// Owns one long-lived container per conversation. Commands run via `container exec`; disk state
/// persists within a session. An `actor` so concurrent tool calls serialize; an in-flight create
/// barrier keyed by conversationId ensures lazy creation happens exactly once even under actor
/// re-entrancy across the suspending `createDetached`.
actor SandboxSessionManager {
    /// This home's container prefix: every container Iris creates is named with it, and the
    /// launch sweeps match only it, so `~/.iris` and `~/.iris-dev` never reap each other's (#492).
    static var namePrefix: String { containerPrefix(for: IrisPaths.default.root) }

    /// `iris-h`, then 8 hex digits of the home's path hash. The `h` keeps it from ever matching
    /// a legacy `iris-<uuid>` session name, which starts with 8 hex digits and a dash too.
    static func containerPrefix(for home: URL) -> String {
        let digest = SHA256.hash(data: Data(home.standardizedFileURL.path.utf8))
        return "iris-h" + digest.prefix(4).map { String(format: "%02x", $0) }.joined() + "-"
    }

    /// The names every home shared before #492: `iris-<uuid>`, and `iris-gate-`, `iris-hook-` or
    /// `iris-run-` followed by a uuid.
    static func isLegacyName(_ name: String) -> Bool {
        guard name.hasPrefix(legacyPrefix) else { return false }
        var rest = name.dropFirst(legacyPrefix.count)
        for kind in ["gate-", "hook-", "run-"] where rest.hasPrefix(kind) {
            rest = rest.dropFirst(kind.count)
            break
        }
        return UUID(uuidString: String(rest)) != nil
    }
    private static let legacyPrefix = "iris-"

    /// Only the release app sweeps the legacy names. Until a release with #492 ships, the installed
    /// app still makes them, so a dev build sweeping them would delete its live containers.
    static func sweepsLegacyNames(_ build: BuildIdentity) -> Bool { build == .release }

    struct Session {
        let name: String
        var mountedWorkspace: ContainerMount?
        /// Every mount the container was created with, workspace included. A container's mounts
        /// are fixed at create time, so a call asking for a different set gets a different
        /// container — the same rule as a changed workspace, which is now one case of it.
        var mounts: [String]
        /// The network the container was attached to. Fixed at create time like the mounts, and
        /// compared like them: a granted run with the network off must never inherit a container
        /// somebody built on the default network (#282 §0.7).
        var network: NetworkMode
        var lastUsed: Date
    }

    private let runtime: ContainerRuntime
    private let image: @Sendable () -> String
    private var sessions: [UUID: Session] = [:]
    /// Conversations whose container was lost (idle-reaped or died mid-session). The next `run`
    /// recreates and prefixes a reset notice, distinguishing an unexpected reset from a cold start.
    private var lostSessions: Set<UUID> = []
    /// In-flight create tasks keyed by conversationId. Concurrent first-commands await the same
    /// task instead of each spawning their own container.
    private var creating: [UUID: Task<Void, Error>] = [:]
    /// Conversations whose session was closed for good (`closeSession`): a finished background
    /// run, a subagent that has returned, a deleted conversation. Each is one-shot, so a command
    /// arriving after the close can only come from a turn that ignored its cancellation, and it is
    /// refused rather than given a container that nothing but the idle reaper would end (#292).
    /// Never cleared: conversation ids are never reused, so no legitimate caller is ever waiting
    /// on the mark to lift, and clearing it on any schedule reopens the hole for a turn that is
    /// slower than that schedule. One UUID per closed conversation for the life of the process.
    private var closed: Set<UUID> = []

    static let shared = SandboxSessionManager(runtime: CLIContainerRuntime(),
                                              image: { ConfigManager.shared.sandboxImage },
                                              gitGuard: .shared)

    /// Starts the container system when a create, or the isolated-network check ahead of it,
    /// says the system is not ready — answering whether that worked. Injected so a test can drive
    /// the retry without spawning `container system start` (#293).
    private let startContainerSystem: @Sendable () async -> Bool

    /// Every container this manager has created and not yet removed, for an exiting CLI (#463).
    private let live: LiveContainerNames

    /// Watches each container's read-write repositories for config changes (#623). The process's
    /// one guard for `shared`, which host commands consult; a manager a test builds gets its own.
    private let gitGuard: GitConfigGuard

    /// The home whose `sandbox-git/` holds each repository's copy for the VM (#658).
    private let paths: IrisPaths

    /// The repositories each session made in its mounts (#658 (a)), so they don't get the next
    /// session's mount refused as a parent of the person's repositories.
    private let vmRepositories: SandboxVMRepositories

    init(runtime: ContainerRuntime, image: @escaping @Sendable () -> String,
         mountAgreementAttempts: Int = SandboxSessionManager.mountAgreementAttempts,
         startContainerSystem: @escaping @Sendable () async -> Bool = {
             await SandboxingManager.shared.startContainerSystem().success
         },
         live: LiveContainerNames = .shared, gitGuard: GitConfigGuard = GitConfigGuard(),
         paths: IrisPaths = .default) {
        self.gitGuard = gitGuard
        self.paths = paths
        self.vmRepositories = SandboxVMRepositories(paths: paths)
        self.runtime = runtime
        self.image = image
        self.mountAgreementAttempts = mountAgreementAttempts
        self.startContainerSystem = startContainerSystem
        self.live = live
    }

    func hasSession(_ id: UUID) -> Bool { sessions[id] != nil }

    func isClosed(_ id: UUID) -> Bool { closed.contains(id) }

    private func name(for id: UUID) -> String { Self.containerName(for: id) }

    /// A conversation's session container name, which is also its `GitConfigGuard` owner.
    /// Always within `ContainerNames.maxLength`: the prefix is fixed-length (`ContainerNameLengthTests`).
    static func containerName(for id: UUID) -> String { "\(namePrefix)\(id.uuidString.lowercased())" }

    private static let resetNotice = """
    [sandbox] This session's container was reclaimed after being idle; previously installed \
    packages and temp files were cleared (your workspace files on disk are untouched). Re-run any \
    setup (installs/builds) before relying on them.
    """

    /// Runs one command in this conversation's container.
    ///
    /// `workspace` is the working directory's mount: it is mounted read-write and the container's
    /// `-w` is its target (`/` when there is none). Typed, not a `source[:target]` string, so a
    /// `:` inside a host path is never read as a target — such a path reaches the runtime as the
    /// four-part entry it always was, and is refused there. `extraMounts` are mounted
    /// alongside it, in `source[:target][:ro]` form, and `network` is the network the container is
    /// attached to; a call that asks for a different set of any of the three than the live
    /// container has gets a fresh container, because all three are fixed when a container is
    /// created. A granted job's `run_command` passes its grant's mounts here and its network mode
    /// (#282); a gate still builds a container of its own rather than borrowing a conversation's
    /// session. `timeoutSeconds` bounds the command itself — past it the command is killed and the
    /// result reads exactly like a host timeout.
    /// `onNote` is told, for the person, what the sandbox's git sync did around the command (#658).
    func run(command: String, conversationId id: UUID, workspace: ContainerMount?, extraMounts: [String] = [],
             network: NetworkMode = .default, timeoutSeconds: Int? = nil,
             onNote: (@Sendable (String) async -> Void)? = nil) async -> String {
        let wasLost = lostSessions.contains(id)
        // #616: every read-write mount is recorded as writable before a container can write it.
        guard WritableRootsRecord(paths: paths).record(Self.readWriteMounts(workspace: workspace, extra: extraMounts).map(\.source)) else {
            return "Error: " + WritableRootsRecord.refusal
        }
        // #617: every read-write mount's `.iris/` goes in read-only, so a real directory must be
        // there to mount before the container is made; one that cannot be protected refuses.
        var absent: Set<String> = []
        for (source, _) in Self.readWriteMounts(workspace: workspace, extra: extraMounts) {
            for item in WorkspaceIrisDir.protected(for: source) {
                switch WorkspaceIrisDir.prepareForMount(source, item) {
                case .refused(let why): return why
                case .absent: absent.insert((source as NSString).appendingPathComponent(item.relative))
                case .ready: break
                }
            }
        }
        // #658: a repository at a read-write mount's root gets the sandbox's own git dir over
        // its common dir's path, and the person's `.git` only read-only.
        var repos: [SandboxGit.Repo] = []
        for (source, target) in Self.readWriteMounts(workspace: workspace, extra: extraMounts) {
            switch SandboxGit.prepare(source: source, target: target, paths: paths) {
            case .refused(let why): return why
            case .repo(let repo): repos.append(repo)
            case .none: break
            }
        }
        let mounts = Self.mountList(workspace: workspace, extra: extraMounts) {
            !absent.contains(($0 as NSString).appendingPathComponent($1))
        } + repos.flatMap(\.mounts)

        // Recreate if the workspace, the mount list or the network changed (agent-initiated — not a "loss").
        if let s = sessions[id], s.mountedWorkspace != workspace || s.mounts != mounts || s.network != network {
            await removeContainer(s.name)
            sessions[id] = nil
        }

        // Capture whether this call is responsible for (re)creating the session BEFORE
        // awaiting, so the reset notice fires correctly even when multiple callers race.
        let created = (sessions[id] == nil)
        let rwSources = Self.readWriteMounts(workspace: workspace, extra: extraMounts).map(\.source)
        var starts: [String: [String]] = [:]
        if created {
            // #658 (a): a read-write mount holding the person's repositories is refused here, as
            // the container is made, and never per command.
            let admission = await ParentMount.admit(rwSources, vmRecord: vmRepositories)
            if let refusal = admission.refusal { return refusal }
            starts = admission.starts
            // Asked on the far side of the barrier, and asked until the answer holds.
            // `ensureSession` coalesces concurrent first-commands onto one create, and the
            // container belongs to whichever of them got there first — including its mounts. A
            // caller that asked for a different set was never told: the check above could not fire
            // for it, because when it ran there was no session to compare against. Running anyway
            // would put a gate's script in a container with someone else's mounts, once, silently.
            //
            // A loop and not a single retry, because the recreate can be coalesced in turn onto a
            // third caller's create. Bounded, and it fails closed at the bound: a command that
            // cannot be given the mounts it asked for does not run in the ones it was handed.
            var attempts = 0
            while true {
                do { try await ensureSession(id, workspace: workspace, mounts: mounts, network: network) }
                catch { return creationError(error) }
                guard let s = sessions[id],
                      s.mounts != mounts || s.mountedWorkspace != workspace || s.network != network else { break }
                attempts += 1
                if attempts >= mountAgreementAttempts {
                    // Left standing on the way out. It is the *winner's* container — tearing it
                    // down here would fail their next command and cost them a recreate and a reset
                    // notice for a contention they had no part in. This call runs nothing, which
                    // is the whole of what it is owed.
                    return Self.mountsContendedError
                }
                await removeContainer(s.name)
                sessions[id] = nil
            }
            vmRepositories.began(owner: name(for: id), starts: starts)
        }

        let workdir = Self.workdir(for: workspace)
        // #623: the repositories it mounts read-write, recorded before its first command and
        // checked on both sides of each one; a disallowed change is put back and reported.
        let sources = Self.readWriteMounts(workspace: workspace, extra: extraMounts).map(\.source)
        let owner = name(for: id)
        gitGuard.watch(owner: owner, sources: sources)
        let gitBefore = gitGuard.check(owner: owner)
        let runtime = self.runtime
        let syncs = repos.map { repo in
            SandboxGitSync(repo: repo, vm: ContainerVMGit(repo: repo) { script in
                guard let r = try? await runtime.exec(name: owner, workdir: "/", command: script, timeoutSeconds: 120) else { return nil }
                return (r.stdout, r.exitCode)
            })
        }
        var befores: [SandboxGitSync.Before] = []
        var syncNotes: [String] = []
        for sync in syncs {
            let (before, notes) = await sync.before()
            befores.append(before)
            syncNotes += notes
        }
        func noted(_ result: String) async -> String {
            var notes = syncNotes
            for (sync, before) in zip(syncs, befores) { notes += await sync.after(before) }
            if !notes.isEmpty { await onNote?(notes.joined(separator: "\n")) }
            let synced = notes.isEmpty ? result : ([result] + notes.map { "[sandbox git] " + $0 }).joined(separator: "\n")
            return GitConfigGuard.withNotices(synced, before: gitBefore, after: gitGuard.check(owner: owner))
        }
        do {
            let r = try await runtime.exec(name: name(for: id), workdir: workdir, command: command,
                                           timeoutSeconds: timeoutSeconds, outputLimit: OutputCap.drainBytes)
            sessions[id]?.lastUsed = Date()
            return await noted(decorate(format(r), notice: wasLost && created, for: id))
        } catch {
            // A deadline is the command's answer, not a dead container. The session is intact and
            // re-running would spend the same wall clock over again, so this one does not go down
            // the self-heal path below — it is reported in the words the host path uses.
            if case ContainerRuntimeError.timedOut(let elapsed) = error {
                sessions[id]?.lastUsed = Date()
                // Decorated like any other outcome: the reset notice is written by the call that
                // recreated the container and by no other, so a timeout on that very call would
                // otherwise be the thing that loses it for good.
                return await noted(decorate(ToolExecutor.commandTimedOutMessage(seconds: timeoutSeconds.map(Double.init) ?? elapsed),
                                      notice: wasLost && created, for: id))
            }
            // Nor is a cancelled turn a dead container. Tearing the session down and building a
            // new one to retry a command nobody is waiting for is work for its own sake.
            if error is CancellationError {
                return await noted(decorate("Error: the command was cancelled.", notice: wasLost && created, for: id))
            }
            // Closed under the running command: the run is over, so there is nothing to heal.
            if closed.contains(id) { return Self.closedMidCommandError }
            // Container likely died/was reaped: mark lost, recreate once, retry.
            lostSessions.insert(id)
            await removeContainer(name(for: id))
            sessions[id] = nil
            // A new container is a new mount: checked again, with what the lost one made recorded.
            let admission = await ParentMount.admit(rwSources, vmRecord: vmRepositories)
            if let refusal = admission.refusal { return refusal }
            do {
                try await ensureSession(id, workspace: workspace, mounts: mounts, network: network)
                vmRepositories.began(owner: owner, starts: admission.starts)
                gitGuard.watch(owner: owner, sources: sources)
                let r = try await runtime.exec(name: name(for: id), workdir: workdir, command: command,
                                               timeoutSeconds: timeoutSeconds, outputLimit: OutputCap.drainBytes)
                sessions[id]?.lastUsed = Date()
                return await noted(decorate(format(r), notice: true, for: id))
            } catch {
                if case ContainerRuntimeError.timedOut(let elapsed) = error {
                    sessions[id]?.lastUsed = Date()
                    return await noted(decorate(ToolExecutor.commandTimedOutMessage(seconds: timeoutSeconds.map(Double.init) ?? elapsed),
                                          notice: true, for: id))
                }
                return creationError(error)
            }
        }
    }

    /// How many times a call will replace a container created with somebody else's mounts before
    /// giving up. Two callers racing settle on the first retry; the bound is for the pathological
    /// case where a third and a fourth keep arriving, and it exists so the loop terminates rather
    /// than because any particular number is right.
    static let mountAgreementAttempts = 3

    /// The bound this manager actually uses. Injected only so a test can force the give-up branch,
    /// which two racing callers otherwise reach by luck and a scheduler in the right mood.
    private let mountAgreementAttempts: Int

    /// What a call gets when it could not be given a container with the mounts it asked for. It
    /// is not run in the mounts it was handed: for a gate that would be the isolation the mounts
    /// exist to provide, quietly not happening.
    static let mountsContendedError = """
    Error: could not start a sandbox container with the requested mounts — another command in this \
    conversation is using different ones. Nothing was run; try again.
    """

    /// The workspace mount (read-write — the agent edits the files it is working on) followed by
    /// whatever the caller declared. Workspace first so the order a container is created with is
    /// stable, which is what makes comparing two mount lists a reliable "same container" test.
    /// Always spelled `source:target` — an identity mount of `/ws` is `/ws:/ws`, exactly the entry
    /// an ungranted workspace has always produced, so the runtime reads (and refuses) it as before.
    ///
    /// Each read-write mount is followed by its `.iris/` read-only (#617), which shadows it: in the
    /// VM, Vibecop's rules and the project allowlist cannot be written, renamed or linked over.
    /// `include` says whether a protected path (source, relative) is there to mount; the caller
    /// prepared them (`WorkspaceIrisDir.prepareForMount`), so a missing optional one is skipped.
    static func mountList(workspace: ContainerMount?, extra: [String],
                          include: (String, String) -> Bool = { _, _ in true }) -> [String] {
        func protecting(_ source: String, _ target: String) -> [String] {
            WorkspaceIrisDir.protected(for: source).filter { include(source, $0.relative) }
                .map { WorkspaceIrisDir.mountEntry(source: source, target: target, relative: $0.relative, readOnly: $0.readOnly) }
        }
        var list: [String] = []
        if let workspace {
            list.append("\(workspace.source):\(workspace.target)")
            list += protecting(workspace.source, workspace.target)
        }
        for entry in extra {
            list.append(entry)
            if let rw = readWrite(entry) { list += protecting(rw.source, rw.target) }
        }
        return list
    }

    /// The read-write mounts among the workspace and `extra`, as (source, target).
    static func readWriteMounts(workspace: ContainerMount?, extra: [String]) -> [(source: String, target: String)] {
        (workspace.map { [($0.source, $0.target)] } ?? []) + extra.compactMap(readWrite)
    }

    private static func readWrite(_ entry: String) -> (source: String, target: String)? {
        guard !ContainerMount.hasReadOnlyFlag(entry) else { return nil }
        let parts = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        return (parts[0], parts.count == 2 ? parts[1] : parts[0])
    }

    /// The container's working directory: the workspace mount's TARGET — which is the source
    /// itself unless the grant named one (#282 §0.6) — and `/` when there is no workspace at all.
    static func workdir(for workspace: ContainerMount?) -> String {
        workspace?.target ?? "/"
    }

    /// Ends this conversation's container. The conversation may start another one: the next
    /// `run` creates it. For a conversation that is finished, use `closeSession`.
    func endSession(_ id: UUID) async {
        // If a delete arrives while this conversation's very first `create` is still in flight
        // (no session entry yet), that just-created container won't be torn down here. It's an
        // orphan, but it's swept by `reapOrphans()` at the home's next launch, by its prefix.
        // `closeSession` does not have this hole: the create checks the mark before it records.
        if let s = sessions[id] { await removeContainer(s.name) }
        sessions[id] = nil
        lostSessions.remove(id)
    }

    /// Ends this conversation's container and refuses it another for the life of the process
    /// (#292). For one-shot conversations only (a background run, a subagent, a deleted
    /// conversation), whose turn can outlive its close when it ignores cancellation. Marked
    /// before the container is removed, so a command racing the removal cannot slip a new
    /// container in behind it.
    func closeSession(_ id: UUID) async {
        closed.insert(id)
        await endSession(id)
    }

    /// What `run_command` answers in a conversation whose session was closed. Nothing ran.
    static let closedSessionError =
        "Error: this run has ended; no new sandbox session will be started for it. Nothing was run."

    /// What a command gets when its run closed (and removed its container) while it ran.
    static let closedMidCommandError =
        "Error: this run has ended and its sandbox container was removed while the command ran; it was not retried."

    private struct SessionClosed: Error {}

    /// Deletes the containers a previous process left behind. Launch only, and only in the process
    /// holding the home's store lock (#463): the app's `openStore()`, and `--run-job` beside its
    /// turn (#492).
    ///
    /// Everything Iris creates carries `namePrefix`, a gate's per-evaluation container included —
    /// that is deliberate, and it is what makes a gate container a crash left behind sweepable at
    /// all. The price is that the prefix alone no longer means "an orphan", so two sets of names
    /// are spared: this manager's live sessions, the gate containers `GateContainerRegistry` says
    /// are mid-evaluation, and the one-off hook and `run_command` containers
    /// `EphemeralContainerRegistry` says are running. The CLI's sweep runs beside its turn, so the
    /// exclusions are what keep it from killing that turn's work.
    ///
    /// This is the app's launch sweep: the release app also takes the legacy shared names. `build`
    /// is a parameter only so a test can ask as the release app.
    func reapOrphans(build: BuildIdentity = .current) async {
        await reapOrphans(inFlight: Self.inFlightNow, includingLegacy: Self.sweepsLegacyNames(build))
    }

    /// `--run-job`'s sweep: this home's own prefix only, never the legacy names (#522). A release
    /// `--run-job` fires on a schedule, so sweeping them there could take a live session from a
    /// pre-#506 dev build still using the shared names. That was only ever the release app's
    /// launch to do, as it was before #506.
    func runJobSweep() async {
        await reapOrphans(inFlight: Self.inFlightNow, includingLegacy: false)
    }

    private static let inFlightNow: @Sendable () async -> Set<String> = {
        await GateContainerRegistry.shared.current()
            .union(await EphemeralContainerRegistry.shared.current())
    }

    /// The sweep with the in-flight names handed in — a test has no way to park a real gate or
    /// hook mid-run.
    func reapOrphans(inFlightGates: Set<String>, inFlightEphemeral: Set<String> = []) async {
        await reapOrphans(inFlight: { inFlightGates.union(inFlightEphemeral) })
    }

    /// The sweep itself. `inFlight` is asked after the listing, never before: a container
    /// registered and created between the two would otherwise be listed and not spared.
    /// Everything recorded in `live` is spared too: a session's name is recorded there before its
    /// create starts but joins `sessions` only once the create returns, so a sweep running beside
    /// the first command (the CLI's always does) would otherwise take it mid-create.
    func reapOrphans(inFlight: @Sendable () async -> Set<String>, includingLegacy: Bool = false) async {
        let own = Self.namePrefix
        let found = await runtime.list(prefix: includingLegacy ? Self.legacyPrefix : own)
            .filter { $0.hasPrefix(own) || (includingLegacy && Self.isLegacyName($0)) }
        let spared = Set(sessions.values.map(\.name)).union(await inFlight()).union(live.names)
        for n in found where !spared.contains(n) { await removeContainer(n) }
        // #658 (a): a session a crash or quit cut short is ended once, which only records what its
        // VM made. Its container may be gone already, so this doesn't wait on the listing.
        let record = vmRepositories
        let keep = Set(sessions.values.map(\.name)).union(await inFlight()).union(live.names)
        await OffPool.run(cancelled: ()) { _ in record.endAbandoned(except: keep) }
    }

    func reapIdle(olderThan seconds: TimeInterval, now: Date = Date()) async {
        for (id, s) in sessions where now.timeIntervalSince(s.lastUsed) > seconds {
            await removeContainer(s.name)
            sessions[id] = nil
            lostSessions.insert(id)
        }
    }

    // MARK: - Helpers

    /// Removes a container, and drops its name from the exit-now box (#463) only once the delete
    /// succeeded: a failed delete, or a plain `remove` from a cancelled task (which launches
    /// nothing), leaves the name for the CLI's exit path to delete.
    private func removeContainer(_ name: String, ignoringCancellation: Bool = false) async {
        let removed = ignoringCancellation ? await runtime.removeIgnoringCancellation(name: name)
            : await runtime.remove(name: name)
        // Only once it is gone: a container still running could write after the last check.
        if removed {
            live.remove(name); gitGuard.end(owner: name)
            let record = vmRepositories
            await OffPool.run(cancelled: ()) { _ in record.ended(owner: name) }
        }
    }

    /// Ensures a container exists for `id`, coalescing concurrent first-commands onto a single
    /// create so actor re-entrancy across the suspending `createDetached` can't spawn duplicates.
    private func ensureSession(_ id: UUID, workspace: ContainerMount?, mounts: [String], network: NetworkMode) async throws {
        if closed.contains(id) { throw SessionClosed() }
        if sessions[id] != nil { return }
        if let inflight = creating[id] {
            try await inflight.value
            // Not necessarily done: the create we waited on may have been torn down again by a
            // caller whose mounts differed, and `creating[id]` is only cleared once the task's own
            // `defer` runs, which can be after this resumes. Ask the sessions table, not the
            // barrier, and fall through to creating our own if the answer is still nothing.
            if sessions[id] != nil { return }
        }
        let task = Task<Void, Error> { [self] in try await create(id, workspace: workspace, mounts: mounts, network: network) }
        creating[id] = task
        defer { creating[id] = nil }
        try await task.value
    }

    /// Creates this conversation's container, and sweeps up after itself if it cannot.
    ///
    /// The sweep is the point. A create has a ceiling now (R31), and a create that breaches it —
    /// or is cancelled, or dies half way — kills the CLI child while the daemon may go on to
    /// finish the pull and keep `iris-<conversation>`. The name is a pure function of the
    /// conversation id, so every later command in it would then fail with "already exists" until
    /// `reapOrphans()` at the next launch. Best effort, and its own failure is ignored: the create
    /// has already failed, and this is tidying, not the answer anybody is waiting for.
    private func create(_ id: UUID, workspace: ContainerMount?, mounts: [String], network: NetworkMode) async throws {
        // §0.7: the isolated network is made sure of before the container that needs it, and a
        // network that cannot be had fails the command closed — `networkFailed` propagates out of
        // here untouched, and `creationError` says so. Before the `do`, on purpose: nothing has
        // been created yet, so there is nothing for the sweep below to stop or delete.
        if case .isolated(let networkName) = network {
            try await ensureIsolatedNetworkSelfHealing(id, named: networkName)
        }
        do {
            try await attemptCreate(id, workspace: workspace, mounts: mounts, network: network)
        } catch ContainerRuntimeError.createFailed(let message) where message == LiveContainerNames.exitingError {
            // Refused before anything was created (#463): nothing to sweep, and no delete to spawn.
            throw ContainerRuntimeError.createFailed(message)
        } catch {
            // Ignoring cancellation on purpose: a cancelled create is one of the two ways this is
            // reached, and the ordinary `remove` would launch nothing at all from a cancelled task
            // — leaving behind the very container this exists to sweep up.
            await removeContainer(name(for: id), ignoringCancellation: true)
            throw error
        }
    }

    private func attemptCreate(_ id: UUID, workspace: ContainerMount?, mounts: [String], network: NetworkMode) async throws {
        let workdir = Self.workdir(for: workspace)
        // Before the create, so a signal mid-create still deletes it; `create`'s sweep drops it.
        guard live.add(name(for: id)) else {
            throw ContainerRuntimeError.createFailed(LiveContainerNames.exitingError)
        }
        do {
            try await runtime.createDetached(name: name(for: id), image: image(),
                                             mounts: mounts, workdir: workdir, network: network)
        } catch {
            if case ContainerRuntimeError.createFailed(let msg) = error,
               ToolExecutor.sandboxSetupHint(for: msg) != nil {
                // A closed conversation never self-starts the system or retries (#292).
                try refuseIfClosed(id)
                if await startContainerSystem() {
                    try refuseIfClosed(id)
                    // The start can take seconds: an exit path that read the box meanwhile has
                    // already deleted what it held, so this retry must not create (#463).
                    guard live.add(name(for: id)) else {
                        throw ContainerRuntimeError.createFailed(LiveContainerNames.exitingError)
                    }
                    try await runtime.createDetached(name: name(for: id), image: image(),
                                                     mounts: mounts, workdir: workdir, network: network)
                    try refuseIfClosed(id)
                    sessions[id] = Session(name: name(for: id), mountedWorkspace: workspace,
                                           mounts: mounts, network: network, lastUsed: Date())
                    return
                }
            }
            throw error
        }
        try refuseIfClosed(id)
        sessions[id] = Session(name: name(for: id), mountedWorkspace: workspace,
                               mounts: mounts, network: network, lastUsed: Date())
    }

    /// A close that landed while the create was suspended: the container just made is not
    /// recorded, and `create`'s sweep deletes it.
    private func refuseIfClosed(_ id: UUID) throws {
        if closed.contains(id) { throw SessionClosed() }
    }

    /// §0.7's network check, self-healing once (#293): a listing or create that fails with a
    /// detail that reads like the container system not running gets exactly one `container system
    /// start` and a retry — the same self-heal `attemptCreate`'s `createFailed` branch does for
    /// the container itself. Any other failure (permissions, a malformed name, …) fails closed
    /// with no start attempted, per spec §0.7: this is not a general retry-on-any-failure. A
    /// conversation closed before or during the start gets neither the start nor the retry (#292).
    private func ensureIsolatedNetworkSelfHealing(_ id: UUID, named name: String) async throws {
        do {
            try await runtime.ensureIsolatedNetwork(named: name)
        } catch {
            guard case ContainerRuntimeError.networkFailed(let detail) = error,
                  ToolExecutor.sandboxSetupHint(for: detail) != nil else { throw error }
            try refuseIfClosed(id)
            guard await startContainerSystem() else { throw error }
            try refuseIfClosed(id)
            try await runtime.ensureIsolatedNetwork(named: name)
        }
    }

    private func format(_ r: ExecOutput) -> String {
        var result = r.stdout
        if !r.stderr.isEmpty { result += "\nStderr: " + r.stderr }
        if r.exitCode != 0, let hint = ToolExecutor.sandboxSetupHint(for: result) { return hint }
        // #709: a drain that dropped part of a stream says so, with the totals, as the host does.
        let dropped = r.droppedStdout + r.droppedStderr
        if dropped > 0 { result = OutputCap.cap(result, advice: .runCommand, droppedBytes: dropped) }
        return result.isEmpty ? "Success" : result
    }

    private func decorate(_ output: String, notice: Bool, for id: UUID) -> String {
        guard notice else { return output }
        lostSessions.remove(id)
        return Self.resetNotice + "\n\n" + output
    }

    private func creationError(_ error: Error) -> String {
        if error is SessionClosed { return Self.closedSessionError }
        if case ContainerRuntimeError.createFailed(let msg) = error,
           let hint = ToolExecutor.sandboxSetupHint(for: msg) {
            return hint
        }
        // A create has a ceiling of its own now, and a breach arrives here like any other failure.
        // Said in minutes and in the caller's terms: "timedOut(elapsedSeconds: 1200.4)" is the
        // error's description, not an answer.
        if case ContainerRuntimeError.timedOut = error {
            return "Error: the sandbox container did not start within \(CLIContainerRuntime.createTimeoutSeconds / 60) minutes. Try again, or check the container runtime in Settings → Sandboxing."
        }
        if case ContainerRuntimeError.invalidMount(let entry, let reason) = error {
            return "Error: the mount `\(entry)` cannot be used — \(reason)."
        }
        if case ContainerRuntimeError.networkFailed(let detail) = error { return Self.isolatedNetworkError(detail) }
        return "Error: could not start the sandbox container: \(error)"
    }

    /// What a granted run gets when the isolated network it needs could not be listed or created.
    /// Nothing ran: a command that was granted no network does not run on the default one.
    static func isolatedNetworkError(_ detail: String) -> String {
        "Error: isolated network unavailable: \(detail). Nothing was run."
    }
}
