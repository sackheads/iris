import CryptoKit
import Foundation

/// The sandbox's own git dir (#658). A repository at the root of a read-write sandbox mount gets a
/// VM-only copy of its common dir, kept under Iris's home and mounted over the host common dir's
/// path inside the VM, so git in the VM reads and writes that copy and never the person's `.git`.
/// The host's common dir goes in read-only at `/iris-host-git/<key>`, and the copy reaches its
/// objects through alternates, so nothing large is copied.
///
/// One rule covers a plain repository and a linked worktree: the copy is mounted at the host
/// common dir's own path, which for a plain repository is `<workspace>/.git` and for a worktree
/// is wherever its `.git` file points (an absolute path, the same inside the VM). Two workspaces of
/// one repository share the copy, keyed by the canonical common dir; git's own locks cover two
/// containers using it at once.
///
/// What host git can still read that the VM wrote: files in the shared worktree. A submodule's or
/// a worktree's `.git` pointer file is one (`pointerProblems`), and `.gitmodules` and
/// `.lfsconfig` are others (`watchedWorktreeFiles`). Commits reach the host through a bundle
/// (`SandboxGitSync`), a plain data file, never by host git reading the copy.
enum SandboxGit {
    /// Where the copy lives, and how it is mounted.
    struct Repo: Equatable, Sendable {
        /// The workspace (mount source) whose root holds the repository.
        var source: String
        /// Its path inside the VM (the mount's target).
        var target: String
        var hostCommonDir: String
        /// For a linked worktree, its own git dir under the common dir's `worktrees/`.
        var hostGitDir: String
        var isWorktree: Bool
        /// The copy on the host.
        var vmDir: String
        /// Where the copy is mounted inside the VM.
        var vmCommonDir: String
        /// Where the host common dir is mounted read-only inside the VM.
        var hostMount: String

        /// The two mounts, in `ContainerMount`'s `source:target[:ro]` form, listed after the
        /// workspace mount they may sit inside.
        var mounts: [String] { ["\(vmDir):\(vmCommonDir)", "\(hostCommonDir):\(hostMount):ro"] }
    }

    enum Prepared: Equatable {
        /// No repository at the mount's root.
        case none
        case repo(Repo)
        /// A `.git` Iris will not use (a link, a `.git` file that does not parse, a copy it could
        /// not make): the command is refused rather than run with the person's `.git` writable.
        case refused(String)
    }

    static let hostMountRoot = "/iris-host-git"
    static let seedMarker = "iris-sandbox-seed"
    static let bundleName = "iris-sync.bundle"

    static func directory(paths: IrisPaths = .default) -> String {
        paths.root.appendingPathComponent("sandbox-git").path
    }

    /// The copy for the repository at `source`, made now if it is not there yet or no longer
    /// belongs to the repository there (re-created since), and the mounts to give it.
    static func prepare(source: String, target: String, paths: IrisPaths = .default) -> Prepared {
        let layout: WorkspaceGit.Layout
        switch WorkspaceGit.entry(at: source) {
        case .none: return .none
        case .unsupported: return .refused(refusal(source, "its .git is a link or a file Iris cannot read"))
        case .layout(let found): layout = found
        }
        let common = IrisPaths.realPath(layout.commonDir)
        let key = Self.key(common)
        let vmDir = (directory(paths: paths) as NSString).appendingPathComponent(key)
        let vmCommonDir: String
        if let relative = WorkspaceGit.relative(layout.commonDir, inside: source) {
            vmCommonDir = (target as NSString).appendingPathComponent(relative)
        } else {
            // A worktree's `.git` file names the common dir by its absolute host path, which is
            // the same inside the VM.
            vmCommonDir = common
        }
        let hostMount = (hostMountRoot as NSString).appendingPathComponent(key)
        do {
            try seed(hostCommonDir: common, vmDir: vmDir, hostMount: hostMount)
        } catch {
            return .refused(refusal(source, "Iris could not make the sandbox's copy of it (\(error.localizedDescription))"))
        }
        return .repo(Repo(source: source, target: target, hostCommonDir: common,
                          hostGitDir: IrisPaths.realPath(layout.gitDir), isWorktree: layout.dotGitIsFile,
                          vmDir: vmDir, vmCommonDir: vmCommonDir, hostMount: hostMount))
    }

