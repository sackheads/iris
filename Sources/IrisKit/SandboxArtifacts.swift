import Foundation

/// Moving an artifact's bytes into and out of a sandboxed session's container (#469 3b, rulings C
/// and D). Both run the `container` CLI through `ProcessGroupRunner`: bounded by a deadline, killed
/// by its ladder, and joined to `LiveProcessGroups` (Invariant 4). Killing the client doesn't reach
/// the VM, so each command runs under `CLIContainerRuntime.recordingWrapper`, and the kill ladder
/// fires its `groupKiller` in the container, as `CLIContainerRuntime.exec` does (#353, #760 review):
/// a FIFO the VM put in the path can't leave a blocked `cat` there for the session's life.
enum SandboxArtifacts {
    /// Where a received artifact is put in the receiver's container (C).
    static let vmDirectory = "/tmp/iris-artifacts"
    static func vmPath(_ sha: String) -> String { vmDirectory + "/" + sha }
    /// How long a copy in or a read out may take.
    static let timeoutSeconds: Double = 120

    /// One `container` invocation: the arguments, the bytes for its stdin, the deadline, the most
    /// of its stdout to keep, and the `container` arguments that kill it in the VM, fired once the
    /// ladder has killed the client. Injectable so a test needs no binary, daemon or VM.
    typealias Run = @Sendable (_ arguments: [String], _ stdin: Data?, _ timeoutSeconds: Double,
                               _ outputLimit: Int?, _ killer: [String]) async -> Result<ProcessGroupRunner.Output, Error>

    static func liveRun(binary: String) -> Run {
        { arguments, stdin, timeout, limit, killer in
            await ProcessGroupRunner(outputLimit: limit).run(
                executable: binary, arguments: arguments, environment: nil, currentDirectory: nil, stdin: stdin,
                timeoutSeconds: timeout,
                onKilled: { BlockingSpawn.detached(binary, killer, timeoutSeconds: Double(CLIContainerRuntime.housekeepingTimeoutSeconds)) })
        }
    }

    /// `container exec [-i] <container> bash -c <wrapper> iris-exec <command>`, and its in-VM killer.
    static func wrapped(_ command: String, container: String, stdin: Bool) -> (run: [String], killer: [String]) {
        let pidFile = CLIContainerRuntime.execPidFile(token: UUID().uuidString)
        return (["exec"] + (stdin ? ["-i"] : []) + [container, "bash", "-c", CLIContainerRuntime.recordingWrapper(pidFile), "iris-exec", command],
                ["exec", container, "bash", "-c", CLIContainerRuntime.groupKiller(pidFile)])
    }

    /// Copies `data` into `container` at `vmPath(sha)`: written beside it and renamed, so a reader
    /// never sees half a file, after removing whatever was at the temporary name (a FIFO there
    /// would block the write). The path is fixed, never one the model or a peer chose, so the
    /// shell line has nothing of theirs in it. Nil on success, else why it wasn't copied.
    static func materialize(_ data: Data, sha: String, container: String, run: Run) async -> String? {
        let path = vmPath(sha)
        let call = wrapped("mkdir -p \(vmDirectory) && rm -f -- \(path).part && cat > \(path).part && mv -f -- \(path).part \(path)",
                           container: container, stdin: true)
        switch await run(call.run, data, timeoutSeconds, 4_096, call.killer) {
        case .failure(let error): return "it couldn't be copied into your sandbox: \(error.localizedDescription)"
        case .success(let out):
            if out.timedOut { return "copying it into your sandbox took over \(Int(timeoutSeconds)) seconds" }
            guard out.status == 0 else {
                let said = String(decoding: out.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return "it couldn't be copied into your sandbox (exit \(out.status)\(said.isEmpty ? "" : ": " + said.prefix(200)))"
            }
            return nil
        }
    }

    /// The in-VM command that reads `path`: only a regular file (a FIFO or device is refused
    /// before `cat` could block on it; one swapped in after the test is ended by the kill), the
    /// path single-quoted into one literal word.
    static func readCommand(_ path: String) -> String {
        let quoted = PluginAuthRunner.shellQuoted(path)
        return "test -f \(quoted) || { echo 'not a regular file' >&2; exit 66; }; exec cat -- \(quoted)"
    }

    /// A file in `container`, read whole, or why not (D). Capped at `maxBytes`: a file over it is
    /// refused, never cut short.
    static func readVMFile(_ path: String, container: String, maxBytes: Int = ArtifactLimits.fileBytes,
                           run: Run) async -> Result<Data, IrisEngine.Refusal> {
        let call = wrapped(readCommand(path), container: container, stdin: false)
        switch await run(call.run, nil, timeoutSeconds, maxBytes + 1, call.killer) {
        case .failure(let error):
            return .failure(.init(text: "\(path) couldn't be read from your sandbox: \(error.localizedDescription)"))
        case .success(let out):
            if out.timedOut { return .failure(.init(text: "reading \(path) from your sandbox took over \(Int(timeoutSeconds)) seconds")) }
            guard out.status == 0 else {
                let said = String(decoding: out.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(.init(text: "\(path) couldn't be read in your sandbox\(said.isEmpty ? "" : ": " + said.prefix(200))"))
            }
            guard out.droppedStdout == 0, out.stdout.count <= maxBytes else {
                return .failure(.init(text: ArtifactError.tooLarge(out.stdout.count + out.droppedStdout).message))
            }
            return .success(out.stdout)
        }
    }
}
