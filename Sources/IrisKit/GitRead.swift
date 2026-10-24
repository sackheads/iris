import Foundation

/// A git read a Vibecop APPROVE may run on the host with no prompt (#607). Off since #606, because a
/// repository's config and attributes run programs on reads. It comes back only where both halves
/// are handled:
/// - the git dir (config, `info/attributes`, hooks) is out of every sandbox's reach, so what it
///   says is the person's own (`repositoryOutOfReach`); a nested or VM-made repository still asks;
/// - the worktree (`.gitattributes`, `.gitmodules`) is neutralised on every run: the attributes
///   come from the empty tree (`prefix`), the attributes file and every program-running key are
///   overridden (`environment`), and submodules aren't entered.
/// It runs as argv, with no shell: `git` + `prefix` + the judged words + the subcommand's forced
/// flags (`argv`). That's the one place Iris adds to what was judged (planner, fork A), and the
/// result shows it.
enum GitRead {
    /// What a silent read says when the repository isn't the person's own by the time it runs.
    static let notRunHere = "Not run: by the time it ran, this repository's git folder was one a sandbox can write (or Iris couldn't check), so a git read here needs your approval. Ask again to be asked."

    /// git's empty tree: attributes read from it are none, so no worktree `.gitattributes` can pick
    /// a filter, textconv or diff driver (probed on git 2.50 and 2.54; the `GIT_ATTR_SOURCE`
    /// variable had no effect, so it's an argument).
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    /// What Iris puts before every silent git read's own words. The one constant (planner).
    static let prefix = ["--attr-source=\(emptyTree)"]
    /// `--attr-source` needs git 2.40 or later; an older one asks.
    static let minimumVersion = (2, 40)

    /// The subcommands a silent read may be, each with its options: an allowlist, as every program's.
    /// Global options before the subcommand are all refused (`-c`, `-C`, `--git-dir`, `-p`, …).
    static let subcommands: [String: ReadOnlyCommand.Flags] = [
        "status": .init(short: Set("sb"), long: ["short", "branch", "porcelain", "ignored", "untracked-files"]),
        "diff": .init(short: Set("w"), shortValued: Set("U"),
                      long: ["stat", "name-only", "name-status", "cached", "staged", "numstat", "shortstat",
                             "no-color", "word-diff", "ignore-all-space", "patience", "histogram", "minimal"],
                      longValued: ["unified", "diff-filter"]),
        "log": logFlags,
        "show": logFlags,
        "blame": .init(short: Set("wsl"), shortValued: Set("LCM"), long: ["porcelain", "line-porcelain", "show-email"]),
        "rev-parse": .init(long: ["abbrev-ref", "show-toplevel", "short", "verify", "is-inside-work-tree", "show-prefix"]),
        "ls-files": .init(short: Set("mocdst"), long: ["others", "modified", "cached", "deleted", "exclude-standard"]),
        "branch": .init(short: Set("arv"), long: ["all", "remotes", "verbose", "show-current", "list", "no-color"]),
        "describe": .init(long: ["tags", "always", "long", "all", "abbrev"], longValued: ["match"]),
        "shortlog": .init(short: Set("sne"), long: ["summary", "numbered", "email"]),
    ]

    private static let logFlags = ReadOnlyCommand.Flags(
        short: Set("p0123456789"), shortValued: Set("n"),
        long: ["oneline", "stat", "patch", "graph", "decorate", "no-decorate", "name-only", "name-status",
               "first-parent", "reverse", "no-merges", "merges", "all", "no-color", "abbrev-commit", "shortstat",
               "color", "pretty"],
        longValued: ["since", "until", "after", "before", "author", "committer", "grep", "format",
                     "max-count", "date", "skip"])

    /// Options whose value is optional and only ever attached (`--porcelain=v2`, `--color=never`):
    /// judged by name, so the next word is never taken as their value.
    static let optionalValued: Set<String> = ["porcelain", "untracked-files", "color", "stat", "word-diff",
                                              "abbrev", "decorate", "short", "pretty"]

    /// Options refused on any subcommand, even where a listed one would read them as a value: each
    /// runs a program, writes a file or reads one outside the repository (planner, #607).
    static let refusedOptions: Set<String> = ["--show-signature", "--verify-signatures", "--output",
                                              "--ext-diff", "--textconv", "--no-index", "--contents",
                                              "--git-path", "--dirty", "--broken", "--exec", "--attr-source"]

