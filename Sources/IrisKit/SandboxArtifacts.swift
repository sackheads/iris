import Foundation

/// Moving an artifact's bytes into and out of a sandboxed session's container (#469 3b, rulings C
/// and D). Both run the `container` CLI through `ProcessGroupRunner`: bounded by a deadline, killed
/// by its ladder, and joined to `LiveProcessGroups` (Invariant 4). Neither starts a command that
/// outlives its client: the copy-in's `cat` ends at the end of its stdin, which the client's death
/// closes, and the read's `cat` gets EPIPE writing to it.
enum SandboxArtifacts {
    /// Where a received artifact is put in the receiver's container (C).
    static let vmDirectory = "/tmp/iris-artifacts"
    static func vmPath(_ sha: String) -> String { vmDirectory + "/" + sha }
    /// How long a copy in or a read out may take.
    static let timeoutSeconds: Double = 120

    /// One `container` invocation: the arguments, the bytes for its stdin, the deadline and the
    /// most of its stdout to keep. Injectable so a test needs no binary, daemon or VM.
    typealias Run = @Sendable (_ arguments: [String], _ stdin: Data?, _ timeoutSeconds: Double,
                               _ outputLimit: Int?) async -> Result<ProcessGroupRunner.Output, Error>

    static func liveRun(binary: String) -> Run {
        { arguments, stdin, timeout, limit in
            await ProcessGroupRunner(outputLimit: limit).run(executable: binary, arguments: arguments, environment: nil,
                                                             currentDirectory: nil, stdin: stdin, timeoutSeconds: timeout)
        }
    }

    /// Copies `data` into `container` at `vmPath(sha)`: written beside it and renamed, so a reader
    /// never sees half a file. The path is fixed, never one the model or a peer chose, so the shell
    /// line has nothing of theirs in it. Nil on success, else why it wasn't copied.
    static func materialize(_ data: Data, sha: String, container: String, run: Run) async -> String? {
        let path = vmPath(sha)
        let script = "mkdir -p \(vmDirectory) && cat > \(path).part && mv \(path).part \(path)"
        switch await run(["exec", "-i", container, "sh", "-c", script], data, timeoutSeconds, 4_096) {
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

    /// A file in `container`, read whole by `cat`, or why not (D). Capped at `maxBytes`: a file
    /// over it is refused, never cut short. `path` is one argument to `cat`, after `--`, never
    /// through a shell.
    static func readVMFile(_ path: String, container: String, maxBytes: Int = ArtifactLimits.fileBytes,
                           run: Run) async -> Result<Data, IrisEngine.Refusal> {
        switch await run(["exec", container, "cat", "--", path], nil, timeoutSeconds, maxBytes + 1) {
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
