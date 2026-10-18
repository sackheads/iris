import Foundation

/// A git repository at the root of a read-write sandbox mount (#623). The VM may write anything in
/// the mount, and git on the Mac runs programs a repository names: hooks, and in its config
/// `core.hooksPath`, `core.fsmonitor`, `diff.external`, filter drivers and more. So a command the
/// VM ran without a prompt could choose what the person's next host `git commit` runs.
///
/// Three layers. In the VM, the repository's `.git` is a mountpoint of its own (it cannot be
/// renamed or removed) and its `hooks/` is read-only (`protected(for:)`). Its config files, which
/// the runtime cannot mount alone, are checked by `GitConfigGuard` before and after every in-VM
/// command and before every host one, and put back when a change could run a program. And a host
/// `run_command` in a sandboxed workspace runs git with the risky fixed-name keys overridden
/// (`hostEnvironment`), which covers a write that lands between a check and git reading the file.
enum WorkspaceGit {
    /// Where the repository at `source` keeps what git reads. `dotGit` is `<source>/.git`, a
    /// directory, or for a worktree a file naming its `gitDir`; `commonDir` holds the shared
    /// config and hooks (the same as `gitDir` outside a worktree).
    struct Layout: Equatable {
        var dotGitIsFile: Bool
        var gitDir: String
        var commonDir: String
        var hooks: String { (commonDir as NSString).appendingPathComponent("hooks") }
    }

    enum Entry: Equatable {
        case none
        case layout(Layout)
        /// `.git` is a symbolic link or something else Iris will not follow.
        case unsupported
    }