    /// Flags Iris adds after the subcommand, so a read can't enter a submodule or run a driver.
    static func forced(_ subcommand: String) -> [String] {
        switch subcommand {
        case "status": return ["--ignore-submodules=all"]
        case "diff": return ["--ignore-submodules=all", "--no-ext-diff", "--no-textconv"]
        case "log", "show": return ["--no-ext-diff", "--no-textconv", "--no-show-signature"]
        case "blame": return ["--no-textconv"]
        default: return []
        }
    }

    /// Whether `args` (the words after `git`) are a read this allows.
    static func isReadOnly(_ args: [String]) -> Bool {
        guard let subcommand = args.first, let flags = subcommands[subcommand] else { return false }
        let rest = Array(args.dropFirst())
        for word in rest {
            let name = String(word.prefix { $0 != "=" })
            if refusedOptions.contains(name) { return false }
            // A format placeholder that verifies a signature (`%G?`, `%GS`, …) runs gpg.
            if word.contains("%G") { return false }
        }
        if subcommand == "branch", rest.contains(where: { !$0.hasPrefix("-") }) { return false }
        if subcommand == "rev-parse", rest.contains(where: { $0.hasPrefix("--git-") }) { return false }
        let judged = rest.map { word -> String in
            guard word.hasPrefix("--"), let eq = word.firstIndex(of: "=") else { return word }
            let name = String(word[word.index(word.startIndex, offsetBy: 2)..<eq])
            return optionalValued.contains(name) ? "--" + name : word
        }
        return ReadOnlyCommand.flagsAllowed(judged, flags)
    }

    /// The argv a judged git read runs as: `git`, the prefix, the subcommand, its forced flags, then
    /// the rest of the judged words. Nil for anything that isn't an allowed read.
    static func argv(_ command: String) -> [String]? {
        guard let words = ReadOnlyCommand.words(command), words.first == "git",
              isReadOnly(Array(words.dropFirst())), let subcommand = words.dropFirst().first else { return nil }
        return ["git"] + prefix + [subcommand] + forced(subcommand) + Array(words.dropFirst(2))
    }

    /// The `GIT_*` a silent read adds to `ReadOnlyCommand.restrictedEnvironment`: the host overrides
    /// every sandboxed workspace's git runs with (`WorkspaceGit.overrides`, one list), plus the keys
    /// a read can reach that those don't cover.
    static func environment() -> [String: String] {
        let pairs = WorkspaceGit.overrides(hooks: "/dev/null") + readOverrides
        var env: [String: String] = ["GIT_CONFIG_COUNT": String(pairs.count), "GIT_PAGER": "cat",
                                     "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0",
                                     "GIT_NO_REPLACE_OBJECTS": "1"]
        for (i, pair) in pairs.enumerated() {
            env["GIT_CONFIG_KEY_\(i)"] = pair.key
            env["GIT_CONFIG_VALUE_\(i)"] = pair.value
        }
        return env
    }

    /// The keys a read reaches that `WorkspaceGit.overrides` leaves: an attributes file outside the
    /// worktree (`--attr-source` doesn't cover it, probed), signature checks on `log`/`show` (which
    /// run `gpg.program`), and submodule summaries.
    static let readOverrides: [(key: String, value: String)] = [
        ("core.attributesFile", "/dev/null"),
        ("log.showSignature", "false"),
        ("status.submoduleSummary", "false"),
        ("diff.submodule", "short"),
    ]

    /// The repository a silent read runs on: its git dir, common dir, and work tree (nil for a bare
    /// one). The run pins exactly these (`GIT_DIR`, `GIT_WORK_TREE`), so git can't open anything
    /// the walk didn't judge (#758 review: git's own discovery also takes a directory that is itself
    /// a git dir, and a VM-written one inside the person's repository was opened in its place).
    struct Repository: Equatable, Sendable {
        var gitDir: String
        var commonDir: String
        var workTree: String?
    }

