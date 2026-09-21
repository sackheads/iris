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

    init(runtime: ContainerRuntime, image: @escaping @Sendable () -> String) {
        self.runtime = runtime
        self.image = image
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
    /// `extraMounts` are mounted alongside the workspace, in `source[:target][:ro]` form; a call
    /// that asks for a different set than the live container has gets a fresh container, because
    /// mounts are fixed when a container is created. `timeoutSeconds` bounds the command itself —
    /// past it the command is killed and the result reads exactly like a host timeout.
    func run(command: String, conversationId id: UUID, workspace: String?,
             extraMounts: [String] = [], timeoutSeconds: Int? = nil) async -> String {
        let wasLost = lostSessions.contains(id)
        let mounts = Self.mountList(workspace: workspace, extra: extraMounts)

        // Recreate if the workspace or the mount list changed (agent-initiated — not a "loss").
        if let s = sessions[id], s.mountedWorkspace != workspace || s.mounts != mounts {
            await runtime.remove(name: s.name)
            sessions[id] = nil
        }

        // Capture whether this call is responsible for (re)creating the session BEFORE
        // awaiting, so the reset notice fires correctly even when multiple callers race.
        let created = (sessions[id] == nil)
        if created {
            do { try await ensureSession(id, workspace: workspace, mounts: mounts) }
            catch { return creationError(error) }
            // Asked again on the far side of the barrier. `ensureSession` coalesces concurrent
            // first-commands onto one create, and the container belongs to whichever of them got
            // there first — including its mounts. A caller that asked for a different set was
            // never told; the check above could not fire for it, because at the time it ran there
            // was no session to compare against. Running anyway would put a gate's script in a
            // container with someone else's mounts, once, silently, and the mismatch would only
            // surface on the next call.
            if let s = sessions[id], s.mounts != mounts || s.mountedWorkspace != workspace {
                await runtime.remove(name: s.name)
                sessions[id] = nil
                do { try await ensureSession(id, workspace: workspace, mounts: mounts) }
                catch { return creationError(error) }
            }
        }

        let workdir = workspace ?? "/"
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
                try await ensureSession(id, workspace: workspace, mounts: mounts)
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

    /// The workspace mount (read-write — the agent edits the files it is working on) followed by
    /// whatever the caller declared. Workspace first so the order a container is created with is
    /// stable, which is what makes comparing two mount lists a reliable "same container" test.
    static func mountList(workspace: String?, extra: [String]) -> [String] {
        (workspace.map { ["\($0):\($0)"] } ?? []) + extra
    }

    func endSession(_ id: UUID) async {
        // If a delete arrives while this conversation's very first `create` is still in flight
        // (no session entry yet), that just-created container won't be torn down here. It's an
        // orphan, but it's swept by `reapOrphans()` on next launch via the `iris-` prefix.
        if let s = sessions[id] { await runtime.remove(name: s.name) }
        sessions[id] = nil
        lostSessions.remove(id)
    }

    func reapOrphans() async {
        for n in await runtime.list(prefix: Self.namePrefix) { await runtime.remove(name: n) }
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
    private func ensureSession(_ id: UUID, workspace: String?, mounts: [String]) async throws {
        if sessions[id] != nil { return }
        if let inflight = creating[id] {
            try await inflight.value
            // Not necessarily done: the create we waited on may have been torn down again by a
            // caller whose mounts differed, and `creating[id]` is only cleared once the task's own
            // `defer` runs, which can be after this resumes. Ask the sessions table, not the
            // barrier, and fall through to creating our own if the answer is still nothing.
            if sessions[id] != nil { return }
        }
        let task = Task<Void, Error> { [self] in try await create(id, workspace: workspace, mounts: mounts) }
        creating[id] = task
        defer { creating[id] = nil }
        try await task.value
    }

    private func create(_ id: UUID, workspace: String?, mounts: [String]) async throws {
        do {
            try await runtime.createDetached(name: name(for: id), image: image(),
                                             mounts: mounts, workdir: workspace ?? "/")
        } catch {
            if case ContainerRuntimeError.createFailed(let msg) = error,
               ToolExecutor.sandboxSetupHint(for: msg) != nil {
                let startResult = await SandboxingManager.shared.startContainerSystem()
                if startResult.success {
                    try await runtime.createDetached(name: name(for: id), image: image(),
                                                     mounts: mounts, workdir: workspace ?? "/")
                    sessions[id] = Session(name: name(for: id), mountedWorkspace: workspace,
                                           mounts: mounts, lastUsed: Date())
                    return
                }
            }
            throw error
        }
        sessions[id] = Session(name: name(for: id), mountedWorkspace: workspace,
                               mounts: mounts, lastUsed: Date())
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
        if case ContainerRuntimeError.invalidMount(let entry, let reason) = error {
            return "Error: the mount `\(entry)` cannot be used — \(reason)."
        }
        return "Error: could not start the sandbox container: \(error)"
    }
}
