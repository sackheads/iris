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

    /// The host side of the run's working directory — the hidden conversation's `workspacePath`
    /// and the path the host file tools resolve against; nil means `/`. The container's own `-w`
    /// is the same mount's target (`workspaceMount`), which differs only when one was named.
    var workingDirectory: String? { mounts.first(where: { !$0.readOnly })?.source }

    /// The working directory's mount, as `SandboxSessionManager.run` takes its `workspace`: the
    /// first read-write one. nil means no read-write mount, which the manager mounts as nothing
    /// and runs in `/` (§0.6).
    var workspaceMount: ContainerMount? { mounts.first(where: { !$0.readOnly }) }

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

extension JobGrant {
    static let grantNeedsMutating = "A grant (mounts or network) is only accepted on a mutating job: a read-only run has no mounts and no network by definition. Pass profile 'mutating', or drop mounts and network."
    static func malformed(_ entry: String, _ reason: String) -> String { "the mount `\(entry)` cannot be used — \(reason)." }
    static func missing(_ source: String) -> String { "the mount source \(source) does not exist." }
    static func notADirectory(_ source: String) -> String {
        "the mount source \(source) is a file, and a file cannot be mounted — mount its directory instead."
    }
    static func tooBroad(_ source: String) -> String {
        "the mount source \(source) is too broad to grant (the whole filesystem, a volume, or the home directory) — name the directory the job actually works in."
    }
    static func protected(_ source: String) -> String {
        "the mount source \(source) is or contains Iris's own directory (~/.iris), which a job may not mount."
    }
    static let readOnlyFirst = "the first mount must be read-write when any later one is, because it is the job's working directory — put the read-write directory first."
    static func duplicate(_ source: String) -> String { "the mount source \(source) is listed twice." }

    /// §0.12: the stores a grant may not mount, whatever the mode. A grant is a standing capability
    /// written by a model from text it read, and `~/.ssh:ro` beside `network: true` is otherwise a
    /// permitted grant. Spelled once; matched on canonical paths, so a link to a store is the store;
    /// and in both directions, as `~/.iris` is — a mount that *contains* a store (`~/.config`,
    /// `~/Library`) hands over the store with everything around it.
    static let credentialStores = ["~/.ssh", "~/.aws", "~/.gnupg", "~/.config/gh", "~/.docker", "~/.kube",
                                   "~/Library/Keychains", "~/Library/Cookies", "~/Library/Application Support/com.apple.container"]
    static let credentialStoreRefusal = "that directory holds credentials; copy the one key the job needs into a directory made for it."

    static func isCredentialStore(_ canonicalSource: String, home: String) -> Bool {
        let lowered = canonicalSource.lowercased()
        return credentialStores.contains { entry in
            let store = IrisPaths.canonicalPath(home + entry.dropFirst()).lowercased()
            return lowered == store || lowered.hasPrefix(store + "/") || store.hasPrefix(lowered + "/")
        }
    }

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
            // The breadth rule is `WatchRoot`'s — shared, not copied, so the two can never drift.
            switch WatchRoot.breadthProblem(for: source, paths: paths, home: home, isVolume: isVolume) {
            case .tooBroad: return .failure(ToolMessage(tooBroad(source)))
            case .protectedIris: return .failure(ToolMessage(protected(source)))
            case nil: break
            }
            if isCredentialStore(source, home: home) { return .failure(ToolMessage(credentialStoreRefusal)) }
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

