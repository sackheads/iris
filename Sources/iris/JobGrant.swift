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
            if let broad = broadRefusal(source, home: home, isVolume: isVolume) { return .failure(ToolMessage(broad)) }
            let iris = IrisPaths.canonicalPath(paths.root.path).lowercased()
            let lowered = source.lowercased()
            if lowered == iris || lowered.hasPrefix(iris + "/") || iris.hasPrefix(lowered + "/") {
                return .failure(ToolMessage(protected(source)))
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
