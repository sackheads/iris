import Foundation

/// #1435 slice 2: the broker-owned bare mirror `vcs fetch` and `vcs push` go through. The agent's repository is
/// never the one that talks to the network.
///
/// - **Out of it:** a fetch the mirror runs, so the agent's side is `upload-pack`, which runs no hook and takes no
///   program from repo-level config (`uploadpack.packObjectsHook` is honoured only from protected config).
/// - **Into it:** a fetch run in the agent's repository, never a push to it. git strips `GIT_CONFIG_COUNT` before
///   it starts `receive-pack` in another local repository, so a push would run that repository's own hooks
///   (measured: pre-receive, update and reference-transaction all ran). A fetch is one process, so the forced
///   settings below reach it, with `--upload-pack` named, auto gc and maintenance off, and the mirror as the far
///   side.
///
/// So the agent repository's config (`url.insteadOf`, `remote.*.uploadpack`, `core.fsmonitor`, filters, diff
/// drivers) and its hooks never reach a step that has the credential or the network, and nothing is checked out.
///
/// The mirror lives under `IrisPaths.vcsDir`, a protected directory, and holds only what Iris put there.
actor VCSMirror {
    static let shared = VCSMirror()

    struct Limits: Sendable {
        var maxFiles = 300
        var maxBytes = 5 * 1024 * 1024
    }

    private let root: URL
    private let remoteURL: @Sendable (String) -> String
    private let credentialConfig: [(key: String, value: String)]
    private let limits: Limits
    private let gitOverride: String?

    /// `remoteURL` and `credentialConfig` are injectable so a test's "GitHub" is a local bare repository with no
    /// credential; production is `https://github.com/<repo>.git` through Iris's own credential helper.
    init(root: URL = IrisPaths.default.vcsDir,
         remoteURL: @escaping @Sendable (String) -> String = { "https://github.com/\($0).git" },
         credentialConfig: [(key: String, value: String)]? = nil, limits: Limits = Limits(), git: String? = nil) {
        self.root = root
        self.remoteURL = remoteURL
        self.credentialConfig = credentialConfig ?? Self.helperConfig()
        self.limits = limits
        self.gitOverride = git
    }

    /// The credential for the mirror's own network steps: Iris's helper, which answers only for an allowed repo.
    static func helperConfig() -> [(key: String, value: String)] {
        guard let exe = Bundle.main.executablePath else { return [] }
        return [("credential.helper", ""), ("credential.helper", "!\(PluginAuthRunner.shellQuoted(exe)) --git-credential-helper"),
                ("credential.useHttpPath", "true")]
    }

    // MARK: running git

    struct Run: Sendable {
        var status: Int32
        var out: String
        var err: String
        var ok: Bool { status == 0 }
    }

    /// Every git the broker runs: no shell, no system or global config, no hooks, no prompts, no transport but
    /// the local one unless `network` (then https only), and `WorkspaceGit.overrides` at command scope, which beats
    /// any repository's own config.
    private func git(_ args: [String], network: Bool = false, stdin: Data? = nil, timeout: Double = 120) async -> Run {
        guard let exe = await executable() else { return Run(status: 127, out: "", err: "no git 2.40 or later was found") }
        var pairs = WorkspaceGit.overrides(hooks: "/dev/null").filter { $0.key != "protocol.file.allow" }
        pairs += [("protocol.allow", "never"), ("protocol.file.allow", "always"), ("safe.bareRepository", "explicit"),
                  ("core.fsmonitor", "false"), ("fetch.recurseSubmodules", "false"), ("submodule.recurse", "false"),
                  ("transfer.fsckObjects", "true"), ("gc.auto", "0"), ("maintenance.auto", "false"),
                  ("fetch.writeCommitGraph", "false")]
        for name in ["git", "http", "ssh", "ext"] { pairs.append(("protocol.\(name).allow", "never")) }
        pairs.append(("protocol.https.allow", network ? "always" : "never"))
        if network { pairs += credentialConfig }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false",
            "GIT_PAGER": "cat", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_CONFIG_COUNT": String(pairs.count),
        ]
        for (i, pair) in pairs.enumerated() {
            env["GIT_CONFIG_KEY_\(i)"] = pair.key
            env["GIT_CONFIG_VALUE_\(i)"] = pair.value
        }
        let result = await ProcessGroupRunner.capture(executable: exe, arguments: args, environment: env, stdin: stdin,
                                                      timeoutSeconds: timeout)
        switch result {
        case .failure(let error): return Run(status: 126, out: "", err: "\(error)")
        case .success(let output):
            return Run(status: output.timedOut ? 124 : output.status, out: String(decoding: output.stdout, as: UTF8.self),
                       err: String(decoding: output.stderr, as: UTF8.self))
        }
    }

    private var resolvedGit: String??

    private func executable() async -> String? {
        if let gitOverride { return gitOverride }
        if let resolvedGit { return resolvedGit }
        var found: String?
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            guard let candidate = GitRead.executable(on: [dir]) else { continue }
            if await GitRead.versionSupported(executable: candidate) { found = candidate; break }
        }
        resolvedGit = .some(found)
        return found
    }

    // MARK: the mirror and the workspace

    func mirrorPath(_ repo: String) -> String {
        root.appendingPathComponent(repo + ".git").path
    }

    private func ensureMirror(_ repo: String) async -> String? {
        let path = mirrorPath(repo)
        if FileManager.default.fileExists(atPath: path + "/HEAD") { return nil }
        let made = await git(["init", "--bare", "-q", path])
        return made.ok ? nil : "Refused: the vcs mirror for \(repo) couldn't be made (\(Self.firstLine(made.err)))."
    }

    /// The workspace as a repository the broker will touch: a work tree whose `.git` is a real directory or a
    /// gitfile (a linked worktree), never a symlink, and whose git directory is not under Iris's own home.
    static func workspaceRefusal(_ workspace: String?, irisRoot: URL = IrisPaths.default.root) -> String? {
        guard let workspace, !workspace.isEmpty else { return "Refused: vcs needs the conversation's workspace to be a git repository." }
        let dotGit = (workspace as NSString).appendingPathComponent(".git")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: dotGit) else {
            return "Refused: the workspace has no .git, so there is nothing for vcs to push or fetch into."
        }
        let type = attributes[.type] as? FileAttributeType
        if type == .typeSymbolicLink { return "Refused: the workspace's .git is a symbolic link, which vcs doesn't follow." }
        var gitDir = dotGit
        if type == .typeRegular {
            guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8), text.hasPrefix("gitdir: ") else {
                return "Refused: the workspace's .git file isn't a gitdir pointer."
            }
            let target = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = (target as NSString).isAbsolutePath ? target : (workspace as NSString).appendingPathComponent(target)
        } else if type != .typeDirectory {
            return "Refused: the workspace's .git is neither a directory nor a gitdir file."
        }
        let real = IrisPaths.realPath(gitDir).lowercased()
        let home = IrisPaths.realPath(irisRoot.path).lowercased()
        if real == home || real.hasPrefix(home + "/") { return "Refused: the workspace's git directory is inside Iris's own folder." }
        return nil
    }

    // MARK: fetch

    /// `main` (and `branch`, or pull request `pr`'s head, when given) from GitHub into the mirror, then into the
    /// workspace as `refs/remotes/origin/<name>` (`origin/pr/<n>` for a PR). Nothing is checked out or merged.
    func fetch(repo: String, branch: String?, pr: Int? = nil, workspace: String?) async -> String {
        if let refusal = Self.workspaceRefusal(workspace) { return refusal }
        if let branch, !VCSTool.isBranchName(branch) { return "Refused: \"\(VCSTool.shown(branch))\" is not a branch name vcs accepts." }
        if let pr, pr <= 0 { return "Refused: a pull request number must be positive." }
        if let failure = await ensureMirror(repo) { return failure }
        let mirror = mirrorPath(repo)
        // (GitHub's ref, the name it gets under refs/remotes/github and refs/remotes/origin)
        var refs = [("refs/heads/\(VCSTool.base)", VCSTool.base)]
        if let branch, branch != VCSTool.base { refs.append(("refs/heads/\(branch)", branch)) }
        if let pr { refs.append(("refs/pull/\(pr)/head", "pr/\(pr)")) }
        let names = refs.map(\.1)
        let specs = refs.map { "+\($0.0):refs/remotes/github/\($0.1)" }
        let fetched = await git(["--git-dir=\(mirror)", "fetch", "--no-tags", "--no-write-fetch-head", remoteURL(repo)] + specs, network: true)
        guard fetched.ok else { return "Refused: the fetch from GitHub failed (\(Self.firstLine(fetched.err)))." }
        let delivered = await git(["-C", workspace!, "fetch", "--upload-pack=git-upload-pack", "--no-tags", "--no-write-fetch-head",
                                   "--no-auto-gc", "--no-auto-maintenance", "--no-recurse-submodules", mirror]
                                  + names.map { "+refs/remotes/github/\($0):refs/remotes/origin/\($0)" })
        guard delivered.ok else { return "Refused: the fetched refs couldn't be written into the workspace (\(Self.firstLine(delivered.err)))." }
        var shown: [String] = []
        for name in names {
            let sha = await git(["--git-dir=\(mirror)", "rev-parse", "--verify", "refs/remotes/github/\(name)"]).out
            shown.append("origin/\(name) at \(sha.prefix(7))")
        }
        return "Fetched " + shown.joined(separator: ", ") + "."
    }

    // MARK: push

    /// The workspace's `refs/heads/<branch>` into the mirror, checked against the policy there, then to GitHub's
    /// branch of the same name. A force push is only ever with a lease on what GitHub had a moment before.
    func push(repo: String, branch: String, force: Bool, caller: VCSTool.Caller, workspace: String?,
              policy: VCSPolicyStore.Policy) async -> String {
        if let refusal = caller.headRefusal(branch) { return refusal }
        if let refusal = Self.workspaceRefusal(workspace) { return refusal }
        if let failure = await ensureMirror(repo) { return failure }
        let mirror = mirrorPath(repo)
        let staged = "refs/vcs/staged/\(branch)"
        // Out of the workspace by a fetch the mirror runs: the workspace is the upload side.
        let collected = await git(["--git-dir=\(mirror)", "fetch", "--no-tags", "--no-write-fetch-head", workspace!,
                                   "+refs/heads/\(branch):\(staged)"])
        guard collected.ok else { return "Refused: the workspace has no branch \(branch) vcs could read (\(Self.firstLine(collected.err)))." }
        let base = await git(["--git-dir=\(mirror)", "fetch", "--no-tags", "--no-write-fetch-head", remoteURL(repo),
                              "+refs/heads/\(VCSTool.base):refs/remotes/github/\(VCSTool.base)"], network: true)
        guard base.ok else { return "Refused: GitHub's \(VCSTool.base) couldn't be fetched to check against (\(Self.firstLine(base.err)))." }
        if let refusal = await policyRefusal(mirror: mirror, tip: staged, policy: policy) { return refusal }

        var args = ["--git-dir=\(mirror)", "push", "--no-verify", "--porcelain", remoteURL(repo)]
        if force {
            // The lease is on what GitHub's branch was just now, or that it doesn't exist.
            let remote = await git(["--git-dir=\(mirror)", "ls-remote", "--heads", remoteURL(repo), "refs/heads/\(branch)"], network: true)
            guard remote.ok else { return "Refused: GitHub's \(branch) couldn't be read for the force push's lease." }
            let expected = remote.out.split(separator: "\t").first.map(String.init) ?? ""
            args.append("--force-with-lease=refs/heads/\(branch):\(expected)")
        }
        args.append("\(staged):refs/heads/\(branch)")
        let pushed = await git(args, network: true)
        guard pushed.ok else {
            let reason = pushed.out.contains("rejected") || pushed.err.contains("rejected")
                ? "GitHub has commits on \(branch) this push doesn't contain; fetch and rebase, or push with force"
                : Self.firstLine(pushed.err)
            return "Refused: the push to GitHub failed (\(reason))."
        }
        let sha = await git(["--git-dir=\(mirror)", "rev-parse", "--verify", staged]).out
        return "Pushed \(branch) at \(sha.prefix(7)) to \(repo)."
    }

    /// The policy on what the branch adds over GitHub's main: no protected path in any of its commits, at most
    /// `maxFiles` files and `maxBytes` of new blobs in the net change, and no symlink that points outside the tree.
    private func policyRefusal(mirror: String, tip: String, policy: VCSPolicyStore.Policy) async -> String? {
        let mainRef = "refs/remotes/github/\(VCSTool.base)"
        let mergeBase = await git(["--git-dir=\(mirror)", "merge-base", mainRef, tip])
        guard mergeBase.ok, let base = mergeBase.out.split(separator: "\n").first.map(String.init) else {
            return "Refused: the branch shares no history with \(VCSTool.base)."
        }
        // Every path any commit touches, so a protected file added then removed is still seen. Without a merge option git
        // lists no files for a merge, so one whose resolution rewrote a workflow passed (dev-2's #1448 review);
        // `dense-combined` lists only what the merge changed against all its parents, so a catch-up merge of a main that
        // changed a workflow isn't refused for main's own change (dev-3's). The net change is checked below too.
        let touched = await git(["--git-dir=\(mirror)", "log", "--diff-merges=dense-combined", "--format=", "--name-only", "-z",
                                 "--no-renames", "\(base)..\(tip)"])
        guard touched.ok else { return "Refused: the branch's commits couldn't be listed." }
        let paths = Set(touched.out.split(separator: "\0").map(String.init).filter { !$0.isEmpty && $0 != "\n" }
            .map { $0.trimmingCharacters(in: .newlines) })
        if let hit = paths.sorted().first(where: policy.protects) {
            return "Refused: the branch touches \(VCSTool.shown(hit)), a protected path, so it needs a person to push it."
        }
        let raw = await git(["--git-dir=\(mirror)", "diff", "--raw", "-z", "--no-renames", "--no-ext-diff", "--no-textconv", base, tip])
        guard raw.ok else { return "Refused: the branch's change couldn't be read." }
        let entries = Self.rawEntries(raw.out)
        // Defence in depth: the log walk above already lists every path any commit or merge changed, so this net check
        // can't refuse anything it missed today; it stays so a future change to that walk can't open the hole alone.
        if let hit = entries.map(\.path).sorted().first(where: policy.protects) {
            return "Refused: the branch changes \(VCSTool.shown(hit)), a protected path, so it needs a person to push it."
        }
        guard entries.count <= limits.maxFiles else { return "Refused: the branch changes \(entries.count) files; vcs pushes at most \(limits.maxFiles)." }
        let added = entries.filter { $0.newSHA != String(repeating: "0", count: $0.newSHA.count) }
        if !added.isEmpty {
            let sizes = await git(["--git-dir=\(mirror)", "cat-file", "--batch-check=%(objectsize)"],
                                  stdin: Data(added.map(\.newSHA).joined(separator: "\n").appending("\n").utf8))
            let total = sizes.out.split(separator: "\n").compactMap { Int($0) }.reduce(0, +)
            guard sizes.ok, total <= limits.maxBytes else {
                return "Refused: the branch adds more than \(limits.maxBytes / 1024 / 1024) MB; vcs doesn't push that much at once."
            }
        }
        for link in added where link.newMode == "120000" {
            let target = await git(["--git-dir=\(mirror)", "cat-file", "blob", link.newSHA]).out
            if !Self.symlinkStaysInTree(path: link.path, target: target) {
                return "Refused: \(VCSTool.shown(link.path)) is a symbolic link pointing outside the repository."
            }
        }
        return nil
    }

    struct RawEntry: Equatable { let newMode: String; let newSHA: String; let path: String }

    /// `git diff --raw -z`: `:<old mode> <new mode> <old sha> <new sha> <status>\0<path>\0`, repeated.
    static func rawEntries(_ text: String) -> [RawEntry] {
        let fields = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var entries: [RawEntry] = []
        var i = 0
        while i + 1 < fields.count {
            let meta = fields[i].split(separator: " ")
            if fields[i].hasPrefix(":"), meta.count >= 5 {
                entries.append(RawEntry(newMode: String(meta[1]), newSHA: String(meta[3]), path: fields[i + 1]))
                i += 2
            } else {
                i += 1
            }
        }
        return entries
    }

    static func symlinkStaysInTree(path: String, target: String) -> Bool {
        guard !target.hasPrefix("/"), !target.hasPrefix("~") else { return false }
        var depth = path.split(separator: "/").count - 1
        for part in target.split(separator: "/") {
            if part == ".." { depth -= 1 } else if part != "." { depth += 1 }
            if depth < 0 { return false }
        }
        return true
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? "no detail"
        return VCSTool.shown(SecretScrub.scrub(line, []))
    }
}