    /// git's discovery, without running git: upward from `cwd`, at each level a `.git` (a directory,
    /// or a file's `gitdir:`), then the level itself if it's a git dir (`HEAD`, `objects/`, `refs/`).
    /// Nil when there's none, or a `.git` file can't be read.
    static func repository(from cwd: String) -> Repository? {
        var dir = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                let gitDir: URL
                if isDir.boolValue {
                    gitDir = dotGit
                } else {
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ") else { return nil }
                    let target = String(line.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespaces)
                    gitDir = URL(fileURLWithPath: target, relativeTo: dir)
                }
                let resolved = gitDir.resolvingSymlinksInPath().standardizedFileURL
                return Repository(gitDir: resolved.path, commonDir: commonDir(of: resolved), workTree: dir.path)
            }
            if isGitDirectory(dir.path) {
                return Repository(gitDir: dir.path, commonDir: commonDir(of: dir), workTree: nil)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    private static func commonDir(of gitDir: URL) -> String {
        guard let text = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) else { return gitDir.path }
        return URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDir)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// git's own test for a git directory (`is_git_directory`): a `HEAD` file, and `objects/` and
    /// `refs/` directories.
    static func isGitDirectory(_ path: String) -> Bool {
        let fm = FileManager.default
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: path + "/HEAD", isDirectory: &dir), !dir.boolValue else { return false }
        return fm.fileExists(atPath: path + "/objects", isDirectory: &dir) && dir.boolValue
            && fm.fileExists(atPath: path + "/refs", isDirectory: &dir) && dir.boolValue
    }

    /// The repository a read in `cwd` would run on, if it's the person's own: its git dir and
    /// common dir outside every folder a sandbox can write. Nil otherwise, so the read asks.
    static func ownRepository(cwd: String, writableRoots: [String]) -> Repository? {
        guard let repo = repository(from: cwd) else { return nil }
        let roots = writableRoots.map { URL(fileURLWithPath: IrisEngine.expandTilde($0)).resolvingSymlinksInPath().standardizedFileURL.path }
        func inRoot(_ path: String) -> Bool {
            roots.contains { root in root == "/" || path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
        }
        // The cwd and every level up to the repository found, as well as its git dirs (dev-2's
        // review): a sandbox that can write any of them could plant what git's discovery would take
        // first, so this doesn't rest on the walk matching git's discovery exactly.
        let top = repo.workTree ?? repo.gitDir
        var level = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
        while true {
            if inRoot(level) { return nil }
            if level == top || !level.hasPrefix(top) { break }
            let parent = (level as NSString).deletingLastPathComponent
            if parent == level { break }
            level = parent
        }
        return inRoot(repo.gitDir) || inRoot(repo.commonDir) ? nil : repo
    }

    /// The variables that pin a read to `repo`, and drop the global config: `~/.gitconfig` and
    /// `~/.config/git/config` (and what they include) aren't under the git-dir rule, and a sandbox
    /// that can write the home folder could write them (#758 review).
    static func pinning(_ repo: Repository) -> [String: String] {
        var env = ["GIT_DIR": repo.gitDir, "GIT_CONFIG_GLOBAL": "/dev/null"]
        if let workTree = repo.workTree { env["GIT_WORK_TREE"] = workTree }
        return env
    }

    /// Whether a read in `cwd` would run on the person's own repository (`ownRepository`).
    static func repositoryOutOfReach(cwd: String, writableRoots: [String]) -> Bool {
        ownRepository(cwd: cwd, writableRoots: writableRoots) != nil
    }

    /// The git a restricted `PATH` would run.
    static func executable(on path: [String], isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        path.map { $0 + "/git" }.first(where: isExecutable)
    }

    /// `git version 2.50.1 (Apple Git-155)` → whether it's at least `minimumVersion`.
    static func supports(versionOutput: String) -> Bool {
        guard let range = versionOutput.range(of: #"\d+\.\d+"#, options: .regularExpression) else { return false }
        let parts = versionOutput[range].split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        return (parts[0], parts[1]) >= minimumVersion
    }

    private static let versions = VersionCache()

    /// Whether the git at `executable` is new enough, asked once per binary: cached by path, inode
    /// and modification time, so an upgraded or replaced git is asked again (planner, fork B). A
    /// version that can't be read is "no", and the read asks.
    static func versionSupported(executable: String) async -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: executable) else { return false }
        let key = "\(executable)|\(attributes[.systemFileNumber] ?? "")|\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        if let known = versions.get(key) { return known }
        let result = await ProcessGroupRunner.capture(executable: executable, arguments: ["--version"],
                                                      environment: ["PATH": "/usr/bin:/bin"], timeoutSeconds: 5)
        let ok: Bool
        if case .success(let output) = result, output.status == 0 {
            ok = supports(versionOutput: String(decoding: output.stdout, as: UTF8.self))
        } else {
            ok = false
        }
        versions.set(key, ok)
        return ok
    }

    private final class VersionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: Bool] = [:]
        func get(_ key: String) -> Bool? { lock.withLock { known[key] } }
        func set(_ key: String, _ value: Bool) { lock.withLock { known[key] = value } }
    }
}
