import Foundation

/// What one read-write mount of a writing script job holds (#688): its files and bytes, and any git
/// repository in it, from one capped walk that follows no link and stays on one filesystem. Taken
/// before and after every run: before, a repository or a walk that can't finish refuses the run;
/// after, a repository the script made, or a large growth or loss, pauses the job.
struct MountSurvey: Codable, Equatable, Sendable {
    var entries: Int
    var bytes: Int64
    /// Directories holding a `.git` (a directory or a gitfile), the mount's root included.
    var repositories: [String]
    /// The walk stopped at its cap, so the counts are partial and the mount can't be shown free of
    /// repositories.
    var capped: Bool

    init(entries: Int, bytes: Int64, repositories: [String], capped: Bool) {
        self.entries = entries; self.bytes = bytes; self.repositories = repositories; self.capped = capped
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent(Int.self, forKey: .entries) ?? 0
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        repositories = try c.decodeIfPresent([String].self, forKey: .repositories) ?? []
        capped = try c.decodeIfPresent(Bool.self, forKey: .capped) ?? false
    }
}

/// One read-write mount's figures for a run's ledger row (#688).
struct MountFigures: Codable, Equatable, Sendable {
    var source: String
    var before: MountSurvey
    var after: MountSurvey?

    init(source: String, before: MountSurvey, after: MountSurvey?) {
        self.source = source; self.before = before; self.after = after
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        before = try c.decodeIfPresent(MountSurvey.self, forKey: .before) ?? MountSurvey(entries: 0, bytes: 0, repositories: [], capped: true)
        after = try c.decodeIfPresent(MountSurvey.self, forKey: .after)
    }
}

enum WritingScripts {
    /// The walk's bounds (planner): whichever comes first.
    static let entryCap = 200_000
    static let secondsCap = 2.0
    /// The free space a read-write mount's disk must have for a fire (planner: fixed, not a share).
    static let floorBytes: Int64 = 5 * 1_073_741_824

    /// Walks `root`: every entry counted and every regular file's size summed, links not followed,
    /// other filesystems skipped, and a `.git` noted (and not entered) wherever it is. Stops at the
    /// entry cap or after `secondsCap` of uptime (#608: a sleep isn't time spent).
    static func survey(_ root: String, entryCap: Int = entryCap, secondsCap: Double = secondsCap,
                       clock: UptimeClock = .live) -> MountSurvey {
        let started = clock.now()
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        var repositories: [String] = []
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: rootURL.appendingPathComponent(".git").path, isDirectory: &isDir) || isSymlink(rootURL.appendingPathComponent(".git")) {
            repositories.append(root)
        }
        // The walker reports resolved paths (`/private/var` for `/var`); a repository is named as
        // the caller spells the mount, so a refusal reads in the person's own path.
        // `realpath`, not `resolvingSymlinksInPath`, which strips `/private` rather than adding it.
        let resolvedRoot = IrisPaths.realPath(root)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .volumeIdentifierKey]
        let volume = (try? rootURL.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier.map { "\($0)" }
        guard let walker = fm.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return MountSurvey(entries: 0, bytes: 0, repositories: repositories, capped: true)
        }
        var entries = 0
        var bytes: Int64 = 0
        for case let url as URL in walker {
            if entries >= entryCap || clock.seconds(since: started) > secondsCap {
                return MountSurvey(entries: entries, bytes: bytes, repositories: repositories, capped: true)
            }
            entries += 1
            let values = try? url.resourceValues(forKeys: Set(keys))
            if url.lastPathComponent == ".git" {
                let holder = spelled(url.deletingLastPathComponent().path, root: root, resolvedRoot: resolvedRoot)
                if holder != root, !repositories.contains(holder) { repositories.append(holder) }
                if values?.isDirectory == true { walker.skipDescendants() }
                continue
            }
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true, let volume, let here = values?.volumeIdentifier.map({ "\($0)" }), here != volume {
                walker.skipDescendants()
                continue
            }
            if values?.isRegularFile == true { bytes += Int64(values?.fileSize ?? 0) }
        }
        return MountSurvey(entries: entries, bytes: bytes, repositories: repositories, capped: false)
    }

    private static func spelled(_ path: String, root: String, resolvedRoot: String) -> String {
        path.hasPrefix(resolvedRoot) ? root + path.dropFirst(resolvedRoot.count) : path
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// Free bytes on `path`'s filesystem, or nil when it can't be read.
    static func freeBytes(_ path: String) -> Int64? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    /// Why a writing script job may not use these mounts, from their surveys: a repository in one,
    /// or one too large to check. Used at creation and before every fire.
    static func refusal(_ surveys: [(source: String, survey: MountSurvey)]) -> String? {
        for (source, survey) in surveys {
            if let repo = survey.repositories.first { return GateEvaluator.writingScriptRepositoryRefusal(repo) }
            if survey.capped {
                return "\(source) is too large to check for repositories quickly (over \(entryCap) entries or \(Int(secondsCap)) seconds to walk), so a writing script job can't mount it read-write. Mount a smaller folder, or mount this one read-only."
            }
        }
        return nil
    }

    /// The creation check (#688): each read-write mount of `grant` surveyed (off the pool), and
    /// refused for a repository or a walk that can't finish.
    static func creationRefusal(_ grant: JobGrant) async -> String? {
        let sources = SandboxSessionManager.readWriteMounts(workspace: grant.workspaceMount, extra: grant.extraMountEntries()).map(\.source)
        var surveys: [(source: String, survey: MountSurvey)] = []
        for source in sources {
            surveys.append((source, await OffPool.run(cancelled: MountSurvey(entries: 0, bytes: 0, repositories: [], capped: true)) { _ in
                survey(source)
            }))
        }
        return refusal(surveys)
    }

    /// The 5 GB floor, before a fire (planner).
    static func floorRefusal(_ sources: [String], freeBytes: (String) -> Int64?) -> String? {
        for source in sources {
            guard let free = freeBytes(source) else { continue }
            if free < floorBytes {
                return "the disk holding \(source) has only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free, under the 5 GB a writing script job needs"
            }
        }
        return nil
    }

    /// Why a run's effect on its mounts pauses the job (planner): a repository it made, or growth
    /// over max(2 GB, 100%), a byte loss over max(1 GB, 20%), or a file-count drop over
    /// max(1,000, 20%). Nil when nothing did, or when either survey was capped.
    static func pauseReason(_ figures: [MountFigures]) -> String? {
        for f in figures {
            guard let after = f.after else { continue }
            if let made = after.repositories.first(where: { !f.before.repositories.contains($0) }) {
                return "this run made a git repository at \(made); the job is paused and the folder left as it is, so you can decide what to do with it"
            }
            guard !f.before.capped, !after.capped else { continue }
            let grew = after.bytes - f.before.bytes
            if grew > max(2 * 1_073_741_824, f.before.bytes) {
                return "this run added \(size(grew)) to \(f.source); paused so you can look"
            }
            let lost = f.before.bytes - after.bytes
            let dropped = f.before.entries - after.entries
            if lost > max(1_073_741_824, f.before.bytes / 5) || dropped > max(1_000, f.before.entries / 5) {
                return "this run removed \(max(0, dropped)) files (\(size(max(0, lost)))) from \(f.source); it may have deleted more than it should, so the job is paused"
            }
        }
        return nil
    }

    /// The first repository a run made in one of its mounts, if any.
    static func madeRepository(_ figures: [MountFigures]) -> String? {
        for f in figures {
            if let made = f.after?.repositories.first(where: { !f.before.repositories.contains($0) }) { return made }
        }
        return nil
    }

    private static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
