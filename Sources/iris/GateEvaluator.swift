import Foundation
import CryptoKit

/// What one look at a `Gate` decided (#187 deliverable 3, spec §7).
///
/// `signal` is what the gate saw — an ETag, an mtime and a hash, a digest of a script's output —
/// recorded on the run's row (`job_runs.gateSignal`) and handed back as `previous` the next time
/// the same gate is asked. `.error` is neither verdict: three of them in a row pause the job
/// (`JobRunner.gateFailingReason`), because a gate nobody can evaluate is a job that is either
/// running for no reason or silently never running, and both need a person.
enum GateResult: Equatable, Sendable {
    /// Something moved. `payload` is a script gate's output, for the run's prompt; the built-in
    /// gates read headers and file metadata and have nothing to say beyond "yes".
    case changed(signal: String, payload: String?)
    case unchanged(signal: String)
    case error(String)
}

/// Evaluates a job's `Gate`: the two built-ins on the host, a `script` gate only inside the
/// `apple/container` VM (#187 R28).
///
/// Everything it needs is injected — the container runtime, the `URLSession`, the `FileManager` —
/// so the whole of it is testable with no VM, no network and no files but the test's own
/// (AGENTS invariant 7).
///
/// A script gate gets a container of its own, created and removed around the one `exec`. Not a
/// `SandboxSessionManager` session, which is keyed by conversation and reused: a gate runs before
/// there is a run, let alone a conversation, and its mounts are its own — sharing a container
/// would mean sharing them. The name carries `SandboxSessionManager.namePrefix` so a container
/// left behind by a crash is swept by `reapOrphans()` at the next launch.
enum GateEvaluator {
    /// How much of a script gate's output is carried into the run's prompt (spec §7).
    static let payloadLimit = 4_000
    /// What a gate script gets when it declared no deadline of its own.
    static let defaultTimeoutSeconds = PollSpec.legacyGateTimeoutSeconds
    /// The window a declared timeout is clamped into. A gate runs unattended on a cadence: below
    /// the floor nothing useful finishes, and above the ceiling a wedged script holds a job's
    /// `inFlight` slot for longer than the cadence it is checked on.
    static let minTimeoutSeconds = 5
    static let maxTimeoutSeconds = 600
    /// Where a gate script runs. Its inputs are wherever it mounted them; the working directory
    /// is deliberately not one of them.
    static let workdir = "/"
    /// Beyond this, a file's signal is its mtime and size alone: hashing every tick is work the
    /// cadence pays for, and a file this large that changed almost certainly changed its size or
    /// its mtime too.
    static let hashSizeLimit = 64 * 1_024 * 1_024

    /// What a script gate is told when the VM it must run in is not there (R28). A gate script
    /// never falls back to the host: it is model-written code that runs unattended forever, and
    /// the container is the whole of what makes that safe.
    static let sandboxUnavailableDetail =
        "the sandbox VM is not available, and a gate script never runs anywhere else"

    /// Asks `gate` whether anything has changed since `previous`.
    ///
    /// `runtime` is `nil` when the sandbox is not resolvable right now — the runtime is not
    /// installed, or sandboxing is switched off. Only a script gate cares, and it answers
    /// `.error`; the built-ins read the host and never needed it.
    static func evaluate(_ gate: Gate, previous: String?, runtime: (any ContainerRuntime)?,
                         http session: URLSession = .shared,
                         fileManager: FileManager = .default,
                         image: String = ConfigManager.shared.sandboxImage) async -> GateResult {
        switch gate {
        case .urlChanged(let url):
            return await evaluateURL(url, previous: previous, session: session)
        case .pathChanged(let path):
            return evaluatePath(path, previous: previous, fileManager: fileManager)
        case .script(let command, let mounts, let timeoutSeconds):
            return await evaluateScript(command, mounts: mounts, timeoutSeconds: timeoutSeconds,
                                        runtime: runtime, image: image)
        }
    }

    /// The verdict a built-in gate reaches by comparison. No previous signal is deliberately a
    /// *change*: the first look has nothing to compare against, and answering "unchanged" would
    /// keep a brand-new job quiet until the world happened to move a second time.
    static func verdict(signal: String, previous: String?) -> GateResult {
        previous == signal ? .unchanged(signal: signal) : .changed(signal: signal, payload: nil)
    }

    // MARK: urlChanged

