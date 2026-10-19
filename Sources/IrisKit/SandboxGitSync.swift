import Foundation

/// What git in the VM reports about its copy (#658). Data from the VM: used only to notice that
/// something changed and to name what to bundle, never as a fact the host acts on. Every SHA a
/// decision uses is read back by host git after the fetch.
struct SandboxVMState: Equatable, Sendable {
    /// The branch checked out in the VM, or nil when its HEAD is detached.
    var headBranch: String?
    var headSha: String?
    var branches: [String: String]
}

/// The git commands run in the VM, against its own copy.
protocol SandboxVMGit: Sendable {
    func state() async -> SandboxVMState?
    /// Writes `SandboxGit.bundleName` into the copy, holding `refs` (branch names) and what they
    /// reach, less what `excluding` (SHAs) reaches.
    func writeBundle(branches: [String], excluding: [String]) async -> Bool
    /// Moves the VM's `branch` from `old` to `new` and its index to match, when that branch is
    /// checked out and the index has nothing staged. No checkout: the worktree is the host's.
    func fastForward(branch: String, from old: String, to new: String) async -> Bool
}

/// The sync decision for the branch the host workspace has checked out (pure, for tests).
struct SandboxSyncFacts: Equatable, Sendable {
    var branch: String
    /// The VM's commit, as host git read it from `refs/iris/sandbox/<branch>` after the fetch.
    var vmSha: String
    /// The branch the host workspace has checked out, nil when detached.
    var hostHeadBranch: String?
    var hostSha: String?
    /// Another host worktree (or the main checkout) with `branch` checked out.
    var checkedOutElsewhere: String?
    var hostIsAncestor: Bool
    /// The host worktree's tracked files are the VM commit's tree.
    var worktreeMatches: Bool
    /// The host index has nothing staged against its HEAD.
    var indexClean: Bool
}

enum SandboxSyncDecision: Equatable, Sendable {
    case unchanged
    case fastForward
    case keep(reason: String)

    static func decide(_ f: SandboxSyncFacts) -> SandboxSyncDecision {
        if f.hostSha == f.vmSha { return .unchanged }
        if let other = f.checkedOutElsewhere { return .keep(reason: "it is checked out in \(other)") }
        guard let head = f.hostHeadBranch else { return .keep(reason: "your Mac's HEAD is detached") }
        guard head == f.branch else { return .keep(reason: "your Mac has \(head) checked out, not \(f.branch)") }
        guard f.hostSha != nil else { return .keep(reason: "\(f.branch) does not exist on your Mac") }
        guard f.hostIsAncestor else { return .keep(reason: "it has diverged from the sandbox's") }
        guard f.indexClean else { return .keep(reason: "your index has staged changes") }
        guard f.worktreeMatches else { return .keep(reason: "your files differ from the sandbox's commit") }
        return .fastForward
    }
}

/// Runs host git against the person's own repository, where the VM can no longer write the
/// config. With no hooks, no fsmonitor, no prompt, and none of Iris's `GIT_*` environment.
struct SandboxHostGit: Sendable {
    var environment: [String: String] = {
        var env = BinaryResolver.commandEnvironment(base: ProcessInfo.processInfo.environment)
        for key in env.keys where key.hasPrefix("GIT_") { env[key] = nil }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        return env
    }()