    static func entry(at source: String) -> Entry {
        let dotGit = (source as NSString).appendingPathComponent(".git")
        var info = stat()
        guard lstat(dotGit, &info) == 0 else { return .none }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            return .layout(Layout(dotGitIsFile: false, gitDir: dotGit, commonDir: dotGit))
        case S_IFREG:
            guard let text = readSmall(dotGit).flatMap({ String(data: $0, encoding: .utf8) }),
                  let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return .unsupported }
            let gitDir = resolve(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces), against: source)
            var commonDir = gitDir
            if let named = readSmall((gitDir as NSString).appendingPathComponent("commondir"))
                .flatMap({ String(data: $0, encoding: .utf8) })?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
                commonDir = resolve(named, against: gitDir)
            }
            return .layout(Layout(dotGitIsFile: true, gitDir: gitDir, commonDir: commonDir))
        default:
            return .unsupported
        }
    }

    /// The directories a read-write mount of `source` carries for its repository: the common dir
    /// read-write over itself, so the VM cannot swap in a repository of its own, then its `hooks/`
    /// read-only. Only what sits inside `source`; a worktree's common dir elsewhere is out of the
    /// VM's reach already. A `.git` link is listed so that preparing it refuses.
    static func protected(for source: String) -> [WorkspaceIrisDir.Protected] {
        switch entry(at: source) {
        case .none: return []
        case .unsupported:
            var info = stat()
            let dotGit = (source as NSString).appendingPathComponent(".git")
            // A worktree's `.git` file that does not parse is guarded as a file; a link refuses.
            if lstat(dotGit, &info) == 0, info.st_mode & S_IFMT == S_IFREG { return [] }
            return [.init(relative: ".git", createIfMissing: false, readOnly: false, holds: "the repository")]
        case .layout(let layout):
            guard let relative = relative(layout.commonDir, inside: source) else { return [] }
            return [.init(relative: relative, createIfMissing: false, readOnly: false, holds: "the repository"),
                    .init(relative: (relative as NSString).appendingPathComponent("hooks"), holds: "the repository's hooks")]
        }
    }

    enum FileKind { case config, pointer }

    /// The files of `source`'s repository the VM could change to make host git run a program, or
    /// read another repository's: its config files, and for a worktree the `.git` file and the
    /// gitdir's `commondir`. Only those inside `source`. A fixed name is listed whether or not it
    /// exists, so one the VM creates is caught; a linked worktree's entries only if present.
    static func watchedFiles(for source: String) -> [String: FileKind] {
        guard case .layout(let layout) = entry(at: source) else { return [:] }
        var files: [String: FileKind] = [:]
        func add(_ path: String, _ kind: FileKind, ifPresent: Bool = false) {
            guard relative(path, inside: source) != nil else { return }
            if ifPresent, !FileManager.default.fileExists(atPath: path) { return }
            files[path] = kind
        }
        let common = layout.commonDir as NSString
        add(common.appendingPathComponent("config"), .config)
        add(common.appendingPathComponent("config.worktree"), .config)
        if layout.dotGitIsFile {
            add((source as NSString).appendingPathComponent(".git"), .pointer)
            add((layout.gitDir as NSString).appendingPathComponent("config.worktree"), .config)
            add((layout.gitDir as NSString).appendingPathComponent("commondir"), .pointer)
        }
        let worktrees = common.appendingPathComponent("worktrees")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: worktrees)) ?? [] {
            let dir = (worktrees as NSString).appendingPathComponent(name) as NSString
            add(dir.appendingPathComponent("config.worktree"), .config, ifPresent: true)
            add(dir.appendingPathComponent("commondir"), .pointer, ifPresent: true)
        }
        return files
    }

    // MARK: Host overrides

    /// What a host git in a sandboxed workspace runs with in place of whatever a repository's
    /// config says, as `GIT_CONFIG_*` (read like `-c`, after every config file, by git 2.31 and
    /// later). Only fixed names: `filter.<x>.clean`, `diff.<x>.textconv`, `merge.<x>.driver`,
    /// `remote.<x>.uploadpack` and their kind cannot be listed, and are left to the config check.
    /// `hooks` is the repository's own read-only hooks folder, or `/dev/null` when Iris did not
    /// see it before the VM could write it.
    static func overrides(hooks: String) -> [(key: String, value: String)] {
        [("core.hooksPath", hooks),
         ("core.fsmonitor", "false"),
         ("core.pager", "cat"),
         ("core.editor", "true"),
         ("sequence.editor", "true"),
         ("core.sshCommand", "ssh"),
         ("core.askPass", ""),
         // An empty value empties the helper list read so far; the person's own follow it.
         ("credential.helper", ""),
         ("gpg.program", "gpg"),
         ("gpg.ssh.program", "ssh-keygen"),
         ("gpg.x509.program", "gpgsm"),
         // Not empty: git runs an empty one and fails. This is git's own diff of the two files.
         ("diff.external", #"f() { git diff --no-index --no-ext-diff -- "$2" "$5"; true; }; f"#),
         ("core.alternateRefsCommand", ""),
         ("protocol.ext.allow", "never"),
         ("protocol.file.allow", "user")]
    }

    static let multiValued: Set<String> = ["credential.helper"]

    /// The environment additions for a host command: each override, except that a key the person
    /// set in their own global or system config keeps their value, so their signing program,
    /// credential helper or editor still work. `personal` maps a lowercased key to its values in
    /// the order git read them.
    static func hostEnvironment(hooks: String, personal: [String: [String]]) -> [String: String] {
        var pairs: [(String, String)] = []
        for (key, value) in overrides(hooks: hooks) {
            let mine = personal[key.lowercased()] ?? []
            if multiValued.contains(key) {
                pairs.append((key, ""))
                pairs += mine.map { (key, $0) }
            } else {
                pairs.append((key, mine.last ?? value))
            }
        }
        var env: [String: String] = ["GIT_CONFIG_COUNT": String(pairs.count), "GIT_PAGER": "cat"]
        for (i, pair) in pairs.enumerated() {
            env["GIT_CONFIG_KEY_\(i)"] = pair.0
            env["GIT_CONFIG_VALUE_\(i)"] = pair.1
        }
        return env
    }

    /// `git config --list --show-scope` output, reduced to the override keys set at global or
    /// system scope. Global is skipped when `trustGlobal` is false: its file is in a folder the VM
    /// can write.
    static func personalValues(listing: String, trustGlobal: Bool) -> [String: [String]] {
        let wanted = Set(overrides(hooks: "").map { $0.key.lowercased() })
        var values: [String: [String]] = [:]
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, parts[0] == "system" || (trustGlobal && parts[0] == "global"),
                  let eq = parts[1].firstIndex(of: "=") else { continue }
            let key = parts[1][..<eq].lowercased()
            guard wanted.contains(key) else { continue }
            values[key, default: []].append(String(parts[1][parts[1].index(after: eq)...]))
        }
        return values
    }

    /// Where git reads the person's global config from.
    static func globalConfigFiles(base: [String: String]) -> [String] {
        let home = base["HOME"] ?? NSHomeDirectory()
        let xdg = base["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (home as NSString).appendingPathComponent(".config")
        return [(home as NSString).appendingPathComponent(".gitconfig"), (xdg as NSString).appendingPathComponent("git/config")]
    }

    // MARK: Paths

    static func resolve(_ path: String, against base: String) -> String {
        let joined = path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
        // `URL.standardized`, not `standardizingPath`, which also drops a leading `/private`.
        return URL(fileURLWithPath: joined).standardized.path
    }

    /// `path` relative to `root` when it lies strictly inside it, comparing real paths, so a
    /// spelling through `/tmp` or `..` cannot step out.
    static func relative(_ path: String, inside root: String) -> String? {
        let realRoot = IrisPaths.realPath(root)
        let realPath = realParent(path)
        let prefix = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        guard realPath.hasPrefix(prefix) else { return nil }
        return String(realPath.dropFirst(prefix.count))
    }

    /// The real path of `path`'s parent joined to its last component: the file itself may be
    /// missing or a link, and is judged as itself.
    private static func realParent(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path).standardized.path
        let parent = (standard as NSString).deletingLastPathComponent
        return (IrisPaths.realPath(parent) as NSString).appendingPathComponent((standard as NSString).lastPathComponent)
    }

    static func readSmall(_ path: String, limit: Int = 1 << 20) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { return nil }
        return try? handle.readToEnd() ?? Data()
    }
}
