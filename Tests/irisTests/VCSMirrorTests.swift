import Testing
import Foundation
@testable import IrisKit

/// #1435 slice 2: `vcs fetch` and `vcs push` through the broker-owned mirror, against a local bare repository
/// standing in for GitHub. The pinned rows are the issue's: a planted filter driver, hooks, `core.fsmonitor`, a
/// symlinked `.git`, a hostile ref name, a push outside the prefix, a protected path, a force push.
@Suite("vcs mirror (#1435 slice 2)", .timeLimit(.minutes(1)))
struct VCSMirrorTests {
    /// A scratch world: "GitHub" (bare, with a main), the agent's workspace (a clone of it), and the mirror's root.
    struct World {
        let root: URL
        var github: String { root.appendingPathComponent("github.git").path }
        var workspace: String { root.appendingPathComponent("ws").path }
        var mirrorRoot: URL { root.appendingPathComponent("iris/vcs") }
        var marker: String { root.appendingPathComponent("PWNED").path }
        var pwned: Bool { FileManager.default.fileExists(atPath: marker) }
    }

    static let git = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }!

    /// The fixture's own git: a person's, with an identity and no global config.
    @discardableResult
    static func sh(_ args: [String], in dir: String? = nil) async throws -> String {
        let env = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                   "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
        let result = await ProcessGroupRunner.capture(executable: git, arguments: (dir.map { ["-C", $0] } ?? []) + args,
                                                      environment: env, timeoutSeconds: 30)
        guard case .success(let output) = result, output.status == 0 else {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(args): \(result)"])
        }
        return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func world() async throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-vcsm-\(UUID().uuidString)")
        let w = World(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await Self.sh(["init", "-q", "--bare", "-b", "main", w.github])
        try await Self.sh(["init", "-q", "-b", "main", w.workspace])
        try "hello\n".write(toFile: w.workspace + "/README.md", atomically: true, encoding: .utf8)
        try await Self.sh(["add", "."], in: w.workspace)
        try await Self.sh(["commit", "-q", "-m", "first"], in: w.workspace)
        try await Self.sh(["push", "-q", w.github, "main:main"], in: w.workspace)
        return w
    }

    func mirror(_ w: World, limits: VCSMirror.Limits = .init()) -> VCSMirror {
        let github = w.github
        return VCSMirror(root: w.mirrorRoot, remoteURL: { _ in github }, credentialConfig: [], limits: limits, git: Self.git)
    }

    func commit(_ w: World, branch: String, files: [String: String], message: String = "change") async throws {
        _ = try? await Self.sh(["checkout", "-q", "-b", branch], in: w.workspace)
        for (path, text) in files {
            let full = w.workspace + "/" + path
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: full, atomically: true, encoding: .utf8)
        }
        try await Self.sh(["add", "-A"], in: w.workspace)
        try await Self.sh(["commit", "-q", "-m", message], in: w.workspace)
    }

    func githubHas(_ w: World, _ branch: String) async -> Bool {
        (try? await Self.sh(["--git-dir=\(w.github)", "rev-parse", "--verify", "-q", "refs/heads/\(branch)"])) != nil
    }

    let role = VCSTool.Caller.role("pilot")

    // MARK: the happy paths

    @Test("fetch writes GitHub's main into the workspace as origin/main and checks nothing out")
    func fetchDelivers() async throws {
        let w = try await world()
        try await Self.sh(["--git-dir=\(w.github)", "update-ref", "refs/heads/main",
                           try await Self.sh(["--git-dir=\(w.github)", "commit-tree", "-p", "main", "-m", "upstream",
                                              try await Self.sh(["--git-dir=\(w.github)", "rev-parse", "main^{tree}"])])])
        let head = try await Self.sh(["rev-parse", "HEAD"], in: w.workspace)
        let result = await mirror(w).fetch(repo: "a/b", branch: nil, workspace: w.workspace)
        #expect(result.hasPrefix("Fetched origin/main at"), Comment(rawValue: result))
        let delivered = try await Self.sh(["rev-parse", "refs/remotes/origin/main"], in: w.workspace)
        #expect(delivered == (try await Self.sh(["--git-dir=\(w.github)", "rev-parse", "main"])))
        #expect((try await Self.sh(["rev-parse", "HEAD"], in: w.workspace)) == head, "nothing checked out")
    }

    @Test("push publishes a role's branch under its prefix")
    func pushPublishes() async throws {
        let w = try await world()
        try await commit(w, branch: "agent/pilot/fix", files: ["Sources/a.swift": "let a = 1\n"])
        let result = await mirror(w).push(repo: "a/b", branch: "agent/pilot/fix", force: false, caller: role, workspace: w.workspace, policy: .defaults)
        #expect(result.hasPrefix("Pushed agent/pilot/fix"), Comment(rawValue: result))
        #expect(await githubHas(w, "agent/pilot/fix"))
    }

    // MARK: the issue's pinned rows

    @Test("a push outside the role's prefix, a hostile ref name, or main is refused, and nothing reaches GitHub",
          arguments: ["agent/other/x", "feature", "main", "-x", "a..b", "agent/pilot/../x"])
    func branchRefusals(_ branch: String) async throws {
        let w = try await world()
        // The branch exists in the workspace, so only the name rule can refuse it.
        if VCSTool.isBranchName(branch), branch != "main" { try await Self.sh(["branch", branch], in: w.workspace) }
        let result = await mirror(w).push(repo: "a/b", branch: branch, force: false, caller: role, workspace: w.workspace, policy: .defaults)
        #expect(result.hasPrefix("Refused"), Comment(rawValue: result))
        if branch != "main" { #expect(!(await githubHas(w, branch))) }
    }

    @Test("a protected path in any commit refuses the push, even when a later commit removes it")
    func protectedPathInHistory() async throws {
        let w = try await world()
        try await commit(w, branch: "agent/pilot/sneak", files: [".github/workflows/x.yml": "on: push\n"], message: "add")
        try FileManager.default.removeItem(atPath: w.workspace + "/.github/workflows/x.yml")
        try await commit(w, branch: "agent/pilot/sneak", files: ["Sources/b.swift": "let b = 2\n"], message: "remove")
        let result = await mirror(w).push(repo: "a/b", branch: "agent/pilot/sneak", force: false, caller: role, workspace: w.workspace, policy: .defaults)
        #expect(result.contains("protected path"), Comment(rawValue: result))
        #expect(!(await githubHas(w, "agent/pilot/sneak")))
    }

    @Test("a merge whose resolution changes a protected path is refused (dev-2's #1448 review)")
    func evilMerge() async throws {
        let w = try await world()
        try await commit(w, branch: "agent/pilot/side", files: ["a.txt": "a\n"], message: "side")
        try await Self.sh(["checkout", "-q", "main"], in: w.workspace)
        try await commit(w, branch: "agent/pilot/merge", files: ["b.txt": "b\n"], message: "other")
        // Merge without committing, slip a workflow into the resolution, then commit the merge.
        try await Self.sh(["merge", "--no-ff", "--no-commit", "agent/pilot/side"], in: w.workspace)
        try FileManager.default.createDirectory(atPath: w.workspace + "/.github/workflows", withIntermediateDirectories: true)
        try "on: push\n".write(toFile: w.workspace + "/.github/workflows/ci.yml", atomically: true, encoding: .utf8)
        try await Self.sh(["add", "-A"], in: w.workspace)
        try await Self.sh(["commit", "-q", "-m", "merge"], in: w.workspace)
        let plainLog = try await Self.sh(["log", "--format=", "--name-only", "main..HEAD"], in: w.workspace)
        #expect(!plainLog.contains("ci.yml"), "the row reproduces the case: plain log doesn't list the merge's file")
        let result = await mirror(w).push(repo: "a/b", branch: "agent/pilot/merge", force: false, caller: role, workspace: w.workspace, policy: .defaults)
        #expect(result.contains("protected path"), Comment(rawValue: result))
        #expect(!(await githubHas(w, "agent/pilot/merge")))
    }

    /// Plants everything the agent's repository could use to run a program in the broker's git: hooks of every
    /// side, a filter and a diff driver with an attributes file, `core.fsmonitor`, `uploadpack.packObjectsHook`,
    /// a `remote.<mirror>` with its own upload-pack, and an `insteadOf` rewriting the mirror and GitHub.
    func plant(_ w: World) async throws {
        let touch = "touch \(w.marker)"
        let hooks = w.workspace + "/.git/hooks"
        for hook in ["pre-push", "pre-receive", "update", "post-receive", "post-update", "reference-transaction", "push-to-checkout", "post-checkout"] {
            let path = hooks + "/" + hook
            try "#!/bin/sh\n\(touch)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        for (key, value) in [("filter.evil.clean", touch), ("filter.evil.smudge", touch), ("diff.evil.command", touch),
                             ("core.fsmonitor", touch), ("uploadpack.packObjectsHook", touch),
                             ("remote.\(w.mirrorRoot.path)/a/b.git.uploadpack", touch),
                             ("remote.\(w.mirrorRoot.path)/a/b.git.url", w.mirrorRoot.path + "/a/b.git"),
                             ("url.ext::sh -c touch% \(w.marker).insteadOf", w.github),
                             ("receive.procReceiveRefs", "refs/heads")] {
            try await Self.sh(["config", key, value], in: w.workspace)
        }
        try "* filter=evil diff=evil\n".write(toFile: w.workspace + "/.gitattributes", atomically: true, encoding: .utf8)
    }

    @Test("a planted filter driver, hooks, core.fsmonitor and repo-level program settings run nothing in fetch or push")
    func plantedProgramsNeverRun() async throws {
        let w = try await world()
        try await commit(w, branch: "agent/pilot/ok", files: ["Sources/c.swift": "let c = 3\n"])
        try await plant(w)
        let m = mirror(w)
        let pushed = await m.push(repo: "a/b", branch: "agent/pilot/ok", force: false, caller: role, workspace: w.workspace, policy: .defaults)
        let fetched = await m.fetch(repo: "a/b", branch: "agent/pilot/ok", workspace: w.workspace)
        #expect(pushed.hasPrefix("Pushed"), Comment(rawValue: pushed))
        #expect(fetched.hasPrefix("Fetched"), Comment(rawValue: fetched))
        #expect(!w.pwned, "a planted program ran")
        #expect(await githubHas(w, "agent/pilot/ok"), "insteadOf in the workspace didn't redirect the push")
    }

    @Test("each planted program alone, a hook, a filter, a diff driver or a repo-level setting, runs nothing in push or fetch", arguments: Array(0..<11))
    func eachPlantedProgramAlone(_ which: Int) async throws {
        let w = try await world()
        try await commit(w, branch: "agent/pilot/ok", files: ["Sources/c.swift": "let c = 3\n"])
        let touch = "touch \(w.marker)"
        let hooks = w.workspace + "/.git/hooks"
        let settings: [(String, String)] = [("filter.evil.clean", touch), ("filter.evil.smudge", touch), ("diff.evil.command", touch),
                             ("core.fsmonitor", touch), ("uploadpack.packObjectsHook", touch),
                             ("remote.\(w.mirrorRoot.path)/a/b.git.uploadpack", touch),
                             ("remote.\(w.mirrorRoot.path)/a/b.git.url", w.mirrorRoot.path + "/a/b.git"),
                             ("url.ext::sh -c touch% \(w.marker).insteadOf", w.github),
                             ("receive.procReceiveRefs", "refs/heads")]
        if which < 9 {
            try await Self.sh(["config", settings[which].0, settings[which].1], in: w.workspace)
            // Measured: git never looks up an absolute path as a configured remote's name, so this row passes even
            // without `--upload-pack`; the flag stays as a second layer.
            if which == 5 { try await Self.sh(["config", settings[6].0, settings[6].1], in: w.workspace) }
        }
        if which == 9 {
            for hook in ["pre-push", "pre-receive", "update", "post-receive", "post-update", "reference-transaction", "push-to-checkout", "post-checkout"] {
                let path = hooks + "/" + hook
                try "#!/bin/sh\necho \(hook) >> \(w.marker)\n".write(toFile: path, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            }
        }
        if which == 10 { try "* filter=evil diff=evil\n".write(toFile: w.workspace + "/.gitattributes", atomically: true, encoding: .utf8) }
        #expect(!w.pwned, "before")
        let m = mirror(w)
        let pushed = await m.push(repo: "a/b", branch: "agent/pilot/ok", force: false, caller: role, workspace: w.workspace, policy: .defaults)
        let afterPush = w.pwned
        let fetched = await m.fetch(repo: "a/b", branch: "agent/pilot/ok", workspace: w.workspace)
        let marker = (try? String(contentsOfFile: w.marker, encoding: .utf8)) ?? ""
        #expect(!w.pwned, "\(which) afterPush=\(afterPush) marker=\(marker) \(pushed.prefix(40)) \(fetched.prefix(40))")
    }

    @Test("a symlinked .git, or a gitfile into Iris's own folder, is refused before any git runs")
    func dotGitRefusals() async throws {
        let w = try await world()
        let other = w.root.appendingPathComponent("other").path
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: other + "/.git", withDestinationPath: w.workspace + "/.git")
        let linked = await mirror(w).fetch(repo: "a/b", branch: nil, workspace: other)
        #expect(linked.contains("symbolic link"), Comment(rawValue: linked))
        #expect(!FileManager.default.fileExists(atPath: w.mirrorRoot.path), "nothing ran, not even the mirror's init")

        let pointed = w.root.appendingPathComponent("pointed").path
        try FileManager.default.createDirectory(atPath: pointed, withIntermediateDirectories: true)
        let irisRoot = w.root.appendingPathComponent("iris")
        try FileManager.default.createDirectory(at: irisRoot.appendingPathComponent("vcs/a/b.git"), withIntermediateDirectories: true)
        try "gitdir: \(irisRoot.path)/vcs/a/b.git\n".write(toFile: pointed + "/.git", atomically: true, encoding: .utf8)
        #expect(VCSMirror.workspaceRefusal(pointed, irisRoot: irisRoot)?.contains("Iris's own folder") == true)
        #expect(VCSMirror.workspaceRefusal(w.workspace, irisRoot: irisRoot) == nil)
        #expect(VCSMirror.workspaceRefusal(nil) != nil)
    }

    @Test("a branch GitHub has moved is refused without force; with force it replaces it, under a lease")
    func forcePush() async throws {
        let w = try await world()
        try await commit(w, branch: "agent/pilot/f", files: ["a.txt": "1\n"])
        let m = mirror(w)
        #expect((await m.push(repo: "a/b", branch: "agent/pilot/f", force: false, caller: role, workspace: w.workspace, policy: .defaults)).hasPrefix("Pushed"))
        try await Self.sh(["commit", "-q", "--amend", "-m", "rewritten"], in: w.workspace)
        let plain = await m.push(repo: "a/b", branch: "agent/pilot/f", force: false, caller: role, workspace: w.workspace, policy: .defaults)
        #expect(plain.hasPrefix("Refused") && plain.contains("doesn't contain"), Comment(rawValue: plain))
        let forced = await m.push(repo: "a/b", branch: "agent/pilot/f", force: true, caller: role, workspace: w.workspace, policy: .defaults)
        #expect(forced.hasPrefix("Pushed"), Comment(rawValue: forced))
        #expect((try await Self.sh(["--git-dir=\(w.github)", "rev-parse", "agent/pilot/f"])) == (try await Self.sh(["rev-parse", "HEAD"], in: w.workspace)))
    }

    @Test("past the file limit the push is refused")
    func fileLimit() async throws {
        let w = try await world()
        try await commit(w, branch: "agent/pilot/many", files: ["a": "1", "b": "2", "c": "3"])
        let result = await mirror(w, limits: .init(maxFiles: 2)).push(repo: "a/b", branch: "agent/pilot/many", force: false, caller: role,
                                                                      workspace: w.workspace, policy: .defaults)
        #expect(result.contains("at most 2"), Comment(rawValue: result))
        #expect(!(await githubHas(w, "agent/pilot/many")))
    }

    @Test("a symlink out of the tree is refused; one inside it is fine")
    func symlinks() async throws {
        #expect(VCSMirror.symlinkStaysInTree(path: "a/b/link", target: "../c"))
        #expect(VCSMirror.symlinkStaysInTree(path: "link", target: "docs/x.md"))
        for target in ["/etc/passwd", "~/.ssh/id_rsa", "../outside", "a/../../x"] {
            #expect(!VCSMirror.symlinkStaysInTree(path: "link", target: target), Comment(rawValue: target))
        }
        let w = try await world()
        _ = try? await Self.sh(["checkout", "-q", "-b", "agent/pilot/ln"], in: w.workspace)
        try FileManager.default.createSymbolicLink(atPath: w.workspace + "/escape", withDestinationPath: "/etc/passwd")
        try await Self.sh(["add", "-A"], in: w.workspace)
        try await Self.sh(["commit", "-q", "-m", "link"], in: w.workspace)
        let result = await mirror(w).push(repo: "a/b", branch: "agent/pilot/ln", force: false, caller: role, workspace: w.workspace, policy: .defaults)
        #expect(result.contains("symbolic link pointing outside"), Comment(rawValue: result))
    }

    @Test("a repository off the allowlist is refused before the mirror runs any git")
    func allowlistFirst() async throws {
        let w = try await world()
        let client = GitHubProxyClient(keychain: KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)"), isRepoAllowed: { _ in false })
        for action in ["fetch", "push"] {
            let result = await VCSTool.$caller.withValue(role) {
                await VCSTool.execute(args: ["action": .string(action), "repo": .string("a/b"), "branch": .string("agent/pilot/x")],
                                      client: client, workspace: w.workspace, mirror: mirror(w))
            }
            #expect(result.contains("not allowed"), Comment(rawValue: result))
        }
        #expect(!FileManager.default.fileExists(atPath: w.mirrorRoot.path))
    }
}

