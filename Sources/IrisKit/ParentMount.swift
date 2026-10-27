import Foundation
import os

/// #658 (a): a read-write sandbox mount that holds the person's repositories without being one is
/// refused when the mount is made. Below a parent such as `~/src` or the home folder, every clone's
/// `.git` would be the VM's to write, and only the workspace's own repository gets a git dir of its
/// own (`SandboxGit`). Decided once per mount, when a container is made; nothing here runs per
/// command, and nothing is renamed, moved or watched.
enum ParentMount {
    /// The walk's bounds, whichever comes first: the same as a writing script job's (#688).
    static let entryCap = WritingScripts.entryCap
    static let secondsCap = WritingScripts.secondsCap

    /// Brian, 2026-10-26: "Allow, document risk". A mount whose root is a repository is allowed even
    /// when it holds clones of the person's own with their own `.git` folder; those stay VM-writable
    /// and are covered only by the frozen key guard (docs/sandbox_repositories.md). False refuses
    /// such a mount, naming the nested clones, as a parent mount is refused.
    static let repositoryRootAllowsNestedClones = true

    /// What one walk of a mount found.
    struct Survey: Equatable, Sendable {
        /// Folders holding a `.git` (a directory, a gitfile or a link) or a bare repository, below
        /// the root. The root itself is never listed. The walk enters none of them.
        var repositories: [String]
        var capped: Bool
        /// A folder it couldn't read, or another disk mounted inside it.
        var incomplete: String?
    }