    func run(_ args: [String], in dir: String, extra: [String: String] = [:]) async -> (status: Int32, out: String) {
        var env = environment
        env.merge(extra) { $1 }
        let full = ["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + args
        guard case .success(let out) = await ProcessGroupRunner.capture(executable: "/usr/bin/env", arguments: full,
                                                                         environment: env, currentDirectory: dir,
                                                                         timeoutSeconds: 120) else { return (-1, "") }
        return (out.status, String(data: out.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

/// One repository's sync, around one in-VM command (#658, Brian's "ii+note"). Before: if the
/// host moved ahead on the branch both have checked out, the VM's branch and index follow. After:
/// each VM branch that moved is fetched from a bundle into `refs/iris/sandbox/<branch>`, and the
/// host branch this workspace has checked out is moved to it when that is a pure fast-forward the
/// worktree already matches: a ref and index move, no checkout, no hooks, said in the chat.
struct SandboxGitSync: Sendable {
    let repo: SandboxGit.Repo
    let vm: any SandboxVMGit
    var host = SandboxHostGit()

    struct Before: Sendable {
        var state: SandboxVMState?
        var worktree: [String: Data?]
    }

    func before() async -> (Before, [String]) {
        let worktree = SandboxGit.worktreeSnapshot(source: repo.source)
        var notes: [String] = []
        var state = await vm.state()
        if let vmState = state, let branch = vmState.headBranch, let vmSha = vmState.headSha,
           await hostHeadBranch() == branch, let hostSha = await hostSha(of: branch), hostSha != vmSha,
           await host.run(["merge-base", "--is-ancestor", vmSha, hostSha], in: repo.source).status == 0 {
            if await vm.fastForward(branch: branch, from: vmSha, to: hostSha) {
                notes.append("Moved the sandbox's \(branch) \(short(vmSha))..\(short(hostSha)) to match your Mac.")
                state = await vm.state()
            }
        }
        return (Before(state: state, worktree: worktree), notes)
    }

    func after(_ before: Before) async -> [String] {
        var notes: [String] = []
        if let now = await vm.state(), let was = before.state {
            notes += await sync(now: now, was: was)
        }
        notes += SandboxGit.worktreeNotes(source: repo.source, before: before.worktree)
        notes += SandboxGit.quarantinePointers(source: repo.source, commonDir: repo.hostCommonDir)
        return notes
    }

    private func sync(now: SandboxVMState, was: SandboxVMState) async -> [String] {
        let changed = now.branches.keys.sorted().filter { now.branches[$0] != was.branches[$0] && Self.isPlainBranch($0) }
        let detachedMoved = now.headBranch == nil && now.headSha != was.headSha && now.headSha.map(Self.isSha) == true
        guard !changed.isEmpty || detachedMoved else { return [] }

        // What the host already has needs no bundle; what it lacks comes in one.
        var missing: [String] = []
        var known: [(String, String)] = []
        for branch in changed {
            guard let sha = now.branches[branch], Self.isSha(sha) else { continue }
            if await host.run(["cat-file", "-e", sha + "^{commit}"], in: repo.source).status == 0 { known.append((branch, sha)) }
            else { missing.append(branch) }
        }
        var notes: [String] = []
        var fetched: Set<String> = []
        if !missing.isEmpty {
            var excluding: [String] = []
            if let head = await host.run(["rev-parse", "-q", "--verify", "HEAD"], in: repo.source).out.nilIfEmpty { excluding.append(head) }
            for branch in missing { if let sha = await hostSha(of: branch) { excluding.append(sha) } }
            if await vm.writeBundle(branches: missing, excluding: excluding), let copy = Self.takeBundle(vmDir: repo.vmDir) {
                defer { try? FileManager.default.removeItem(atPath: copy) }
                let specs = missing.map { "+refs/heads/\($0):refs/iris/sandbox/\($0)" }
                let fetch = await host.run(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", copy] + specs, in: repo.source)
                if fetch.status == 0 { fetched.formUnion(missing) }
                else { notes.append("Iris could not bring the sandbox's commits on \(missing.joined(separator: ", ")) to your Mac; they stay in the sandbox's copy.") }
            } else {
                notes.append("Iris could not bring the sandbox's commits on \(missing.joined(separator: ", ")) to your Mac; they stay in the sandbox's copy.")
            }
        }
        for (branch, sha) in known
        where await host.run(["update-ref", "refs/iris/sandbox/\(branch)", sha], in: repo.source).status == 0 {
            fetched.insert(branch)
        }

        let headBranch = await hostHeadBranch()
        for branch in changed where fetched.contains(branch) {
            guard let vmSha = await host.run(["rev-parse", "-q", "--verify", "refs/iris/sandbox/\(branch)"], in: repo.source).out.nilIfEmpty
            else { continue }
            let facts = await facts(branch: branch, vmSha: vmSha, headBranch: headBranch)
            switch SandboxSyncDecision.decide(facts) {
            case .unchanged:
                break
            case .fastForward:
                notes.append(await fastForward(branch: branch, from: facts.hostSha ?? "", to: vmSha))
            case .keep(let reason):
                notes.append(facts.hostSha == nil && facts.checkedOutElsewhere == nil
                    ? "The sandbox made branch \(branch); it is at refs/iris/sandbox/\(branch) (\(short(vmSha)))."
                    : "The sandbox's \(branch) is at refs/iris/sandbox/\(branch) (\(short(vmSha))); \(branch) on your Mac was not moved because \(reason).")
            }
        }
        if detachedMoved {
            notes.append("The sandbox's HEAD is detached; commits made there were not brought to your Mac. Check out a branch in the sandbox to keep them.")
        }
        return notes
    }

    private func facts(branch: String, vmSha: String, headBranch: String?) async -> SandboxSyncFacts {
        let hostSha = await hostSha(of: branch)
        var facts = SandboxSyncFacts(branch: branch, vmSha: vmSha, hostHeadBranch: headBranch, hostSha: hostSha,
                                     checkedOutElsewhere: await checkedOutElsewhere(branch),
                                     hostIsAncestor: false, worktreeMatches: false, indexClean: false)
        guard headBranch == branch, let hostSha, facts.checkedOutElsewhere == nil else { return facts }
        facts.hostIsAncestor = await host.run(["merge-base", "--is-ancestor", hostSha, vmSha], in: repo.source).status == 0
        facts.indexClean = await host.run(["diff", "--cached", "--quiet", "HEAD", "--"], in: repo.source).status == 0
        facts.worktreeMatches = await worktreeMatches(vmSha)
        return facts
    }

    /// Whether the worktree's files are `sha`'s tree, compared through a scratch index so the
    /// person's own index is untouched: files the commit adds count too.
    private func worktreeMatches(_ sha: String) async -> Bool {
        let scratch = (NSTemporaryDirectory() as NSString).appendingPathComponent("iris-sync-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let env = ["GIT_INDEX_FILE": scratch]
        guard await host.run(["read-tree", sha], in: repo.source, extra: env).status == 0 else { return false }
        _ = await host.run(["update-index", "-q", "--refresh"], in: repo.source, extra: env)
        return await host.run(["diff-files", "--quiet"], in: repo.source, extra: env).status == 0
    }

    /// The ref moves only if it is still where it was checked (`update-ref`'s old value), then the
    /// index is rebuilt from the new commit. The worktree already holds it, so nothing is
    /// checked out and no file is written.
    private func fastForward(branch: String, from old: String, to new: String) async -> String {
        let count = await host.run(["rev-list", "--count", "\(old)..\(new)"], in: repo.source).out
        guard await host.run(["update-ref", "-m", "iris: from the sandbox", "refs/heads/\(branch)", new, old], in: repo.source).status == 0,
              await host.run(["read-tree", new], in: repo.source).status == 0 else {
            return "The sandbox's \(branch) is at refs/iris/sandbox/\(branch) (\(short(new))); Iris could not move \(branch) on your Mac."
        }
        _ = await host.run(["update-index", "-q", "--refresh"], in: repo.source)
        let n = Int(count) ?? 0
        return "Moved \(branch) \(short(old))..\(short(new)) (\(n) commit\(n == 1 ? "" : "s") from the sandbox)."
    }

    /// Copies the bundle the VM wrote out of the copy (a folder the VM can write) to a private
    /// file, refusing anything but a regular file: host git is never pointed at a path the VM
    /// could have made a repository or a link.
    static func takeBundle(vmDir: String) -> String? {
        let path = (vmDir as NSString).appendingPathComponent(SandboxGit.bundleName)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let copy = (NSTemporaryDirectory() as NSString).appendingPathComponent("iris-sync-\(UUID().uuidString).bundle")
        guard FileManager.default.createFile(atPath: copy, contents: nil, attributes: [.posixPermissions: 0o600]),
              let out = FileHandle(forWritingAtPath: copy) else { return nil }
        defer { try? out.close() }
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { out.write(chunk) }
        return copy
    }

    private func hostHeadBranch() async -> String? {
        let ref = await host.run(["symbolic-ref", "-q", "HEAD"], in: repo.source)
        guard ref.status == 0, ref.out.hasPrefix("refs/heads/") else { return nil }
        return String(ref.out.dropFirst("refs/heads/".count))
    }

    private func hostSha(of branch: String) async -> String? {
        await host.run(["rev-parse", "-q", "--verify", "refs/heads/\(branch)"], in: repo.source).out.nilIfEmpty
    }

    /// The other worktree (or main checkout) of this repository with `branch` checked out.
    private func checkedOutElsewhere(_ branch: String) async -> String? {
        let list = await host.run(["worktree", "list", "--porcelain"], in: repo.source)
        guard list.status == 0 else { return nil }
        let here = IrisPaths.realPath(repo.source)
        var path: String?
        for line in list.out.split(separator: "\n").map(String.init) {
            if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
            if line == "branch refs/heads/\(branch)", let p = path, IrisPaths.realPath(p) != here { return p }
        }
        return nil
    }

    private func short(_ sha: String) -> String { String(sha.prefix(7)) }

    /// A branch name Iris will put in a refspec: the characters git branch names normally use,
    /// nothing that reads as an option or a refspec, nothing git itself refuses.
    static func isPlainBranch(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
        return !name.isEmpty && name.count <= 200 && name.unicodeScalars.allSatisfy(allowed.contains)
            && !name.hasPrefix("-") && !name.hasPrefix("/") && !name.hasSuffix("/") && !name.hasSuffix(".")
            && !name.hasSuffix(".lock") && !name.contains("..") && !name.contains("//") && !name.contains("/.")
            && !name.hasPrefix(".")
    }

    static func isSha(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// `SandboxVMGit` over a container's `exec`.
struct ContainerVMGit: SandboxVMGit {
    let repo: SandboxGit.Repo
    /// Runs a bash command in the container, answering its stdout and exit status.
    let exec: @Sendable (String) async -> (out: String, status: Int32)?

    private var dir: String { quoted(repo.target) }

    func state() async -> SandboxVMState? {
        let script = "cd \(dir) 2>/dev/null || exit 3; git symbolic-ref -q HEAD; echo @@; git rev-parse -q --verify HEAD; echo @@; git for-each-ref --format='%(refname:strip=2) %(objectname)' refs/heads"
        guard let r = await exec(script), r.status == 0 || r.status == 1 else { return nil }
        let parts = r.out.components(separatedBy: "@@\n")
        guard parts.count == 3 else { return nil }
        let head = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        var branches: [String: String] = [:]
        for line in parts[2].split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1).map(String.init)
            if fields.count == 2 { branches[fields[0]] = fields[1] }
        }
        return SandboxVMState(headBranch: head.hasPrefix("refs/heads/") ? String(head.dropFirst("refs/heads/".count)) : nil,
                              headSha: parts[1].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                              branches: branches)
    }

    func writeBundle(branches: [String], excluding: [String]) async -> Bool {
        guard branches.allSatisfy(SandboxGitSync.isPlainBranch), excluding.allSatisfy(SandboxGitSync.isSha) else { return false }
        let bundle = quoted((repo.vmCommonDir as NSString).appendingPathComponent(SandboxGit.bundleName))
        let refs = branches.map { "refs/heads/\($0)" }.joined(separator: " ")
        let not = excluding.isEmpty ? "" : " --not " + excluding.joined(separator: " ")
        return await exec("cd \(dir) && git bundle create -q \(bundle) \(refs)\(not)")?.status == 0
    }

    func fastForward(branch: String, from old: String, to new: String) async -> Bool {
        guard SandboxGitSync.isPlainBranch(branch), SandboxGitSync.isSha(old), SandboxGitSync.isSha(new) else { return false }
        let script = "cd \(dir) && [ \"$(git symbolic-ref -q HEAD)\" = refs/heads/\(branch) ] && git diff --cached --quiet HEAD -- && git update-ref refs/heads/\(branch) \(new) \(old) && git read-tree \(new) && { git update-index -q --refresh; true; }"
        return await exec(script)?.status == 0
    }

    private func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
