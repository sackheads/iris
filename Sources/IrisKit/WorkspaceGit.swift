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
            let hooks = ([layout.commonDir] + modules(commonDir: layout.commonDir)).compactMap { dir -> WorkspaceIrisDir.Protected? in
                guard let r = self.relative(dir, inside: source) else { return nil }
                return .init(relative: (r as NSString).appendingPathComponent("hooks"), holds: "the repository's hooks")
            }
            return [.init(relative: relative, createIfMissing: false, readOnly: false, holds: "the repository")] + hooks
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
        // Submodules' repositories, each with a config and hooks of its own, nested to any depth.
        for module in modules(commonDir: layout.commonDir) {
            add((module as NSString).appendingPathComponent("config"), .config)
        }
        let worktrees = common.appendingPathComponent("worktrees")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: worktrees)) ?? [] {
            let dir = (worktrees as NSString).appendingPathComponent(name) as NSString
            add(dir.appendingPathComponent("config.worktree"), .config, ifPresent: true)
            add(dir.appendingPathComponent("commondir"), .pointer, ifPresent: true)
        }
        return files
    }

    /// The git dirs of the submodules under `commonDir/modules` that exist now: each folder there
    /// holding a `HEAD`, searched to a bounded depth (a module's path may have several parts, and
    /// a submodule its own `modules/`).
    static func modules(commonDir: String) -> [String] {
        var found: [String] = []
        func walk(_ dir: String, depth: Int) {
            guard depth < 8, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for name in names.sorted() {
                let path = (dir as NSString).appendingPathComponent(name)
                var info = stat()
                guard !name.contains(quarantineSuffix), lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
                if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("HEAD")) {
                    found.append(path)
                    walk((path as NSString).appendingPathComponent("modules"), depth: depth + 1)
                } else {
                    walk(path, depth: depth + 1)
                }
            }
        }
        walk((commonDir as NSString).appendingPathComponent("modules"), depth: 0)
        return found
    }

    /// The folders of the worktrees linked to `commonDir`, read from each `worktrees/<n>/gitdir`.
    /// Their git reads the common config too, wherever they are.
    static func linkedWorktrees(commonDir: String) -> [String] {
        let worktrees = (commonDir as NSString).appendingPathComponent("worktrees")
        return ((try? FileManager.default.contentsOfDirectory(atPath: worktrees)) ?? []).compactMap { name in
            guard let text = readSmall((worktrees as NSString).appendingPathComponent(name + "/gitdir"))
                .flatMap({ String(data: $0, encoding: .utf8) })?.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.hasPrefix("/") else { return nil }
            return (text as NSString).deletingLastPathComponent
        }
    }

    // MARK: Submodules

    /// What a submodule moved aside is renamed with (#623 2b): never deleted, so a person who
    /// trusts it can rename it back.
    static let quarantineSuffix = ".iris-quarantine"

    /// The index is read only up to this; a larger one fails the check closed.
    static let indexLimit = 128 << 20

    /// The submodule paths (gitlinks) in the index at `path`, read without running git: versions
    /// 2 to 4, SHA-1 or SHA-256 object names. `[]` when there is no index; nil when it is too
    /// large or does not parse, which the caller treats as a failed check.
    static func gitlinks(index path: String, sha256: Bool, followLink: Bool = true) -> [String]? {
        var info = stat()
        if lstat(path, &info) != 0 { return errno == ENOENT ? [] : nil }
        guard let data = readSmall(path, limit: indexLimit) else { return nil }
        let b = [UInt8](data)
        func u32(_ at: Int) -> UInt32? {
            guard at >= 0, at + 4 <= b.count else { return nil }
            return UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
        }
        guard b.count >= 12, b[0] == 0x44, b[1] == 0x49, b[2] == 0x52, b[3] == 0x43,
              let version = u32(4), (2...4).contains(version), let count = u32(8) else { return nil }
        let oid = sha256 ? 32 : 20
        var at = 12
        var previous: [UInt8] = []
        var links: [String] = []
        for _ in 0..<count {
            guard let mode = u32(at + 24), at + 40 + oid + 2 <= b.count else { return nil }
            let flags = Int(b[at + 40 + oid]) << 8 | Int(b[at + 40 + oid + 1])
            var fixed = 40 + oid + 2
            if flags & 0x4000 != 0 { guard version >= 3 else { return nil }; fixed += 2 }
            var p = at + fixed
            var name: [UInt8]
            if version == 4 {
                // Prefix-compressed: how many bytes of the previous name to drop, then the rest.
                guard p < b.count else { return nil }
                var c = b[p]; p += 1
                var strip = Int(c & 0x7f)
                while c & 0x80 != 0 {
                    guard p < b.count, strip < 1 << 24 else { return nil }
                    c = b[p]; p += 1
                    strip = ((strip + 1) << 7) | Int(c & 0x7f)
                }
                guard strip <= previous.count, let end = b[p...].firstIndex(of: 0) else { return nil }
                name = Array(previous.dropLast(strip)) + b[p..<end]
                at = end + 1
            } else {
                guard p <= b.count, let end = b[p...].firstIndex(of: 0) else { return nil }
                name = Array(b[p..<end])
                // Padded with 1 to 8 NULs to a multiple of 8.
                at += (fixed + name.count + 8) & ~7
                guard at <= b.count else { return nil }
            }
            previous = name
            if mode & 0o170000 == 0o160000 {
                guard let text = String(bytes: name, encoding: .utf8) else { return nil }
                links.append(text)
            }
        }
        // Extensions, up to the trailing checksum. A split index (`link`) keeps most entries in
        // `sharedindex.<oid>` beside it, so its gitlinks are read too; one that cannot be is a
        // failed read (#632 review: a split index hid a planted submodule).
        while at + 8 <= b.count - oid {
            guard let size = u32(at + 4), at + 8 + Int(size) <= b.count - oid else { return nil }
            if b[at] == 0x6c, b[at + 1] == 0x69, b[at + 2] == 0x6e, b[at + 3] == 0x6b {   // "link"
                guard followLink, size >= oid else { return nil }
                let hex = b[(at + 8)..<(at + 8 + oid)].map { String(format: "%02x", $0) }.joined()
                let shared = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("sharedindex." + hex)
                var info = stat()
                guard lstat(shared, &info) == 0, let more = gitlinks(index: shared, sha256: sha256, followLink: false) else { return nil }
                links += more.filter { !links.contains($0) }
            }
            at += 8 + Int(size)
        }
        return links
    }

    /// Whether `command` names `path` as a whole path: followed by its end, `/`, or a character
    /// that cannot continue a file name in a shell word, so `/x/iris` is not `/x/iris-overseer`.
    static func commandNames(_ command: String, _ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var rest = command[...]
        while let range = rest.range(of: path) {
            let next = rest[range.upperBound...].first
            if next.map({ !($0.isLetter || $0.isNumber || "-_.~+@".contains($0)) }) ?? true { return true }
            rest = rest[range.upperBound...]
        }
        return false
    }

    /// A repository-relative path that stays inside it: no `..`, no empty part, no `.git`.
    static func isPlainRelative(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.hasPrefix("/") && !parts.isEmpty
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }
    }

    /// What `<source>/<link>/.git` is now, compared between checks: missing, a pointer file's
    /// text, a folder's identity, or a link's target.
    static func pointerSignature(source: String, link: String) -> String {
        let path = (source as NSString).appendingPathComponent(link + "/.git")
        var info = stat()
        guard lstat(path, &info) == 0 else { return "absent" }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return "file:" + (readSmall(path, limit: 4096).map { String(decoding: $0, as: UTF8.self) } ?? "\(info.st_size)-\(info.st_mtimespec.tv_nsec)")
        case S_IFDIR: return "dir:\(info.st_dev)-\(info.st_ino)"
        default: return "other:\(info.st_mode)-\(info.st_ino)-\(info.st_mtimespec.tv_nsec)"
        }
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
         // Empty: git fails to run "" and signs with no default key rather than run the repo's.
         ("gpg.ssh.defaultKeyCommand", ""),
         ("interactive.diffFilter", "cat"),
         ("protocol.ext.allow", "never"),
         ("protocol.file.allow", "user")]
    }

    static let multiValued: Set<String> = ["credential.helper"]

    /// The environment additions for a host command: each override, except that a key the person
    /// set in their own global or system config keeps their value, so their signing program,
    /// credential helper or editor still work. `personal` maps a lowercased key to its values in
    /// the order git read them. `proxyCommand` is the person's own `GIT_PROXY_COMMAND`, kept.
    static func hostEnvironment(hooks: String, personal: [String: [String]], proxyCommand: String? = nil) -> [String: String] {
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
        // `core.gitProxy` set on the command line does not win over the repository's (probed, git
        // 2.54); the environment variable does, and empty connects directly.
        var env: [String: String] = ["GIT_CONFIG_COUNT": String(pairs.count), "GIT_PAGER": "cat",
                                     "GIT_PROXY_COMMAND": proxyCommand ?? ""]
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