    /// One line, the same on the result, `/jobs` and the card: each mount's mode, its source (and
    /// target when different), which one is the working directory, the network bit, and the
    /// nesting note when a source lies under another.
    func describe(hostNote: Bool = false) -> String {
        var parts: [String] = mounts.map { mount in
            var text = (mount.readOnly ? "read-only " : "read-write ") + mount.source
            if mount.target != mount.source { text += " \u{2192} \(mount.target)" }
            if !mount.readOnly, mount.source == workingDirectory { text += " (working directory)" }
            return text
        }
        if parts.isEmpty { parts.append("no mounts") }
        // `hostNote` is the listing's: an `--internal` network still reaches the Mac's own
        // listeners (measured, §0.7), and `/jobs` is where a person reads what a job can reach.
        parts.append(network ? "network on" : (hostNote ? "network off (host reachable)" : "network off"))
        for inner in mounts {
            if let outer = mounts.first(where: { $0.source != inner.source && inner.source.hasPrefix($0.source + "/") }) {
                parts.append("nested: \(inner.source) under \(outer.source), whose mode applies beneath it")
            }
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    var sentence: String { "Grant: \(describe())." }
}

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

extension JobGrant {
    /// The entries to hand `SandboxSessionManager.run` as `extraMounts`: every mount except the
    /// working directory's — the first read-write one, which `run` receives as its `workspace` and
    /// `mountList` mounts itself, at its target; listing it here as well would be two `--mount`
    /// flags for one directory.
    func extraMountEntries() -> [String] {
        guard let workspace = mounts.firstIndex(where: { !$0.readOnly }) else { return mountEntries }
        return mounts.enumerated().filter { $0.offset != workspace }.map(\.element.entry)
    }
}

extension JobGrant {
    private static func isUnder(_ path: String, _ source: String) -> Bool {
        path == source || path.hasPrefix(source.hasSuffix("/") ? source : source + "/")
    }

    /// Each mount with its source taken to the real path, so a source stored as `/tmp/x` meets a
    /// candidate that resolved to `/private/tmp/x`. A source that will not resolve covers nothing.
    private var realMounts: [(mount: ContainerMount, real: String)] {
        mounts.compactMap { mount in IrisPaths.realPathForAllow(mount.source).map { (mount, $0) } }
    }

    /// Case-insensitive (§3): APFS keeps the caller's spelling and the decision is only *whether*;
    /// the descriptor walk (Task 4c) is what proves the file is really under the entry.
    func covering(_ realPath: String) -> ContainerMount? {
        let lowered = realPath.lowercased()
        return realMounts.filter { Self.isUnder(lowered, $0.real.lowercased()) }
            .max { $0.real.count < $1.real.count }?.mount
    }

    /// The lexical components of the call's path beneath `mount.source` — the spelling the walk
    /// descends, `.` removed. nil when the path is not spelled under the source (case-insensitively —
    /// a spelling that only *resolves* into the mount, the `/private` firmlink or a link from
    /// outside, has no components to walk from the mount's root) or when any component is `..`
    /// (the walk refuses it again on its own; this is the earlier, cheaper no).
    func relativeComponents(of details: String, cwd: String?, under mount: ContainerMount) -> [String]? {
        let spelled = IrisEngine.expandTilde(ToolExecutor.resolvePath(details, cwd: cwd))
        let source = mount.source.hasSuffix("/") ? String(mount.source.dropLast()) : mount.source
        guard spelled.lowercased() == source.lowercased() || spelled.lowercased().hasPrefix(source.lowercased() + "/") else { return nil }
        let components = spelled.dropFirst(source.count).split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init).filter { $0 != "." }
        guard !components.contains("..") else { return nil }
        return components
    }

    /// The mount a file-tool call may use, or nil. Three conditions, all of them: the path is
    /// spelled under the mount (`relativeComponents`), its real path is covered by the mount
    /// (`covering` — a link from inside the spelling to outside resolves outside), and the mode fits.
    func allowedMount(toolName: String, details: String, cwd: String?) -> ContainerMount? {
        guard toolName == "write_file" || toolName == "read_file",
              let real = IrisPaths.realPathForAllow(ToolExecutor.resolvePath(details, cwd: cwd)),
              let mount = covering(real),
              relativeComponents(of: details, cwd: cwd, under: mount) != nil else { return nil }
        if toolName == "write_file", mount.readOnly { return nil }
        return mount
    }

    /// Pure (spec §3). `run_command` answers the sandbox question the caller hands in (§0.4) — the
    /// R20 check in the dispatcher is the other lock, and neither trusts the other — so a path that
    /// reaches approval unsandboxed gets `false`. The two file tools answer through `allowedMount`.
    /// Everything else is `false`.
    func allows(toolName: String, details: String, cwd: String?, sandboxed: Bool) -> Bool {
        switch toolName {
        case "run_command": return sandboxed
        case "write_file", "read_file": return allowedMount(toolName: toolName, details: details, cwd: cwd) != nil
        default: return false
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