    /// Walks `root` for repositories: links not followed, other filesystems not entered, and a
    /// repository, once found, not entered either. Stops at the entry cap or after `secondsCap` of
    /// uptime (#608).
    static func survey(_ root: String, entryCap: Int = entryCap, secondsCap: Double = secondsCap,
                       clock: UptimeClock = .live) -> Survey {
        // Nothing there holds nothing: the container's create fails on a missing source by itself.
        var info = stat()
        if lstat(root, &info) != 0, errno == ENOENT { return Survey(repositories: [], capped: false) }
        let started = clock.now()
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let resolvedRoot = IrisPaths.realPath(root)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .volumeIdentifierKey]
        let volume = (try? rootURL.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier.map { "\($0)" }
        let unreadable = OSAllocatedUnfairLock<String?>(initialState: nil)
        guard let walker = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: [],
                                                          errorHandler: { url, _ in
            unreadable.withLock { $0 = $0 ?? url.path }
            return true
        }) else {
            return Survey(repositories: [], capped: false, incomplete: "it can't be read")
        }
        var repositories: [String] = []
        var otherVolume: String?
        var entries = 0
        for case let url as URL in walker {
            if entries >= entryCap || clock.seconds(since: started) > secondsCap {
                return Survey(repositories: repositories, capped: true)
            }
            entries += 1
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if url.lastPathComponent == ".git" { walker.skipDescendants(); continue }
            if let volume, let here = values?.volumeIdentifier.map({ "\($0)" }), here != volume {
                otherVolume = otherVolume ?? spelled(url.path, root: root, resolvedRoot: resolvedRoot)
                walker.skipDescendants()
                continue
            }
            if holdsGit(url.path) || WritingScripts.isBareRepository(url.path) {
                repositories.append(spelled(url.path, root: root, resolvedRoot: resolvedRoot))
                walker.skipDescendants()
            }
        }
        let incomplete = unreadable.withLock { $0 }.map { "a folder in it can't be read (\($0))" }
            ?? otherVolume.map { "another disk is mounted inside it (\($0))" }
        return Survey(repositories: repositories, capped: false, incomplete: incomplete)
    }

    static func isRepository(_ dir: String) -> Bool { holdsGit(dir) || WritingScripts.isBareRepository(dir) }

    /// Which repository is at `dir`: its `.git`'s (or a bare repository's `HEAD`'s) device, inode
    /// and birth time, so one cloned again at the same path isn't taken for the one recorded.
    static func identity(_ dir: String) -> String? {
        var info = stat()
        guard lstat(dir + "/.git", &info) == 0 || lstat(dir + "/HEAD", &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec).\(info.st_birthtimespec.tv_nsec)"
    }

    /// Whether `dir` has a `.git` of any kind: a folder, a gitfile, or a link (never followed).
    static func holdsGit(_ dir: String) -> Bool {
        var info = stat()
        return lstat(dir + "/.git", &info) == 0
    }

    /// Why `source` may not be mounted read-write, or nil when it may. `vmMade` are repositories
    /// an earlier sandbox session made in it (`SandboxVMRepositories`), which don't count.
    static func refusal(source: String, survey: Survey, vmMade: Set<String>) -> String? {
        if survey.capped {
            return "Not run: \(source) is too large to check for git repositories (over \(entryCap) entries or \(Int(secondsCap)) seconds to walk), so the sandbox can't mount it read-write. Mount a narrower folder, such as the one repository being worked on."
        }
        if let why = survey.incomplete {
            return "Not run: \(source) can't be checked for git repositories, because \(why), so the sandbox can't mount it read-write. Mount a narrower folder, such as the one repository being worked on."
        }
        let found = survey.repositories.filter { !vmMade.contains($0) }
        guard !found.isEmpty else { return nil }
        let shown = found.prefix(5).map { "`\($0)`" }.joined(separator: ", ")
        let more = found.count > 5 ? " and \(found.count - 5) more" : ""
        return "Not run: \(source) holds git repositories (\(shown)\(more)), and the sandbox would be able to write their git config and hooks, which git on this Mac runs. Mount the one repository being worked on instead: its own git dir is kept apart from the sandbox."
    }

    /// The check for one read-write source, as a container is made: the refusal, or nil and the
    /// repositories to record as the session's start (nil when the root is a repository and isn't
    /// walked at all).
    static func check(source: String, vmRecord: SandboxVMRepositories,
                      survey: (String) -> Survey = { survey($0) }) -> (refusal: String?, start: [String]?) {
        let isRepository = isRepository(source)
        let vmMade = vmRecord.vmMade(in: source)
        // The allowance is for a repository of the person's, not a root the VM's `git init` made
        // one (#776 review): that folder is still the parent it was, so it's walked. Decided from
        // the raw record, never the identity check, which a VM could fail on purpose by making
        // the root's `.git` again (#776 re-review).
        if isRepository && repositoryRootAllowsNestedClones && !vmRecord.everVMMade(source, in: source) { return (nil, nil) }
        let found = survey(source)
        let excused = vmMade.union(vmRecord.madeDuringLiveSessions(in: source, found: found.repositories))
        if let why = refusal(source: source, survey: found, vmMade: excused) { return (why, nil) }
        return (nil, found.repositories + (isRepository ? [source] : []))
    }

    /// What `admit` decided for a container's read-write sources.
    struct Admission: Sendable {
        var refusal: String?
        /// Root → repositories at the start, for `SandboxVMRepositories.began` once the container exists.
        var starts: [String: [String]]
    }

    /// `check` for every read-write source, off the cooperative pool: the first refusal, or the
    /// starts to record once the container exists.
    static func admit(_ sources: [String], vmRecord: SandboxVMRepositories) async -> Admission {
        await OffPool.run(cancelled: Admission(refusal: "Error: the command was cancelled.", starts: [:])) { _ in
            var starts: [String: [String]] = [:]
            for source in sources {
                let (why, start) = check(source: source, vmRecord: vmRecord)
                if let why { return Admission(refusal: why, starts: [:]) }
                if let start { starts[source] = start }
            }
            return Admission(refusal: nil, starts: starts)
        }
    }

    /// A mutating job's grant, checked when the job is made, so a parent mount is refused then
    /// rather than at every fire. The fire's own container is checked again as it's made.
    static func grantRefusal(_ grant: JobGrant, paths: IrisPaths) async -> String? {
        let sources = SandboxSessionManager.readWriteMounts(workspace: grant.workspaceMount, extra: grant.extraMountEntries()).map(\.source)
        return await admit(sources, vmRecord: SandboxVMRepositories(paths: paths)).refusal
    }

    private static func spelled(_ path: String, root: String, resolvedRoot: String) -> String {
        path.hasPrefix(resolvedRoot) ? root + path.dropFirst(resolvedRoot.count) : path
    }
}