    static func key(_ commonDir: String) -> String {
        SHA256.hash(data: Data(commonDir.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private static func refusal(_ source: String, _ why: String) -> String {
        "Not run: \(source) holds a git repository, and \(why). The sandbox mounts it only with a git dir of its own, so git in the VM never writes yours."
    }

    // MARK: - Seeding

    /// Identity of a host common dir, so a copy made for a repository that has since been removed
    /// and made again is not reused (its alternates would name objects that are gone).
    private static func identity(_ dir: String) -> String? {
        var info = stat()
        guard stat(dir, &info) == 0 else { return nil }
        return "\(dir)\n\(info.st_dev):\(info.st_ino)\n"
    }

    /// Makes the copy: everything in the host common dir but its objects, hooks and logs, with
    /// alternates onto the host's objects as the VM sees them. Its config, refs, HEAD, index and
    /// `info/exclude` are the host's at the time, so git in the VM starts where the person is.
    /// Kept across sessions; reused while it belongs to the same repository.
    static func seed(hostCommonDir: String, vmDir: String, hostMount: String) throws {
        let fm = FileManager.default
        guard let identity = identity(hostCommonDir) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: hostCommonDir])
        }
        let marker = (vmDir as NSString).appendingPathComponent(seedMarker)
        if let existing = WorkspaceGit.readSmall(marker), existing == Data(identity.utf8) { return }
        try fm.createDirectory(atPath: (vmDir as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // Made beside it and renamed in, so a half-made copy is never mounted.
        let staging = vmDir + ".seeding-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: staging) }
        try copyTree(from: hostCommonDir, to: staging)
        try writeAlternates(in: staging, hostMount: hostMount, relative: "")
        try Data(identity.utf8).write(to: URL(fileURLWithPath: (staging as NSString).appendingPathComponent(seedMarker)))
        if fm.fileExists(atPath: vmDir) {
            // A copy for a repository that is gone. Its commits were fetched to the host when they
            // were made, so nothing here is the only copy of anything.
            try fm.removeItem(atPath: vmDir)
        }
        try fm.moveItem(atPath: staging, toPath: vmDir)
    }

    /// Skipped at the top of a git dir (the common dir, a submodule's or a worktree's: a folder
    /// holding `HEAD`), never deeper, where a branch may have any of these names: what holds
    /// objects (reached through alternates instead), what runs programs, and logs. Stale locks
    /// anywhere.
    private static func skipped(_ name: String, atGitDirTop: Bool) -> Bool {
        name.hasSuffix(".lock") || atGitDirTop && (name == "objects" || name == "hooks" || name == "logs")
    }

    private static func copyTree(from source: String, to destination: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let top = fm.fileExists(atPath: (source as NSString).appendingPathComponent("HEAD"))
        for name in try fm.contentsOfDirectory(atPath: source) where !skipped(name, atGitDirTop: top) {
            let from = (source as NSString).appendingPathComponent(name)
            let to = (destination as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(from, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: try copyTree(from: from, to: to)
            case S_IFREG: try fm.copyItem(atPath: from, toPath: to)
            default: continue   // links, sockets: not part of a repository git needs
            }
        }
        if top { try fm.createDirectory(atPath: (destination as NSString).appendingPathComponent("hooks"), withIntermediateDirectories: true) }
    }

    /// `objects/info/alternates` for the copy and each submodule repository in it, naming the
    /// matching host objects under the read-only mount.
    private static func writeAlternates(in dir: String, hostMount: String, relative: String) throws {
        let here = (dir as NSString).appendingPathComponent(relative)
        let info = ((here as NSString).appendingPathComponent("objects") as NSString).appendingPathComponent("info")
        try FileManager.default.createDirectory(atPath: info, withIntermediateDirectories: true)
        let host = ((hostMount as NSString).appendingPathComponent(relative) as NSString).appendingPathComponent("objects")
        try Data((host + "\n").utf8).write(to: URL(fileURLWithPath: (info as NSString).appendingPathComponent("alternates")))
        for module in WorkspaceGit.modules(commonDir: here) {
            guard let sub = WorkspaceGit.relative(module, inside: dir) else { continue }
            if sub == relative { continue }
            try writeAlternates(in: dir, hostMount: hostMount, relative: sub)
        }
    }

    /// Removes copies no workspace in `inUse` needs any more.
    static func prune(inUse sources: [String], paths: IrisPaths = .default) {
        let dir = directory(paths: paths)
        var keep: Set<String> = []
        for source in sources {
            if case .layout(let layout) = WorkspaceGit.entry(at: source) { keep.insert(key(IrisPaths.realPath(layout.commonDir))) }
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where !keep.contains(name) {
            // Only what Iris made: a finished copy, or a staging folder left by a crash.
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(seedMarker)) || name.contains(".seeding-") {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    // MARK: - What host git reads from the shared worktree

    /// Each `.git` pointer file host git would follow in `source` that does not lead into the
    /// host's own repository, `commonDir` as Iris recorded it when it made the copy (never as the
    /// worktree's `.git` file says, which the VM can rewrite): the root `.git` when it is a file
    /// (a worktree, a separate git dir), and each submodule's in the host index. A VM commit
    /// synced to the host can add gitlinks, so the set is read from the index each time.
    ///
    /// A submodule whose `.git` is a folder in the worktree is a repository of its own there, like
    /// any nested repository: not checked here (moving the person's own aside would break it).
    static func pointerProblems(source: String, commonDir: String) -> [(relative: String, points: String)] {
        guard case .layout(let layout) = WorkspaceGit.entry(at: source) else {
            return []
        }
        let common = IrisPaths.realPath(commonDir)
        var problems: [(String, String)] = []
        if layout.dotGitIsFile {
            let gitDir = IrisPaths.realPath(layout.gitDir)
            if gitDir != common && !isInside(gitDir, (common as NSString).appendingPathComponent("worktrees")) {
                problems.append((".git", gitDir))
                return problems   // its index is not the host's: nothing below can be read from it
            }
        }
        let index = (layout.gitDir as NSString).appendingPathComponent("index")
        let links = WorkspaceGit.gitlinks(index: index, sha256: false) ?? WorkspaceGit.gitlinks(index: index, sha256: true) ?? []
        let modules = (common as NSString).appendingPathComponent("modules")
        for link in links where WorkspaceGit.isPlainRelative(link) {
            let dotGit = ((source as NSString).appendingPathComponent(link) as NSString).appendingPathComponent(".git")
            var info = stat()
            guard lstat(dotGit, &info) == 0 else { continue }   // not checked out: git reads nothing there
            if info.st_mode & S_IFMT == S_IFDIR { continue }
            guard info.st_mode & S_IFMT == S_IFREG,
                  let text = WorkspaceGit.readSmall(dotGit).flatMap({ String(data: $0, encoding: .utf8) }),
                  let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else {
                problems.append((link + "/.git", "a file that is not a gitdir pointer"))
                continue
            }
            let named = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            let resolved = IrisPaths.realPath(named.hasPrefix("/") ? named
                : (((source as NSString).appendingPathComponent(link)) as NSString).appendingPathComponent(named))
            if !isInside(resolved, modules) { problems.append((link + "/.git", resolved)) }
        }
        return problems
    }

    private static func isInside(_ path: String, _ dir: String) -> Bool {
        let root = IrisPaths.realPath(dir)
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Moves each pointer that leads outside the host's repository aside (never deletes it), so
    /// host git reads nothing it names, and says what it did.
    static func quarantinePointers(source: String, commonDir: String) -> [String] {
        let root = IrisPaths.realPath(source)
        return pointerProblems(source: source, commonDir: commonDir).map { problem in
            let path = (source as NSString).appendingPathComponent(problem.relative)
            if let moved = GitConfigGuard.quarantine(root: root, relative: problem.relative) {
                return "\(path) pointed git at \(problem.points), outside your repository; Iris moved it aside to \(moved) so git on your Mac does not use it. If you trust it, rename it back."
            }
            return "\(path) points git at \(problem.points), outside your repository, and Iris could not move it aside. Check it before running git on your Mac."
        }
    }

    /// The worktrees of every repository with a copy, with its common dir: the main checkout and
    /// each linked worktree the host common dir lists. Read from the host's own files and Iris's
    /// marker, which the VM cannot write.
    static func knownWorktrees(paths: IrisPaths = .default) -> [(worktree: String, commonDir: String)] {
        let dir = directory(paths: paths)
        var worktrees: [(String, String)] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            let marker = ((dir as NSString).appendingPathComponent(name) as NSString).appendingPathComponent(seedMarker)
            guard let text = WorkspaceGit.readSmall(marker).flatMap({ String(data: $0, encoding: .utf8) }),
                  let common = text.split(separator: "\n").first.map(String.init) else { continue }
            if (common as NSString).lastPathComponent == ".git" { worktrees.append(((common as NSString).deletingLastPathComponent, common)) }
            worktrees += WorkspaceGit.linkedWorktrees(commonDir: common).map { ($0, common) }
        }
        return worktrees
    }

    /// `quarantinePointers` over every known worktree, before a host command: the notice, or nil.
    static func checkHostPointers(paths: IrisPaths = .default) -> String? {
        let notes = knownWorktrees(paths: paths).flatMap { quarantinePointers(source: $0.worktree, commonDir: $0.commonDir) }
        return notes.isEmpty ? nil : "[sandbox] " + notes.joined(separator: " ")
    }

    /// The worktree files host git (or git-lfs) reads that only name data, never a program, but
    /// that a person should know the sandbox changed: submodule URLs and LFS endpoints.
    static let watchedWorktreeFiles = [".gitmodules", ".lfsconfig"]

    static func worktreeSnapshot(source: String) -> [String: Data?] {
        Dictionary(uniqueKeysWithValues: watchedWorktreeFiles.map { name in
            (name, WorkspaceGit.readSmall((source as NSString).appendingPathComponent(name)))
        })
    }

    static func worktreeNotes(source: String, before: [String: Data?]) -> [String] {
        let after = worktreeSnapshot(source: source)
        return watchedWorktreeFiles.compactMap { name -> String? in
            guard (before[name] ?? nil) != (after[name] ?? nil) else { return nil }
            let path = (source as NSString).appendingPathComponent(name)
            return name == ".gitmodules"
                ? "The sandbox changed \(path). Submodule URLs in it are used by `git submodule sync` and `update` on your Mac; check them before running either."
                : "The sandbox changed \(path). git-lfs on your Mac uses its `lfs.url` for downloads and uploads; check it before pulling or pushing LFS files."
        }
    }
}
