import Foundation
import CryptoKit

/// What one look at a `Gate` decided (#187 deliverable 3, spec §7).
///
/// `signal` is what the gate saw — a digest of a URL's validators, an mtime and a hash, a digest of
/// a script's output — recorded on the run's row (`job_runs.gateSignal`). For the two built-ins it
/// is handed back as `previous` the next time the same gate is asked, and the comparison *is* the
/// verdict. A script gate's signal is a record only: the script does its own comparing and answers
/// with a token, so nothing ever reads its signal back. `.error` is neither verdict: three of them in a row pause the job
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
    /// The ceiling on starting a gate's container. `createDetached` has one of its own (R31,
    /// twenty minutes), pitched for a person waiting at a keyboard through a cold image pull; that
    /// is far too long here. This is an unattended, repeating caller, and a long await inside a
    /// job's in-flight mark is a job that goes quiet — every later tick dropped as an overlap, no
    /// row, no card, and the three-error pause never reached. Generous, because a legitimate pull
    /// is slow; short, because nobody is watching this one.
    static let createCeilingSeconds = 300
    /// The longest the one line of somebody else's output that a gate error quotes may be.
    static let detailLimit = 160
    /// How many entries a directory gate will walk before it gives up on the whole path.
    ///
    /// A `gate_path` of `/Users/me` or `/` is a plausible thing to ask for ("watch my home
    /// folder") and the walk behind it is synchronous and stats every entry: on a real home
    /// directory that is minutes of a cooperative thread, every tick, inside the job's in-flight
    /// mark — which drops every later tick as an overlap and never errors, so the three-error
    /// pause never rescues it. Past the cap the evaluation is an error instead, which does pause
    /// the job, and `schedule_job` refuses such a path while there is still someone to read why.
    static let directoryEntryLimit = 20_000

    /// What a path too large to watch is told, at creation and at evaluation alike.
    static func tooManyEntriesDetail(_ path: String, limit: Int = directoryEntryLimit) -> String {
        "\(path) holds more than \(limit) entries, which is too many to check on a cadence; watch a narrower path, or use gate_script"
    }

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
    /// `image` and `createCeilingSeconds` are the script gate's alone — `nil` resolves the
    /// configured sandbox image when, and only when, a script gate is what is being asked. A
    /// default argument is evaluated at every call site that omits it, and a URL gate has no
    /// business constructing a `ConfigManager`.
    static func evaluate(_ gate: Gate, previous: String?, runtime: (any ContainerRuntime)?,
                         http session: URLSession = .shared,
                         fileManager: FileManager = .default,
                         image: String? = nil,
                         createCeilingSeconds: Int = GateEvaluator.createCeilingSeconds,
                         directoryEntryLimit: Int = GateEvaluator.directoryEntryLimit) async -> GateResult {
        switch gate {
        case .urlChanged(let url):
            return await evaluateURL(url, previous: previous, session: session)
        case .pathChanged(let path):
            return evaluatePath(path, previous: previous, fileManager: fileManager,
                                entryLimit: directoryEntryLimit)
        case .script(let command, let mounts, let timeoutSeconds):
            return await evaluateScript(command, mounts: mounts, timeoutSeconds: timeoutSeconds,
                                        runtime: runtime,
                                        image: image ?? ConfigManager.shared.sandboxImage,
                                        createCeiling: createCeilingSeconds,
                                        fileManager: fileManager)
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
    /// sends, in a fixed order so the signal is stable across ticks.
    static let urlValidators = ["ETag", "Last-Modified", "Content-Length"]

    /// What a URL gate that cannot work against this server tells whoever reads the pause.
    static let tryAnotherGate = "use gate_path or gate_script instead"

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
                // 405 gets its own advice: the document may be perfectly fine, and the server
                // simply will not answer the request this gate is made of.
                let hint = http.statusCode == 405
                    ? " — that server does not answer HEAD requests; \(Self.tryAnotherGate)" : ""
                return .error("HEAD \(url) answered \(http.statusCode)\(hint)")
            }
            let present = urlValidators.filter { name in
                !(http.value(forHTTPHeaderField: name)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
            }
            // Not "unchanged": with no validator at all this gate can never answer, and a job that
            // silently never fires is worse news than one that says its gate is broken.
            guard !present.isEmpty else {
                return .error("HEAD \(url) carried no ETag, Last-Modified or Content-Length to compare; "
                    + Self.tryAnotherGate)
            }
            // The *values* are hashed rather than stored. They are arbitrary text chosen by a
            // remote server, and this column is read back into a model's context by `get_job_run`
            // and into a person's `/jobs` by the ledger. A hash answers the only question the
            // signal is ever asked — "is this the same document?" — is bounded, and cannot carry
            // an instruction. Which validators were present is our own vocabulary, so it stays
            // legible: "the ETag stopped being sent" is a real diagnosis.
            let joined = urlValidators.compactMap { name in
                http.value(forHTTPHeaderField: name).map { "\(name.lowercased())=\($0)" }
            }.joined(separator: "\n")
            let signal = "validators=\(present.map { $0.lowercased() }.joined(separator: ","))"
                + "; sha256=" + hex(SHA256.hash(data: Data(joined.utf8)))
            return verdict(signal: signal, previous: previous)
        } catch {
            return .error("HEAD \(url) failed: \(error.localizedDescription)")
        }
    }

    // MARK: pathChanged

    private static func evaluatePath(_ path: String, previous: String?, fileManager: FileManager,
                                     entryLimit: Int) -> GateResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .error("there is nothing at \(path)")
        }
        do {
            let signal = isDirectory.boolValue
                ? try directorySignal(path, fileManager: fileManager, entryLimit: entryLimit)
                : try fileSignal(path, fileManager: fileManager)
            return verdict(signal: signal, previous: previous)
        } catch is DirectoryTooLarge {
            // An error, not a silent "unchanged": it counts towards the three-error pause, so a
            // job pointed at a tree nobody can walk stops and says so instead of going quiet.
            return .error(tooManyEntriesDetail(path, limit: entryLimit))
        } catch {
            return .error("could not read \(path): \(error.localizedDescription)")
        }
    }

    /// A directory gate given more than `directoryEntryLimit` entries to look at.
    private struct DirectoryTooLarge: Error {}

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
    private static func directorySignal(_ path: String, fileManager: FileManager,
                                        entryLimit: Int) throws -> String {
        let rootModified = (try fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            ?? Date(timeIntervalSince1970: 0)
        let walked = walk(path, fileManager: fileManager, limit: entryLimit)
        guard !walked.overLimit else { throw DirectoryTooLarge() }
        return "root=\(Int(rootModified.timeIntervalSince1970.rounded()))"
            + "; newest=\(Int(walked.newest.timeIntervalSince1970.rounded())); entries=\(walked.entries)"
    }

    /// Everything under `path`, up to the cap: how many entries there are and the newest
    /// modification among them. `overLimit` says the walk stopped early, which is the one thing
    /// both callers do with it — the evaluation turns it into a gate error, `schedule_job` into a
    /// refusal. One entry past the cap is enough to know; nothing counts the rest.
    static func walk(_ path: String, fileManager: FileManager, limit: Int = directoryEntryLimit)
        -> (entries: Int, newest: Date, overLimit: Bool) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var newest = Date(timeIntervalSince1970: 0)
        var entries = 0
        // Errors on the way down are skipped rather than failing the gate: one unreadable
        // subdirectory in a large tree must not read as "the whole path is broken".
        let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: path),
                                                includingPropertiesForKeys: keys,
                                                options: [], errorHandler: { _, _ in true })
        while let url = enumerator?.nextObject() as? URL {
            entries += 1
            if entries > limit { return (entries, newest, true) }
            if let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
               modified > newest {
                newest = modified
            }
        }
        return (entries, newest, false)
    }

    private static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: script

    static let changedToken = "CHANGED"
    static let unchangedToken = "UNCHANGED"

    /// A create that outlived `createCeilingSeconds`. Its own type so the catch below can tell it
    /// from anything the runtime itself threw.
    private struct CreateTimedOut: Error {}

    private static func evaluateScript(_ command: String, mounts: [String], timeoutSeconds: Int,
                                       runtime: (any ContainerRuntime)?, image: String,
                                       createCeiling: Int,
                                       fileManager: FileManager) async -> GateResult {
        // R28, and the reason this parameter is optional at all.
        guard let runtime else { return .error(sandboxUnavailableDetail) }
        // A legacy `PollSpec` row with no gate at all decodes to a script gate with an empty
        // command (invariant 1: decode leniently). Answered here rather than by three container
        // create/remove cycles that each run `bash -c ""` and hear nothing back.
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error("this job's gate has no script to run")
        }
        // Before anything is started: the mounts must still be the directories that were reviewed.
        if let drift = mountDrift(mounts, fileManager: fileManager) { return .error(drift) }
        let seconds = clampedTimeout(timeoutSeconds)
        let name = "\(SandboxSessionManager.namePrefix)gate-\(UUID().uuidString.lowercased())"
        // Registered before the create and taken out again by `sweep`, so a sweep of the leftovers
        // of a previous process cannot delete a container that is mid-evaluation right now.
        await GateContainerRegistry.shared.register(name)
        do {
            try await createWithinCeiling(runtime, name: name, image: image,
                                          mounts: readOnly(mounts), seconds: createCeiling)
        } catch is CreateTimedOut {
            // Not a hang: a bounded failure that lands on the ordinary error path, so it is
            // counted towards the three-error pause and somebody is eventually told. The remove
            // is the same best-effort sweep a failed create gets.
            await sweep(runtime, name: name)
            return .error("the gate's container could not be started within \(createCeiling) seconds")
        } catch {
            // Remove anyway: a create that failed part way through can still have left a container
            // behind, and the next tick would collide with nothing but the daemon's opinion of it.
            await sweep(runtime, name: name)
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
        await sweep(runtime, name: name)
        return result
    }

    /// `createDetached` with a deadline on it.
    ///
    /// A race in a task group rather than a `withTimeout` helper that walks away: losing the race
    /// cancels the create, and `CLIProcessRunner` answers cancellation with its kill ladder, so the
    /// CLI child is signalled rather than left running. The group awaits the cancelled child before
    /// this returns, which is what makes "the gate did not start a container" true rather than
    /// hopeful.
    private static func createWithinCeiling(_ runtime: any ContainerRuntime, name: String,
                                            image: String, mounts: [String], seconds: Int) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await runtime.createDetached(name: name, image: image, mounts: mounts,
                                                 workdir: workdir)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
                throw CreateTimedOut()
            }
            defer { group.cancelAll() }
            // The first to finish decides; `cancelAll` above stops the other, and leaving the
            // group's scope waits for it.
            try await group.next()
        }
    }

    /// The verdict is the last line of stdout, never the exit code (spec §7): `diff -q` and
    /// `grep -q` disagree about what zero means, so any exit-code convention makes a plausible
    /// model-written gate fire every tick or never. A non-zero exit is still an error — the script
    /// did not get as far as an opinion — and so is any other last line.
    static func scriptVerdict(_ output: (stdout: String, stderr: String, exitCode: Int32)) -> GateResult {
        guard output.exitCode == 0 else {
            let said = quoted(output.stderr) ?? quoted(output.stdout) ?? ""
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
            return .error("the gate script's last line was '\(quoted(last) ?? "")', not \(changedToken) or \(unchangedToken)")
        }
    }

    static func clampedTimeout(_ seconds: Int) -> Int {
        min(max(seconds, minTimeoutSeconds), maxTimeoutSeconds)
    }

    /// A mount entry's parts, under the `source[:target][:ro]` grammar: a bare source mounts at
    /// itself. Lenient, because a row can be edited outside Iris and hold anything — the strict
    /// reading is `ContainerMount.argument`'s, which refuses what it cannot make sense of before
    /// any container is created.
    static func mountParts(_ entry: String) -> (source: String, target: String, readOnly: Bool) {
        var parts = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let readOnly = ContainerMount.hasReadOnlyFlag(entry)
        if readOnly, parts.count > 1 { parts.removeLast() }
        let source = parts.first ?? ""
        return (source, parts.count > 1 ? parts[1] : source, readOnly)
    }

    /// `entry` with its source resolved — tilde expanded, `..` removed, symlinks followed — by the
    /// same helper the permission layer canonicalises a write with, and its target left exactly as
    /// it was asked for.
    ///
    /// Stored this way, so the directory the review was shown and the directory the daemon binds
    /// are the same one: `/tmp/innocuous` is whatever it points at, and a reviewer shown the
    /// spelling rather than the location is reviewing nothing. The target is *not* resolved —
    /// it is a path inside the container that the script was written against, and moving it would
    /// break a script the review just approved.
    static func canonicalMount(_ entry: String) -> String {
        let parts = mountParts(entry)
        guard !parts.source.isEmpty else { return entry }
        let resolved = IrisPaths.canonicalPath(parts.source)
        return parts.readOnly ? "\(resolved):\(parts.target):ro" : "\(resolved):\(parts.target)"
    }

    /// Why this gate's mounts cannot be used *now*, or `nil` when they are still what was stored.
    ///
    /// Asked at every evaluation, not only at creation. A mount is a standing read capability over
    /// a directory that is not ours, granted once by a review and then used unattended for as long
    /// as the job lives: a source replaced by a symlink somewhere else, or by a file, would
    /// otherwise be bound without anybody having looked at it. Resolving to something other than
    /// the stored path is the whole test — the stored path is already canonical, so any difference
    /// is a change made since.
    static func mountDrift(_ mounts: [String], fileManager: FileManager = .default) -> String? {
        for entry in mounts {
            let source = mountParts(entry).source
            guard !source.isEmpty else { continue }
            let resolved = IrisPaths.canonicalPath(source)
            guard resolved == source else {
                return "the gate's mount \(source) now resolves to \(resolved), which is not what was approved"
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return "the gate's mount \(source) is no longer a directory"
            }
        }
        return nil
    }

    /// Removes the gate's container and takes its name out of the in-flight set.
    ///
    /// `removeIgnoringCancellation`, because this is the cleanup and the caller may well be
    /// cancelled by the time it runs: `CLIProcessRunner` refuses to launch on a cancelled task, so
    /// a plain `remove` would spawn neither `stop` nor `delete` and leave the container standing
    /// until something swept it. Bounded by the remove's own housekeeping deadline.
    private static func sweep(_ runtime: any ContainerRuntime, name: String) async {
        await runtime.removeIgnoringCancellation(name: name)
        await GateContainerRegistry.shared.unregister(name)
    }

    /// Every declared mount, read-only. Nothing in `ContainerRuntime` forces that — `:ro` is just
    /// one spelling its grammar accepts — so the gate forces it here, on the way in: a gate looks
    /// at its inputs, and a writable mount would be model-written code with a durable handle on
    /// the user's disk, running unattended on a cadence forever.
    static func readOnly(_ mounts: [String]) -> [String] {
        // `ContainerMount`'s own test for the flag, not a `hasSuffix(":ro")` of our own: the two
        // must agree about what "already read-only" means, or an entry could be appended to here
        // and read differently there. This is the first caller that rewrites a user's entry.
        mounts.map { ContainerMount.hasReadOnlyFlag($0) ? $0 : $0 + ":ro" }
    }

    /// Why `entry` cannot be a gate's mount, or `nil` when it can. Asked at creation, while there
    /// is a person to read the answer: the daemon's version of these refusals arrives later, on a
    /// tick nobody is watching, as three gate errors and a paused job.
    ///
    /// Every question below is asked of the *resolved* source, never the spelling, because that is
    /// what would actually be bound: `/tmp/innocuous -> /` is a mount of the whole disk, and a
    /// refusal that reads the text would miss it.
    static func mountRefusal(_ entry: String, fileManager: FileManager = .default,
                             paths: IrisPaths = .default) -> String? {
        let normalized = readOnly([entry])[0]
        do {
            _ = try ContainerMount.argument(for: normalized)
        } catch ContainerRuntimeError.invalidMount(_, let reason) {
            return "the mount `\(entry)` cannot be used — \(reason)"
        } catch {
            return "the mount `\(entry)` cannot be used"
        }
        let source = IrisPaths.canonicalPath(mountParts(normalized).source)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source, isDirectory: &isDirectory) else {
            return "the mount source \(source) does not exist"
        }
        guard isDirectory.boolValue else {
            return "the mount source \(source) is a file, and a file cannot be mounted — mount its directory instead"
        }
        // The whole disk read-only, on a cadence, into a model's context is not a gate — it is the
        // absence of one, and no review of a two-line script would catch it.
        guard source != "/" else {
            return "the mount source \(source) is the whole filesystem, which is too much for a gate to read — name the directory the script actually looks at"
        }
        // The same two directories `PermissionManager` will not let a write into: the allowlist,
        // the hook definitions and the plugins are how Iris decides what anything may do, and a
        // gate script reading them on a cadence puts them in a model's context forever.
        guard !paths.isUnderProtectedWriteDir(source) else {
            return "the mount source \(source) is part of Iris's own configuration, which a gate may not read — name a directory outside it"
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

    /// One short, printable line of somebody else's output, safe to put in a sentence.
    ///
    /// A gate error's detail is the only part of it a script or a server wrote, and it is rendered
    /// raw in `/jobs run`'s answer and stored on a ledger row. So: newlines and runs of whitespace
    /// collapse to single spaces, control characters go, and the whole thing is capped. Not an
    /// injection defence — the model-facing routes are guarded — a rendering one, so a script
    /// cannot redraw somebody's terminal or bury the sentence it is quoted inside.
    static func quoted(_ text: some StringProtocol) -> String? {
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let printable = String(String.UnicodeScalarView(
            collapsed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        return printable.isEmpty ? nil : String(printable.prefix(detailLimit))
    }

    private static func firstLine(of text: String) -> String? { quoted(text) }
}

/// The gate containers that exist right now, by name.
///
/// A gate's container is named with `SandboxSessionManager.namePrefix` on purpose: that is what
/// makes one left behind by a crash sweepable at the next launch. The price of sharing the prefix
/// is that the prefix alone no longer identifies an orphan, so the sweep asks here as well as
/// asking its own session table. Nothing schedules the sweep today — it runs once, at launch,
/// before any gate could be mid-evaluation — and this is what keeps it correct if anything ever
/// does.
actor GateContainerRegistry {
    static let shared = GateContainerRegistry()

    private var names: Set<String> = []

    func register(_ name: String) { names.insert(name) }
    func unregister(_ name: String) { names.remove(name) }

    /// The names in flight at this instant. A snapshot: a gate that starts after it is taken is
    /// not in it, which is why the sweep is a launch-time job and not a periodic one.
    func current() -> Set<String> { names }
}