/// #1435 (planner): a real turn's `vcs fetch` taints the conversation exactly when it brought someone else's code.
@MainActor
@Suite("vcs fetch taint through a turn (#1435 slice 2)", .timeLimit(.minutes(1)))
struct VCSFetchTaintTests {
    private func turn(fetching args: [String: JSONValue], role: String?) async throws -> Bool {
        let fixtures = VCSMirrorTests()
        let w = try await fixtures.world()
        try await VCSMirrorTests.sh(["push", "-q", w.github, "main:refs/heads/agent/author/x", "main:refs/heads/feature"], in: w.workspace)
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let idx = try #require(app.conversations.firstIndex { $0.id == id })
        app.conversations[idx].role = role
        app.conversations[idx].workspacePath = w.workspace
        let call = FunctionCall(name: VCSTool.name, args: args.merging(["action": .string("fetch"), "repo": .string("a/b")]) { a, _ in a })
        let part = Part(text: nil, functionCall: call, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        let client = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil),
        ])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0, githubToolsEnabled: true)
        let scoped = VCSTool.Scoped(client: GitHubProxyClient(keychain: KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)"),
                                                              isRepoAllowed: { $0 == "a/b" }),
                                    mirror: fixtures.mirror(w))
        try await VCSTool.$scoped.withValue(scoped) {
            let task = Task { await engine.processInput("go", source: "UI", conversationId: id) }
            try await value(of: task)
        }
        let results = app.conversations[idx].history.flatMap { $0.parts }.compactMap { $0.functionResponse?.response["result"]?.stringValue }
        #expect(results.contains { $0.contains("Fetched origin/main") }, "\(results)")
        return app.conversations[idx].hasUntrustedToolOutput
    }

    @Test("a role fetching main, or its own branch, stays untainted")
    func ownFetchClean() async throws {
        #expect(!(try await turn(fetching: [:], role: "pilot")))
    }

    @Test("a reviewer role fetching the author's branch is tainted")
    func reviewerFetchTaints() async throws {
        #expect(try await turn(fetching: ["branch": .string("agent/author/x")], role: "pilot"))
    }

    @Test("the owner's typed fetch of a branch is tainted; of main, not")
    func ownerFetch() async throws {
        #expect(try await turn(fetching: ["branch": .string("feature")], role: nil))
        #expect(!(try await turn(fetching: [:], role: nil)))
    }
}
