import Foundation
import CryptoKit

/// A script as it was reviewed (#330, #687): a script job's action, or a script gate. Everything
/// the review showed is here, because everything the review showed is what a person approved: a
/// stored row edited to add a mount or turn the network on must fail the fingerprint exactly as an
/// edited script does.
struct ScriptSpec: Codable, Equatable, Sendable {
    var command: String
    /// `source[:target]` entries, stored resolved and read-only (`GateEvaluator.readOnly`).
    var mounts: [String]
    var timeoutSeconds: Int
    /// Off is the isolated network, which is host-only (#690): it still reaches services on the
    /// Mac. On is the default network.
    var network: Bool

    init(command: String, mounts: [String], timeoutSeconds: Int, network: Bool) {
        self.command = command
        self.mounts = mounts
        self.timeoutSeconds = timeoutSeconds
        self.network = network
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decode(String.self, forKey: .command)
        mounts = try c.decodeIfPresent([String].self, forKey: .mounts) ?? []
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? ScriptJobs.defaultTimeoutSeconds
        network = try c.decodeIfPresent(Bool.self, forKey: .network) ?? false
    }

    /// SHA-256 over every reviewed field, each length-prefixed so no two specs share an input.
    /// Built field by field, never from a JSON encoding, whose key order is not stable.
    var fingerprint: String {
        var data = Data()
        func add(_ s: String) {
            let bytes = Data(s.utf8)
            data.append(contentsOf: String(bytes.count).utf8)
            data.append(0x3A)
            data.append(bytes)
        }
        add("v1")
        add(command)
        add(String(mounts.count))
        mounts.forEach(add)
        add(String(timeoutSeconds))
        add(network ? "network" : "isolated")
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum ScriptJobs {
    /// A script job's run window (#330, fork E): the gate's floor, the run ceiling.
    static let minTimeoutSeconds = 5
    static let maxTimeoutSeconds = 3600
    static let defaultTimeoutSeconds = 120
    static func clampedTimeout(_ seconds: Int) -> Int { min(max(seconds, minTimeoutSeconds), maxTimeoutSeconds) }

    /// Kept of each stream, on the row and over the pipe from the VM (#330, C).
    static let outputLimit = 64 * 1_024
    static let truncatedMarker = "[truncated]"
    /// The card's outcome line, like a prompt run's.
    static let outcomeLimit = 200

    /// The marker a card carries when its line was checked without the tier-3 canary (#330, D).
    /// The same text on every card path that adds it.
    static let withoutTier3Marker = "(checked without tier 3)"
    static let withheldOutcome = "output withheld: the injection guard blocked it"
    static let changedSinceReview = "script changed since review"
    static let keychainUnreadable = "Iris couldn't read its Keychain item, so it can't check this script is the one you reviewed; it won't run until it can"
    static let couldNotRecordReview = "Iris couldn't save the record of this review in its Keychain item (it may be unreadable), so the job wasn't created: a script job or gate it can't verify never runs."

    /// The outcome line: the last non-empty line of stdout, capped; `exit N` when there is none.
    static func outcome(stdout: String, exitCode: Int32) -> String {
        let last = stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && $0 != truncatedMarker }
        guard let last else { return "exit \(exitCode)" }
        return String(last.prefix(outcomeLimit))
    }

    /// Whether a run posts a card (#330, C, ruled): the first run, any failure, or a status or
    /// outcome that differs from the previous run's. Every run writes its row regardless.
    static func posts(status: JobRun.Status, outcome: String?, previous: JobRun?) -> Bool {
        guard let previous else { return true }
        if status != .completed { return true }
        return previous.status != status || previous.outcome != outcome
    }

    /// The tier-3 guard on a line about to be posted (#330, D): the line, or the withheld text when
    /// the guard blocks it, and whether tier 3 could not run (protection off, or its model absent).
    static func guardLine(_ line: String, protectionEnabled: Bool? = nil) async -> (line: String, withoutTier3: Bool) {
        let outcome = await InjectionGuard.classify(line, contextTag: "script_output", maxTier: .tier3_canary,
                                                    protectionEnabled: protectionEnabled)
        let ran = InjectionGuard.tier3WillRun(protectionEnabled: protectionEnabled)
        switch outcome {
        case .passed(let clean): return (clean, !ran)
        case .blocked: return (withheldOutcome, !ran)
        }
    }

    /// The script wrapped so at most `limit` bytes of each stream ever leave the VM: written to the
    /// container's `/tmp`, then the head of each sent back, with a marker past the cap. The script
    /// travels as base64, so no quoting in it can break the wrapper. Exit status is the script's.
    static func cappedCommand(_ script: String, limit: Int = outputLimit) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        return """
            printf '%s' '\(encoded)' | base64 -d > /tmp/.iris-script || exit 125; \
            bash /tmp/.iris-script > /tmp/.iris-out 2> /tmp/.iris-err; rc=$?; \
            head -c \(limit) /tmp/.iris-out; \
            [ "$(wc -c < /tmp/.iris-out)" -gt \(limit) ] && printf '\\n\(truncatedMarker)'; \
            head -c \(limit) /tmp/.iris-err >&2; \
            [ "$(wc -c < /tmp/.iris-err)" -gt \(limit) ] && printf '\\n\(truncatedMarker)' >&2; \
            exit $rc
            """
    }