/// #658 (a), #773 P2b: the repositories a sandbox session made in the folders it mounted, so an
/// agent's own clone doesn't get the next session's mount refused. Each mount is surveyed when its
/// container is made (`began`) and again when it's removed (`ended`); a repository found only the
/// second time is recorded as the VM's. A session a crash cut short is ended once at the next
/// launch, which only records (`endAbandoned`).
///
/// It only ever feeds `ParentMount.refusal`: it refuses nothing itself, and nothing reads it per
/// command. A file that can't be read is taken as empty, which at worst gets a mount refused with
/// the repositories named. A clone the person makes in a mounted folder mid-session is recorded as
/// the VM's too, an accepted loosening.
final class SandboxVMRepositories: Sendable {
    struct Record: Codable, Equatable {
        /// Mount root → repositories the VM made in it.
        var vmMade: [String: [String]] = [:]
        /// Container name → mount root → the repositories it held when the container was made.
        var live: [String: [String: [String]]] = [:]
        /// Repository → `ParentMount.identity` when it was recorded as the VM's. It's excused only
        /// while that still matches (#776 review).
        var identities: [String: String] = [:]

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            vmMade = try c.decodeIfPresent([String: [String]].self, forKey: .vmMade) ?? [:]
            live = try c.decodeIfPresent([String: [String: [String]]].self, forKey: .live) ?? [:]
            identities = try c.decodeIfPresent([String: String].self, forKey: .identities) ?? [:]
        }
    }

    let url: URL
    private let survey: @Sendable (String) -> ParentMount.Survey
    /// One writer at a time in this process; the home's store lock keeps other processes out.
    private static let lock = NSLock()

    init(paths: IrisPaths, survey: @escaping @Sendable (String) -> ParentMount.Survey = { ParentMount.survey($0) }) {
        url = paths.configDir.appendingPathComponent("sandbox-vm-repositories.json")
        self.survey = survey
    }

    /// The repositories recorded as the VM's in `root` that are still the ones recorded: one the
    /// person cloned again at the same path isn't.
    func vmMade(in root: String) -> Set<String> {
        let r = Self.lock.withLock { load() }
        return Set((r.vmMade[root] ?? []).filter { repo in
            r.identities[repo].map { $0 == ParentMount.identity(repo) } ?? false
        })
    }

    /// Whether `repo` was ever recorded as the VM's in `root`, whatever is there now.
    func everVMMade(_ repo: String, in root: String) -> Bool {
        Self.lock.withLock { load().vmMade[root]?.contains(repo) ?? false }
    }

    /// Of `found` in `root`, those that appeared while a session mounting it is still live: its
    /// VM's, by the same reading as `ended`, before that session has ended. So a subagent, or a
    /// second session, isn't refused for the clone the first one just made.
    func madeDuringLiveSessions(in root: String, found: [String]) -> Set<String> {
        let starts = Self.lock.withLock { load().live.values.compactMap { $0[root] } }
        return Set(found.filter { repo in starts.contains { !$0.contains(repo) } })
    }

    /// `owner`'s container was made with these read-write roots, holding these repositories (the
    /// root among them when it is one). A recorded repository that's gone is dropped.
    func began(owner: String, starts: [String: [String]]) {
        guard !starts.isEmpty else { return }
        Self.lock.withLock {
            var r = load()
            for (root, repos) in starts {
                if let made = r.vmMade[root] { r.vmMade[root] = made.filter(repos.contains) }
            }
            let kept = Set(r.vmMade.values.joined())
            r.identities = r.identities.filter { kept.contains($0.key) }
            r.live[owner] = starts
            save(r)
        }
    }

    /// `owner`'s container is gone: each root it mounted is surveyed once more, and what's new is
    /// the VM's.
    func ended(owner: String) {
        Self.lock.withLock {
            var r = load()
            guard let starts = r.live.removeValue(forKey: owner) else { return }
            record(starts, into: &r)
            save(r)
        }
    }

    /// Launch: every session still recorded as live, other than `except`, was cut short by a crash
    /// or a quit. Each is ended once. This only records; it never refuses or moves anything.
    func endAbandoned(except: Set<String>) {
        Self.lock.withLock {
            var r = load()
            let abandoned = r.live.keys.filter { !except.contains($0) }
            guard !abandoned.isEmpty else { return }
            for owner in abandoned { if let starts = r.live.removeValue(forKey: owner) { record(starts, into: &r) } }
            save(r)
        }
    }

    /// What's new in each root since `starts` is the VM's, the root itself included when it has
    /// become a repository (#776 review: a `git init` at the root).
    private func record(_ starts: [String: [String]], into r: inout Record) {
        for (root, before) in starts {
            let now = survey(root).repositories + (ParentMount.isRepository(root) ? [root] : [])
            let new = now.filter { !before.contains($0) }
            guard !new.isEmpty else { continue }
            r.vmMade[root] = Array(Set(r.vmMade[root] ?? []).union(new)).sorted()
            for repo in new { r.identities[repo] = ParentMount.identity(repo) }
        }
        let kept = Set(r.vmMade.values.joined())
        r.identities = r.identities.filter { kept.contains($0.key) }
    }

    private func load() -> Record {
        guard let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(Record.self, from: data) else { return Record() }
        return r
    }

    private func save(_ r: Record) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(r) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
