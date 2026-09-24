import Foundation

/// Owns one long-lived container per conversation. Commands run via `container exec`; disk state
/// persists within a session. An `actor` so concurrent tool calls serialize; an in-flight create
/// barrier keyed by conversationId ensures lazy creation happens exactly once even under actor
/// re-entrancy across the suspending `createDetached`.
actor SandboxSessionManager {
    static let namePrefix = "iris-"

    struct Session {
        let name: String
        var mountedWorkspace: String?
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

    static let shared = SandboxSessionManager(runtime: CLIContainerRuntime(),
                                              image: { ConfigManager.shared.sandboxImage })

    init(runtime: ContainerRuntime, image: @escaping @Sendable () -> String,
         mountAgreementAttempts: Int = SandboxSessionManager.mountAgreementAttempts) {
        self.runtime = runtime
        self.image = image
        self.mountAgreementAttempts = mountAgreementAttempts
    }

    func hasSession(_ id: UUID) -> Bool { sessions[id] != nil }

    private func name(for id: UUID) -> String { "\(Self.namePrefix)\(id.uuidString.lowercased())" }

    private static let resetNotice = """
    [sandbox] This session's container was reclaimed after being idle; previously installed \
    packages and temp files were cleared (your workspace files on disk are untouched). Re-run any \
    setup (installs/builds) before relying on them.
    """

    /// Runs one command in this conversation's container.
    ///
    /// `workspace` is the working directory's mount, `source[:target]`: it is mounted read-write
    /// and the container's `-w` is its target (`/` when there is none). `extraMounts` are mounted
    /// alongside it, in `source[:target][:ro]` form, and `network` is the network the container is
    /// attached to; a call that asks for a different set of any of the three than the live
    /// container has gets a fresh container, because all three are fixed when a container is
    /// created. A granted job's `run_command` passes its grant's mounts here and its network mode
    /// (#282); a gate still builds a container of its own rather than borrowing a conversation's
    /// session. `timeoutSeconds` bounds the command itself — past it the command is killed and the
    /// result reads exactly like a host timeout.
    func run(command: String, conversationId id: UUID, workspace: String?, extraMounts: [String] = [],
             network: NetworkMode = .default, timeoutSeconds: Int? = nil) async -> String {
        let wasLost = lostSessions.contains(id)
        let mounts = Self.mountList(workspace: workspace, extra: extraMounts)

        // Recreate if the workspace, the mount list or the network changed (agent-initiated — not a "loss").
        if let s = sessions[id], s.mountedWorkspace != workspace || s.mounts != mounts || s.network != network {
            await runtime.remove(name: s.name)
            sessions[id] = nil
        }

        // Capture whether this call is responsible for (re)creating the session BEFORE
        // awaiting, so the reset notice fires correctly even when multiple callers race.
        let created = (sessions[id] == nil)
        if created {
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
                await runtime.remove(name: s.name)
                sessions[id] = nil
            }
        }

        let workdir = Self.workdir(for: workspace)
        do {
            let r = try await runtime.exec(name: name(for: id), workdir: workdir, command: command,
                                           timeoutSeconds: timeoutSeconds)
            sessions[id]?.lastUsed = Date()
            return decorate(format(r), notice: wasLost && created, for: id)
        } catch {
            // A deadline is the command's answer, not a dead container. The session is intact and
            // re-running would spend the same wall clock over again, so this one does not go down
            // the self-heal path below — it is reported in the words the host path uses.
            if case ContainerRuntimeError.timedOut(let elapsed) = error {
                sessions[id]?.lastUsed = Date()
                // Decorated like any other outcome: the reset notice is written by the call that
                // recreated the container and by no other, so a timeout on that very call would
                // otherwise be the thing that loses it for good.
                return decorate(ToolExecutor.commandTimedOutMessage(seconds: timeoutSeconds.map(Double.init) ?? elapsed),
                                notice: wasLost && created, for: id)
            }
            // Nor is a cancelled turn a dead container. Tearing the session down and building a
            // new one to retry a command nobody is waiting for is work for its own sake.
            if error is CancellationError {
                return decorate("Error: the command was cancelled.", notice: wasLost && created, for: id)
            }
            // Container likely died/was reaped: mark lost, recreate once, retry.
            lostSessions.insert(id)
            await runtime.remove(name: name(for: id))
            sessions[id] = nil
            do {
                try await ensureSession(id, workspace: workspace, mounts: mounts, network: network)
                let r = try await runtime.exec(name: name(for: id), workdir: workdir, command: command,
                                               timeoutSeconds: timeoutSeconds)
                sessions[id]?.lastUsed = Date()
                return decorate(format(r), notice: true, for: id)
            } catch {
                if case ContainerRuntimeError.timedOut(let elapsed) = error {
                    sessions[id]?.lastUsed = Date()
                    return decorate(ToolExecutor.commandTimedOutMessage(seconds: timeoutSeconds.map(Double.init) ?? elapsed),
                                    notice: true, for: id)
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
    /// Always spelled `source:target`, so a bare path and its identity form compare equal.
    static func mountList(workspace: String?, extra: [String]) -> [String] {
        (workspace.map { let m = workspaceMount($0); return ["\(m.source):\(m.target)"] } ?? []) + extra
    }

    /// The container's working directory: the workspace mount's TARGET — which is the source
    /// itself unless the grant named one (#282 §0.6) — and `/` when there is no workspace at all.
    static func workdir(for workspace: String?) -> String {
        workspace.map { workspaceMount($0).target } ?? "/"
    }

    /// `source[:target]` split, identity when no target was named. Not `ContainerMount(parsing:)`:
    /// that one refuses what no container could mount, and refusing is the runtime's job at
    /// create, where an ungranted workspace has always been refused too.
    private static func workspaceMount(_ workspace: String) -> (source: String, target: String) {
        let parts = workspace.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return (parts[0], parts.count == 2 ? parts[1] : parts[0])
    }

    func endSession(_ id: UUID) async {
        // If a delete arrives while this conversation's very first `create` is still in flight
        // (no session entry yet), that just-created container won't be torn down here. It's an
        // orphan, but it's swept by `reapOrphans()` on next launch via the `iris-` prefix.
        if let s = sessions[id] { await runtime.remove(name: s.name) }
        sessions[id] = nil
        lostSessions.remove(id)
    }

    /// Deletes the containers a previous process left behind. Launch only, before anything else
    /// can have started one.
    ///
    /// Everything Iris creates carries `namePrefix`, a gate's per-evaluation container included —
    /// that is deliberate, and it is what makes a gate container a crash left behind sweepable at
    /// all. The price is that the prefix alone no longer means "an orphan", so two sets of names
    /// are spared: this manager's live sessions, and the gate containers
    /// `GateContainerRegistry` says are mid-evaluation. Nothing schedules this today; both
    /// exclusions are what keep it from killing live work if anything ever does.
    func reapOrphans() async {
        await reapOrphans(inFlightGates: await GateContainerRegistry.shared.current())
    }

    /// The sweep itself, with the in-flight gate names handed in — a test has no way to park a
    /// real gate inside its own evaluation.
    func reapOrphans(inFlightGates: Set<String>) async {
        let found = await runtime.list(prefix: Self.namePrefix)
        let spared = Set(sessions.values.map(\.name)).union(inFlightGates)
        for n in found where !spared.contains(n) { await runtime.remove(name: n) }
    }

    func reapIdle(olderThan seconds: TimeInterval, now: Date = Date()) async {
        for (id, s) in sessions where now.timeIntervalSince(s.lastUsed) > seconds {
            await runtime.remove(name: s.name)
            sessions[id] = nil
            lostSessions.insert(id)
        }
    }

    // MARK: - Helpers

    /// Ensures a container exists for `id`, coalescing concurrent first-commands onto a single
    /// create so actor re-entrancy across the suspending `createDetached` can't spawn duplicates.
    private func ensureSession(_ id: UUID, workspace: String?, mounts: [String], network: NetworkMode) async throws {
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
    private func create(_ id: UUID, workspace: String?, mounts: [String], network: NetworkMode) async throws {
        do {
            try await attemptCreate(id, workspace: workspace, mounts: mounts, network: network)
        } catch {
            // Ignoring cancellation on purpose: a cancelled create is one of the two ways this is
            // reached, and the ordinary `remove` would launch nothing at all from a cancelled task
            // — leaving behind the very container this exists to sweep up.
            await runtime.removeIgnoringCancellation(name: name(for: id))
            throw error
        }
    }

    private func attemptCreate(_ id: UUID, workspace: String?, mounts: [String], network: NetworkMode) async throws {
        // §0.7: the isolated network is made sure of before the container that needs it, and a
        // network that cannot be had fails the command closed — `networkFailed` propagates out of
        // here untouched, and `creationError` says so.
        if case .isolated(let networkName) = network {
            try await runtime.ensureIsolatedNetwork(named: networkName)
        }
        let workdir = Self.workdir(for: workspace)
        do {
            try await runtime.createDetached(name: name(for: id), image: image(),
                                             mounts: mounts, workdir: workdir, network: network)
        } catch {
            if case ContainerRuntimeError.createFailed(let msg) = error,
               ToolExecutor.sandboxSetupHint(for: msg) != nil {
                let startResult = await SandboxingManager.shared.startContainerSystem()
                if startResult.success {
                    try await runtime.createDetached(name: name(for: id), image: image(),
                                                     mounts: mounts, workdir: workdir, network: network)
                    sessions[id] = Session(name: name(for: id), mountedWorkspace: workspace,
                                           mounts: mounts, network: network, lastUsed: Date())
                    return
                }
            }
            throw error
        }
        sessions[id] = Session(name: name(for: id), mountedWorkspace: workspace,
                               mounts: mounts, network: network, lastUsed: Date())
    }

    private func format(_ r: (stdout: String, stderr: String, exitCode: Int32)) -> String {
        var result = r.stdout
        if !r.stderr.isEmpty { result += "\nStderr: " + r.stderr }
        if r.exitCode != 0, let hint = ToolExecutor.sandboxSetupHint(for: result) { return hint }
        return result.isEmpty ? "Success" : result
    }

    private func decorate(_ output: String, notice: Bool, for id: UUID) -> String {
        guard notice else { return output }
        lostSessions.remove(id)
        return Self.resetNotice + "\n\n" + output
    }

    private func creationError(_ error: Error) -> String {
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