    /// The review text for a script, gate or job: what it can read, whether it can reach the
    /// network and what that means, how long it may run, then the script last (see
    /// `GateScriptReview.details` for why the script goes last).
    static func reviewDetails(_ spec: ScriptSpec, isGate: Bool) -> String {
        let rendered = spec.mounts.map { entry -> String in
            let parts = GateEvaluator.mountParts(entry)
            return "  \(parts.source) \u{2192} \(parts.target), read-only"
        }
        let inputs = rendered.isEmpty
            ? "  (none \u{2014} the script can read nothing of yours)" : rendered.joined(separator: "\n")
        let what = isGate
            ? "This gate script runs unattended inside the sandbox VM every time the job's schedule comes round, for as long as the job exists."
            : "This script job runs unattended inside the sandbox VM every time it fires, with no model looking at it, for as long as the job exists."
        let network: String
        switch (spec.network, spec.mounts.isEmpty) {
        case (true, false):
            network = "Network: on. It can read the folders above and reach the internet on every run, with no one watching: it could send what it reads anywhere, or download and run more code."
        case (true, true):
            network = "Network: on. It can reach the internet on every run, with no one watching: it could download and run more code."
        case (false, _):
            network = "Network: off (host-only): no internet, but it can still reach services on this Mac."
        }
        return what + " What it can read:\n" + inputs + "\n" + network + "\n"
            + "It is stopped after \(spec.timeoutSeconds) seconds." + "\n\nScript:\n" + spec.command
    }
}

/// The fingerprints of reviewed scripts (#330 ruling, #678's lesson for the job store). The job
/// row is in the conversation database, which one approved shell command can edit; a fingerprint
/// is kept beside the API keys in the secrets item, which it cannot, and a fire whose stored script
/// no longer matches is refused. Written only by the review at creation and by the one-time upgrade
/// pass; a missing fingerprint refuses the fire, never "trust and record".
enum ScriptFingerprints {
    static func key(_ jobId: UUID) -> String { "SCRIPT_FP_" + jobId.uuidString }
    /// In the same item: the upgrade pass has run, so it cannot run twice.
    static let upgradeMarker = "SCRIPT_FP_UPGRADE_V1"

    enum Check: Equatable { case matches, changed, missing, unreadable }

    static func check(jobId: UUID, spec: ScriptSpec, keychain: KeychainManager) -> Check {
        guard let secrets = try? keychain.secretsOrThrow(service: KeychainManager.legacyService) else { return .unreadable }
        guard let stored = secrets[key(jobId)] else { return .missing }
        return stored == spec.fingerprint ? .matches : .changed
    }

    /// False when the item could not be written (an unreadable item blocks writes, #678).
    @discardableResult
    static func record(jobId: UUID, spec: ScriptSpec, keychain: KeychainManager) -> Bool {
        guard !keychain.areWritesBlocked,
              var secrets = try? keychain.secretsOrThrow(service: KeychainManager.legacyService) else { return false }
        secrets[key(jobId)] = spec.fingerprint
        return (try? keychain.saveSecretsOrThrow(secrets, service: KeychainManager.legacyService)) != nil
    }

    static func forget(jobId: UUID, keychain: KeychainManager) {
        guard !keychain.areWritesBlocked,
              var secrets = try? keychain.secretsOrThrow(service: KeychainManager.legacyService),
              secrets.removeValue(forKey: key(jobId)) != nil else { return }
        try? keychain.saveSecretsOrThrow(secrets, service: KeychainManager.legacyService)
    }

    /// The one-time upgrade pass: every existing script gate's stored script is fingerprinted as it
    /// stands (trust on first use, ruled: a row tampered before the upgrade was exposed already).
    /// Script jobs postdate this pass, so each was fingerprinted at its review. Returns how many it
    /// recorded, or nil when it already ran or the item cannot be read or written. Only the app runs
    /// it (#679's rule), and its marker is in the same item, so it cannot run twice.
    ///
    /// Known limit: deleting the item and replaying #678's upgrade also replays this pass. That
    /// replay is announced (#679), so the person sees it.
    @discardableResult
    static func upgrade(jobs: [Job], keychain: KeychainManager) -> Int? {
        guard !keychain.areWritesBlocked,
              var secrets = try? keychain.secretsOrThrow(service: KeychainManager.legacyService),
              secrets[upgradeMarker] == nil else { return nil }
        var recorded = 0
        for job in jobs {
            guard let spec = job.trigger.gate?.scriptSpec else { continue }
            secrets[key(job.id)] = spec.fingerprint
            recorded += 1
        }
        secrets[upgradeMarker] = "1"
        guard (try? keychain.saveSecretsOrThrow(secrets, service: KeychainManager.legacyService)) != nil else { return nil }
        return recorded
    }
}

extension JobAction {
    /// A script job's spec, or nil.
    var scriptSpec: ScriptSpec? { if case .script(let spec) = self { return spec } else { return nil } }
}

extension Gate {
    /// A script gate as it was reviewed, or nil for the built-in gates.
    var scriptSpec: ScriptSpec? {
        guard case .script(let command, let mounts, let timeoutSeconds, let network) = self else { return nil }
        return ScriptSpec(command: command, mounts: mounts, timeoutSeconds: timeoutSeconds, network: network)
    }
}