    /// The three headers that say "this is the same document": whichever the server actually
    /// sends, joined in a fixed order so the signal is stable across ticks.
    static let urlValidators = ["ETag", "Last-Modified", "Content-Length"]

    private static func evaluateURL(_ url: String, previous: String?, session: URLSession) async -> GateResult {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .error("'\(url)' is not an http(s) URL")
        }
        var request = URLRequest(url: parsed)
        request.httpMethod = "HEAD"
        // A cached answer would be the same forever, which is exactly the failure a gate cannot
        // detect from the inside.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .error("HEAD \(url) did not answer with HTTP")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .error("HEAD \(url) answered \(http.statusCode)")
            }
            let fields = urlValidators.compactMap { name -> String? in
                guard let value = http.value(forHTTPHeaderField: name)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
                return "\(name.lowercased())=\(value)"
            }
            // Not "unchanged": with no validator at all this gate can never answer, and a job that
            // silently never fires is worse news than one that says its gate is broken.
            guard !fields.isEmpty else {
                return .error("HEAD \(url) carried no ETag, Last-Modified or Content-Length to compare")
            }
            return verdict(signal: fields.joined(separator: "; "), previous: previous)
        } catch {
            return .error("HEAD \(url) failed: \(error.localizedDescription)")
        }
    }

    // MARK: pathChanged

    private static func evaluatePath(_ path: String, previous: String?, fileManager: FileManager) -> GateResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .error("there is nothing at \(path)")
        }
        do {
            let signal = isDirectory.boolValue
                ? try directorySignal(path, fileManager: fileManager)
                : try fileSignal(path, fileManager: fileManager)
            return verdict(signal: signal, previous: previous)
        } catch {
            return .error("could not read \(path): \(error.localizedDescription)")
        }
    }

    /// A file's mtime, its size and (up to `hashSizeLimit`) the hash of its contents. All three,
    /// because each catches what the others miss: a touch moves the mtime without changing a byte,
    /// and an editor that rewrites a file in place can leave the mtime where it was.
    private static func fileSignal(_ path: String, fileManager: FileManager) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        var signal = "mtime=\(Int(mtime.rounded())); size=\(size)"
        if size >= 0, size <= hashSizeLimit {
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
            signal += "; sha256=" + hex(SHA256.hash(data: data))
        }
        return signal
    }

    /// The newest modification anywhere *under* a directory, the directory's own mtime, and how
    /// many entries there are.
    ///
    /// Three parts, not one maximum: a directory's own mtime moves whenever a name is added or
    /// removed directly inside it, and it is almost always the latest thing in a fresh tree — so
    /// folding it into the maximum would swallow every change deeper down. The count is what
    /// notices a deletion that left every surviving mtime where it was.
    private static func directorySignal(_ path: String, fileManager: FileManager) throws -> String {
        let root = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let rootModified = (try fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            ?? Date(timeIntervalSince1970: 0)
        var newest = Date(timeIntervalSince1970: 0)
        var entries = 0
        // Errors on the way down are skipped rather than failing the gate: one unreadable
        // subdirectory in a large tree must not read as "the whole path is broken".
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys,
                                                options: [], errorHandler: { _, _ in true })
        while let url = enumerator?.nextObject() as? URL {
            entries += 1
            if let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
               modified > newest {
                newest = modified
            }
        }
        return "root=\(Int(rootModified.timeIntervalSince1970.rounded()))"
            + "; newest=\(Int(newest.timeIntervalSince1970.rounded())); entries=\(entries)"
    }

    private static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: script

    static let changedToken = "CHANGED"
    static let unchangedToken = "UNCHANGED"

    private static func evaluateScript(_ command: String, mounts: [String], timeoutSeconds: Int,
                                       runtime: (any ContainerRuntime)?, image: String) async -> GateResult {
        // R28, and the reason this parameter is optional at all.
        guard let runtime else { return .error(sandboxUnavailableDetail) }
        let seconds = clampedTimeout(timeoutSeconds)
        let name = "\(SandboxSessionManager.namePrefix)gate-\(UUID().uuidString.lowercased())"
        do {
            try await runtime.createDetached(name: name, image: image,
                                             mounts: readOnly(mounts), workdir: workdir)
        } catch {
            // Remove anyway: a create that failed part way through can still have left a container
            // behind, and the next tick would collide with nothing but the daemon's opinion of it.
            await runtime.remove(name: name)
            return .error("the gate's container could not be started: \(describe(error))")
        }
        let result: GateResult
        do {
            let output = try await runtime.exec(name: name, workdir: workdir, command: command,
                                                timeoutSeconds: seconds)
            result = scriptVerdict(output)
        } catch ContainerRuntimeError.timedOut {
            // The allowance, not the elapsed seconds: what a person can act on is the number they
            // set, exactly as the sandboxed `run_command` route reports it.
            result = .error("the gate script timed out after \(seconds) seconds")
        } catch {
            result = .error("the gate script could not be run: \(describe(error))")
        }
        // No `defer`: it cannot await, and a container left running would outlive every tick.
        await runtime.remove(name: name)
        return result
    }

    /// The verdict is the last line of stdout, never the exit code (spec §7): `diff -q` and
    /// `grep -q` disagree about what zero means, so any exit-code convention makes a plausible
    /// model-written gate fire every tick or never. A non-zero exit is still an error — the script
    /// did not get as far as an opinion — and so is any other last line.
    static func scriptVerdict(_ output: (stdout: String, stderr: String, exitCode: Int32)) -> GateResult {
        guard output.exitCode == 0 else {
            let said = firstLine(of: output.stderr) ?? firstLine(of: output.stdout) ?? ""
            return .error("the gate script exited \(output.exitCode)\(said.isEmpty ? "" : ": \(said)")")
        }
        let lines = output.stdout.split(whereSeparator: \.isNewline)
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces), !last.isEmpty else {
            return .error("the gate script printed nothing; its last line must be \(changedToken) or \(unchangedToken)")
        }
        let signal = "script=\(last); sha256=" + hex(SHA256.hash(data: Data(output.stdout.utf8)))
        switch last {
        case changedToken:
            let payload = String(lines.dropLast().joined(separator: "\n").prefix(payloadLimit))
            return .changed(signal: signal, payload: payload.isEmpty ? nil : payload)
        case unchangedToken:
            return .unchanged(signal: signal)
        default:
            return .error("the gate script's last line was '\(String(last.prefix(80)))', not \(changedToken) or \(unchangedToken)")
        }
    }

    static func clampedTimeout(_ seconds: Int) -> Int {
        min(max(seconds, minTimeoutSeconds), maxTimeoutSeconds)
    }

    /// Every declared mount, read-only. Nothing in `ContainerRuntime` forces that — `:ro` is just
    /// one spelling its grammar accepts — so the gate forces it here, on the way in: a gate looks
    /// at its inputs, and a writable mount would be model-written code with a durable handle on
    /// the user's disk, running unattended on a cadence forever.
    static func readOnly(_ mounts: [String]) -> [String] {
        mounts.map { $0.hasSuffix(":ro") ? $0 : $0 + ":ro" }
    }

    /// Why `entry` cannot be a gate's mount, or `nil` when it can. Asked at creation, while there
    /// is a person to read the answer: the daemon's version of these refusals arrives later, on a
    /// tick nobody is watching, as three gate errors and a paused job.
    static func mountRefusal(_ entry: String, fileManager: FileManager = .default) -> String? {
        let normalized = readOnly([entry])[0]
        do {
            _ = try ContainerMount.argument(for: normalized)
        } catch ContainerRuntimeError.invalidMount(_, let reason) {
            return "the mount `\(entry)` cannot be used — \(reason)"
        } catch {
            return "the mount `\(entry)` cannot be used"
        }
        let source = String(normalized.split(separator: ":", omittingEmptySubsequences: false)[0])
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source, isDirectory: &isDirectory) else {
            return "the mount source \(source) does not exist"
        }
        guard isDirectory.boolValue else {
            return "the mount source \(source) is a file, and a file cannot be mounted — mount its directory instead"
        }
        return nil
    }

    /// One line of a runtime failure, in the words the CLI used rather than Swift's.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case ContainerRuntimeError.createFailed(let message): return firstLine(of: message) ?? "the create failed"
        case ContainerRuntimeError.launchFailed(let message): return firstLine(of: message) ?? "the runtime would not start"
        case ContainerRuntimeError.invalidMount(let entry, let reason): return "the mount `\(entry)` — \(reason)"
        case is CancellationError: return "it was cancelled"
        default: return error.localizedDescription
        }
    }

    private static func firstLine(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.split(separator: "\n").first.map(String.init)?.prefix(200) ?? "")
    }
}
