import Testing
import Foundation
@testable import iris

/// #282 §3, §0.9 — the pure gate. Temp directories only.
@Suite("JobGrant.allows (#282)")
struct JobGrantAllowsTests {
    struct Tree {
        let base: URL; let proj: URL; let project: URL; let ro: URL; let inner: URL; let home: URL
        var grant: JobGrant {
            JobGrant(mounts: [ContainerMount(source: IrisPaths.canonicalPath(proj.path)),
                              ContainerMount(source: IrisPaths.canonicalPath(ro.path), readOnly: true),
                              ContainerMount(source: IrisPaths.canonicalPath(inner.path), readOnly: true)])
        }
        func tearDown() { try? FileManager.default.removeItem(at: base) }
    }

    /// proj/ (rw) with proj/locked/ (ro, nested), project/ (a sibling sharing a prefix), ro/ (ro),
    /// and a fake home holding `.iris/config`. Sources are stored the way Task 2a stores them
    /// (`canonicalPath`, i.e. `/tmp/...`), while `allows` compares real paths (`/private/tmp/...`).
    static func tree() throws -> Tree {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-gate-\(UUID().uuidString)")
        for name in ["proj/locked", "project", "ro", "home/.iris/config"] {
            try fm.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        return Tree(base: base, proj: base.appendingPathComponent("proj"), project: base.appendingPathComponent("project"),
                    ro: base.appendingPathComponent("ro"), inner: base.appendingPathComponent("proj/locked"),
                    home: base.appendingPathComponent("home"))
    }

    static func c(_ url: URL, _ tail: String = "") -> String {
        IrisPaths.canonicalPath(tail.isEmpty ? url.path : url.appendingPathComponent(tail).path)
    }
    private func c(_ url: URL, _ tail: String = "") -> String { Self.c(url, tail) }

    @Test("write_file inside a read-write mount, at the boundary, outside, one directory up, and through ..")
    func writeInsideBoundaryOutside() throws {
        let t = try Self.tree(); defer { t.tearDown() }
        let g = t.grant
        #expect(g.allows(toolName: "write_file", details: c(t.proj, "out.md"), cwd: nil, sandboxed: false))
        #expect(g.allows(toolName: "write_file", details: c(t.proj, "new/dir/out.md"), cwd: nil, sandboxed: false), "a file under a directory that does not exist yet still resolves to the mount")
        #expect(!g.allows(toolName: "write_file", details: c(t.project, "out.md"), cwd: nil, sandboxed: false), "/proj does not cover /project")
        #expect(!g.allows(toolName: "write_file", details: c(t.base, "out.md"), cwd: nil, sandboxed: false), "one directory above the mount")
        #expect(!g.allows(toolName: "write_file", details: c(t.proj) + "/../out.md", cwd: nil, sandboxed: false), ".. is refused outright")
        #expect(!g.allows(toolName: "write_file", details: c(t.proj) + "/../proj/out.md", cwd: nil, sandboxed: false), "even a .. that would land inside")
        #expect(g.allows(toolName: "write_file", details: c(t.proj), cwd: nil, sandboxed: false), "the mount itself")
        // Spelled under the granted directory, not merely resolving there: the firmlink spelling reaches
        // the mount through `/private`, which the walk cannot descend from the mount's root.
        #expect(!g.allows(toolName: "write_file", details: "/private" + c(t.proj, "out.md"), cwd: nil, sandboxed: false), "a spelling that is not under the granted directory falls to the allowlist")
        #expect(g.allowedMount(toolName: "write_file", details: c(t.proj, "new/dir/out.md"), cwd: nil)?.source == c(t.proj))
        #expect(g.relativeComponents(of: c(t.proj, "new/./dir/out.md"), cwd: nil, under: g.mounts[0]) == ["new", "dir", "out.md"])
    }

    @Test("a differently-cased spelling of a granted directory is allowed (§3): the walk, not the string, proves identity")
    func differentlyCasedSpellingIsAllowed() throws {
        let t = try Self.tree(); defer { t.tearDown() }
        // The claim is about APFS's default: a case-insensitive volume keeps the caller's spelling.
        // On a case-sensitive volume `PROJ` is simply another directory and there is nothing to pin.
        let caseSensitive = try t.base.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? false
        guard !caseSensitive else { return }
        let upper = t.base.appendingPathComponent("PROJ").appendingPathComponent("out.md").path
        let mount = try #require(t.grant.allowedMount(toolName: "write_file", details: upper, cwd: nil))
        #expect(mount.source == c(t.proj), "realpath already spelled the real path as on disk, so the exact comparison finds the entry")
        #expect(t.grant.relativeComponents(of: upper, cwd: nil, under: mount) == ["out.md"], "and the walk starts at the granted root, so on any volume the write lands in the granted directory")
        #expect(!t.grant.allows(toolName: "write_file", details: t.base.appendingPathComponent("PROJECT/out.md").path, cwd: nil, sandboxed: false), "case-insensitive is not prefix-insensitive")
    }

    @Test("the real path is compared exactly: a differently-cased sibling that really exists is another directory, not the grant (§0.13 amendment)")
    func differentlyCasedSiblingIsRefused() throws {
        let t = try Self.tree(); defer { t.tearDown() }
        // Pure, on any volume: `covering` takes real paths, and realpath(3) returns the on-disk case
        // for every existing component (measured), so a real path differing from the stored source
        // in case only is a different directory — on a case-sensitive volume, an existing one.
        let realProj = IrisPaths.realPath(c(t.proj))
        let upper = (realProj as NSString).deletingLastPathComponent + "/PROJ/x"
        #expect(t.grant.covering(upper) == nil)
        #expect(t.grant.covering(realProj + "/x")?.source == c(t.proj))
        // End to end, where the sibling can exist: grant `proj`, a different directory `PROJ` beside
        // it. Before the amendment the fold chose `proj`, the walk opened it, and `proj/x` was
        // written for a call that named `PROJ/x`. On a case-insensitive volume `PROJ` is `proj`
        // and `differentlyCasedSpellingIsAllowed` is the test.
        let caseSensitive = try t.base.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? false
        guard caseSensitive else { return }
        let sibling = t.base.appendingPathComponent("PROJ")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let target = sibling.appendingPathComponent("x").path
        #expect(!t.grant.allows(toolName: "write_file", details: target, cwd: nil, sandboxed: false))
        #expect(t.grant.allowedMount(toolName: "write_file", details: target, cwd: nil) == nil)
        #expect(t.grant.nearest(to: target, cwd: nil) == c(t.proj), "refused with the nearest granted directory named")
    }

    @Test("a relative path resolves against the working directory before it is judged")
    func relativeAgainstCwd() throws {
        let t = try Self.tree(); defer { t.tearDown() }
        #expect(t.grant.allows(toolName: "write_file", details: "out.md", cwd: c(t.proj), sandboxed: false))
        #expect(!t.grant.allows(toolName: "write_file", details: "../out.md", cwd: c(t.proj), sandboxed: false))
        #expect(!t.grant.allows(toolName: "write_file", details: "out.md", cwd: c(t.base), sandboxed: false))
        #expect(!t.grant.allows(toolName: "write_file", details: "out.md", cwd: nil, sandboxed: false), "no cwd: nothing to resolve against, refused")
    }

    @Test("a symlink from inside a mount to a protected directory resolves outside and is refused, with or without a .. (§0.9)")
    func symlinkToProtected() throws {
        let t = try Self.tree(); defer { t.tearDown() }
        let link = t.proj.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: t.home.appendingPathComponent(".iris"))
        // `permissions.json` does not exist in the tree (§0.9, measured): only the new-file case
        // diverges from the kernel under the old lexical resolution, and it is `write_file`'s case.
        #expect(!FileManager.default.fileExists(atPath: link.path + "/config/permissions.json"))
        for tool in ["write_file", "read_file"] {
            #expect(!t.grant.allows(toolName: tool, details: link.path + "/config/permissions.json", cwd: nil, sandboxed: false), Comment(rawValue: tool))
            #expect(!t.grant.allows(toolName: tool, details: link.path + "/../.iris/config/permissions.json", cwd: nil, sandboxed: false), Comment(rawValue: tool))
        }
        // The lexical form of that last path is inside the mount — which is exactly the trap.
        #expect(IrisPaths.canonicalPath(link.path + "/../.iris/config/permissions.json").hasPrefix(c(t.proj)))
    }

    @Test("read under a read-only mount is allowed; write under it is refused; the innermost entry wins")
    func readOnlyAndInnermost() throws {
        let t = try Self.tree(); defer { t.tearDown() }
        let g = t.grant
        #expect(g.allows(toolName: "read_file", details: c(t.ro, "key"), cwd: nil, sandboxed: false))
        #expect(!g.allows(toolName: "write_file", details: c(t.ro, "key"), cwd: nil, sandboxed: false))
        #expect(!g.allows(toolName: "write_file", details: c(t.inner, "x"), cwd: nil, sandboxed: false))
        #expect(g.allows(toolName: "read_file", details: c(t.inner, "x"), cwd: nil, sandboxed: false))
        #expect(g.allows(toolName: "write_file", details: c(t.proj, "lockedfile"), cwd: nil, sandboxed: false), "a sibling name that merely starts with 'locked' is still under proj")
        #expect(g.covering(IrisPaths.realPath(c(t.inner, "x")))?.source == c(t.inner))
        #expect(g.covering(IrisPaths.realPath(c(t.project, "x"))) == nil)
    }

    @Test("run_command is the sandbox answer; every other tool is false; a mountless grant allows only run_command")
    func runCommandAndTheRest() throws {
        let t = try Self.tree(); defer { t.tearDown() }
        #expect(t.grant.allows(toolName: "run_command", details: "rm -rf /", cwd: nil, sandboxed: true))
        #expect(!t.grant.allows(toolName: "run_command", details: "rm -rf /", cwd: nil, sandboxed: false),
                "§0.4: the grant asks the sandbox question itself — a path that reaches approval unsandboxed gets false, not true")
        for tool in ["create_skill", "update_memory", "save_fact", "gmail_send_email", "register_directory_watcher", "set_workspace"] {
            #expect(!t.grant.allows(toolName: tool, details: c(t.proj, "x"), cwd: nil, sandboxed: false), Comment(rawValue: tool))
        }
        let netOnly = JobGrant(network: true)
        #expect(netOnly.allows(toolName: "run_command", details: "curl x", cwd: nil, sandboxed: true))
        #expect(!netOnly.allows(toolName: "run_command", details: "curl x", cwd: nil, sandboxed: false))
        #expect(!netOnly.allows(toolName: "write_file", details: c(t.proj, "x"), cwd: nil, sandboxed: false))
        #expect(netOnly.nearest(to: c(t.proj, "x"), cwd: nil) == nil)
    }

    @Test("nearest names the granted directory sharing the longest prefix with the path")
    func nearestDirectory() throws {
        let t = try Self.tree(); defer { t.tearDown() }
        #expect(t.grant.nearest(to: c(t.base, "out.md"), cwd: nil) == c(t.proj), "a tie between proj and ro goes to the earlier entry")
        #expect(t.grant.nearest(to: c(t.ro, "sub/x"), cwd: nil) == c(t.ro))
        #expect(t.grant.nearest(to: c(t.proj, "locked/deeper/x"), cwd: nil) == c(t.inner))
        #expect(t.grant.nearest(to: "/nowhere/x", cwd: nil) == c(t.proj), "nothing shared beyond / still names something")
        #expect(t.grant.nearest(to: c(t.proj) + "/../x", cwd: nil) == c(t.proj), "a refused .. path is still told where the grant is")
    }

    @Test("nearest for a relative path with no working directory names the first mount, not somewhere under the process cwd")
    func nearestForARelativePathWithoutCwd() throws {
        let t = try Self.tree(); defer { t.tearDown() }
        // The second entry IS the process cwd: resolving a bare `out.md` against it would name it.
        let launchDir = IrisPaths.canonicalPath(FileManager.default.currentDirectoryPath)
        let g = JobGrant(mounts: [ContainerMount(source: c(t.ro), readOnly: true), ContainerMount(source: launchDir)])
        #expect(g.nearest(to: "out.md", cwd: nil) == c(t.ro), "the card must not depend on where the daemon was launched")
        #expect(g.nearest(to: "out.md", cwd: launchDir) == launchDir, "with a cwd it is placed as usual")
        #expect(JobGrant(network: true).nearest(to: "out.md", cwd: nil) == nil)
    }
}

/// The gate in its place (#282 §3): `AppState.requestApproval`'s background branch. The permission
/// layer is pointed at a temp `IrisPaths`, never `~/.iris`.
@MainActor
@Suite("JobGrant through requestApproval (#282)")
struct JobGrantApprovalTests {
    private typealias Tree = JobGrantAllowsTests.Tree
    private func c(_ url: URL, _ tail: String = "") -> String { JobGrantAllowsTests.c(url, tail) }

    private func background(_ t: Tree, grant: JobGrant?) -> (AppState, UUID) {
        let app = AppState()
        app.permissions = PermissionManager(paths: IrisPaths(root: t.home.appendingPathComponent(".iris")))
        let cid = app.createNewConversation(isBackground: true, select: false)
        app.setWorkspace(for: cid, path: c(t.proj))
        app.setSandboxGrant(for: cid, grant)
        return (app, cid)
    }

    @Test("a granted run_command is allowed only with the sandbox answer in hand (§0.4)")
    func grantedCommandNeedsTheSandboxAnswer() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let (app, cid) = background(t, grant: t.grant)
        #expect(await app.requestApproval(toolName: "run_command", details: "git status", args: ["command": .string("git status")],
                                          workspace: c(t.proj), conversationId: cid, inSandbox: true))
        #expect(app.takeBackgroundDenials(for: cid).isEmpty)
        // The same call arriving with the dispatcher's answer "not sandboxed" (R20 would have refused
        // it first; this is the second lock) falls to the allowlist and is recorded.
        #expect(!(await app.requestApproval(toolName: "run_command", details: "git status", args: ["command": .string("git status")],
                                            workspace: c(t.proj), conversationId: cid, inSandbox: false)))
        let denial = try #require(app.takeBackgroundDenials(for: cid).first)
        #expect(denial.toolName == "run_command")
        #expect(denial.grantNearest == nil, "a command is not placed against the grant's directories; 'nearest' is the file tools' word")
        #expect(app.conversations.first { $0.id == cid }?.messages.last?.content
                == String(format: AppState.unattendedDenialNotice, "run_command"))
    }

    @Test("a granted background conversation runs a write inside the grant without a denial or a dialog")
    func grantedWriteIsAllowed() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let (app, cid) = background(t, grant: t.grant)
        let decided = t.grant.allowedMount(toolName: "write_file", details: "out.md", cwd: c(t.proj))
        let ok = await app.requestApproval(toolName: "write_file", details: "out.md",
                                           args: ["path": .string("out.md")], workspace: c(t.proj), conversationId: cid,
                                           grantedMount: decided)
        #expect(ok)
        #expect(app.pendingApprovals.isEmpty && app.takeBackgroundDenials(for: cid).isEmpty)
        #expect(app.conversations.first { $0.id == cid }?.messages.isEmpty == true)
    }

    @Test("R10 is asked first: a grant that somehow covers a protected directory still cannot write into it")
    func protectedWriteBeatsTheGrant() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        // Never creatable through the tools (Task 2a refuses ~/.iris), so built by hand.
        let rogue = JobGrant(mounts: [ContainerMount(source: c(t.home, ".iris"))])
        let (app, cid) = background(t, grant: rogue)
        let target = c(t.home, ".iris/config/permissions.json")
        // The dispatcher's decision under the rogue grant is a yes — the mount covers the path — so
        // only R10, asked first, stands between this call and `true`.
        let decided = rogue.allowedMount(toolName: "write_file", details: target, cwd: c(t.proj))
        #expect(decided != nil, "the grant says yes; the refusal has to be R10's")
        let ok = await app.requestApproval(toolName: "write_file", details: target,
                                           args: ["path": .string(target)], workspace: c(t.proj), conversationId: cid,
                                           grantedMount: decided)
        #expect(!ok)
        let denial = try #require(app.takeBackgroundDenials(for: cid).first)
        #expect(denial.reason == .approval && denial.grantNearest == nil, "a protected write is refused as R10, not as 'outside the grant'")
    }

    @Test("the reproduced escape — link/../ into ~/.iris from inside a read-write mount — is recorded as R10, for both tools (§0.9)")
    func linkDotDotIsRecordedAsProtected() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let link = t.proj.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: t.home.appendingPathComponent(".iris"))
        let (app, cid) = background(t, grant: t.grant)
        let escape = link.path + "/../.iris/config/permissions.json"
        #expect(!(await app.requestApproval(toolName: "write_file", details: escape, args: ["path": .string(escape)],
                                            workspace: c(t.proj), conversationId: cid)))
        let denial = try #require(app.takeBackgroundDenials(for: cid).first)
        #expect(denial.grantNearest == nil, "refused by R10, before the grant is read")
        #expect(app.conversations.first { $0.id == cid }?.messages.last?.content
                == String(format: AppState.unattendedDenialNotice, "write_file"))
        // A read through the same link with no `..` resolves outside every mount by real path, so
        // the dispatcher's decision for it is nil; the gate refuses on that decision and names the
        // call as outside the grant (reads are not R10's business).
        let read = link.path + "/config/permissions.json"
        let readDecision = t.grant.allowedMount(toolName: "read_file", details: read, cwd: c(t.proj))
        #expect(readDecision == nil, "the real path is ~/.iris/config, under no mount")
        #expect(!(await app.requestApproval(toolName: "read_file", details: read, args: ["path": .string(read)],
                                            workspace: c(t.proj), conversationId: cid, grantedMount: readDecision)))
        #expect(app.takeBackgroundDenials(for: cid).first?.grantNearest == c(t.proj))
    }

    @Test("in a granted run the file tools are the grant's alone: an allowlisted write outside it is recorded with the nearest directory; other tools still fall to the allowlist")
    func missFallsToAllowlistThenRecords() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let (app, cid) = background(t, grant: t.grant)
        let outside = c(t.base, "elsewhere.md")
        let rules = t.proj.appendingPathComponent(".iris")
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        try JSONEncoder().encode([PermissionRule(toolName: "write_file", details: outside),
                                  PermissionRule(toolName: "run_command", details: "make lint")])
            .write(to: rules.appendingPathComponent("permissions.json"))
        // H1's invariant: a granted run's write reaches Foundation on no branch, so the allowlist
        // cannot widen the two file tools — the decision (nil here) is the whole answer.
        #expect(!(await app.requestApproval(toolName: "write_file", details: outside, args: ["path": .string(outside)],
                                            workspace: c(t.proj), conversationId: cid, grantedMount: nil)))
        #expect(app.takeBackgroundDenials(for: cid).first?.grantNearest == c(t.proj))
        // Every other tool keeps the allowlist step (here a command the sandbox answer refused).
        #expect(await app.requestApproval(toolName: "run_command", details: "make lint", workspace: c(t.proj),
                                          conversationId: cid, inSandbox: false))
        // And an ungranted background run's allowlisted write is exactly as today.
        let (plainApp, plainCid) = background(t, grant: nil)
        #expect(await plainApp.requestApproval(toolName: "write_file", details: outside, workspace: c(t.proj), conversationId: plainCid))

        let other = c(t.base, "other.md")
        #expect(!(await app.requestApproval(toolName: "write_file", details: other, args: ["path": .string(other)],
                                            workspace: c(t.proj), conversationId: cid)))
        let denial = try #require(app.takeBackgroundDenials(for: cid).first)
        #expect(denial.grantNearest == c(t.proj))
        let notice = String(format: AppState.outsideGrantDenialNotice, "write_file", c(t.proj))
        #expect(app.conversations.first { $0.id == cid }?.messages.last?.content == notice)
    }

    @Test("an ungranted background conversation is exactly as before: denied, recorded, the old notice")
    func ungrantedUnchanged() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let (app, cid) = background(t, grant: nil)
        let target = c(t.proj, "x.md")
        #expect(!(await app.requestApproval(toolName: "write_file", details: target, workspace: c(t.proj), conversationId: cid)))
        #expect(app.takeBackgroundDenials(for: cid).first?.grantNearest == nil)
        #expect(app.conversations.first { $0.id == cid }?.messages.last?.content
                == String(format: AppState.unattendedDenialNotice, "write_file"))
    }

    @Test("a read-only profile refuses a granted call before approval is ever asked (R13 untouched)")
    func readOnlyProfileRefusesFirst() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.permissions = PermissionManager(paths: IrisPaths(root: t.home.appendingPathComponent(".iris")))
        let target = c(t.proj, "x.md")
        let call = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
            Part(functionCall: FunctionCall(name: "write_file", args: ["path": .string(target), "content": .string("hi")]))]))],
                                  usageMetadata: nil)
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: [call]),
                                protectionEnabled: false, sessionPeerCount: 0, recentWrites: RecentWrites())
        let cid = state.createNewConversation(isBackground: true, select: false)
        state.setJobProfile(for: cid, .readOnly)
        state.setSandboxGrant(for: cid, t.grant)          // a contradiction Task 2a refuses at creation; the profile still wins
        await engine.processInput("go", source: "job:x", conversationId: cid)
        let denial = try #require(state.takeBackgroundDenials(for: cid).first)
        #expect(denial.reason == .profile)
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test("through the engine, a granted write is routed to the walk: a link inside the mount is refused by the walk, a plain write lands")
    func engineRoutesGrantedWritesToTheWalk() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        // The link points INSIDE the grant (proj/real), so the decision allows — the real path is
        // covered — and only the walk refuses. A link to a sibling outside would be refused by the
        // decision first and would not exercise the routing at all (M3).
        let real = t.proj.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: t.proj.appendingPathComponent("link"), withDestinationURL: real)
        func turn(_ path: String) async throws -> (result: String, state: AppState) {
            let store = try ConversationStore.inMemory()
            let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
            state.conversations.removeAll()
            state.permissions = PermissionManager(paths: IrisPaths(root: t.home.appendingPathComponent(".iris")))
            let call = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
                Part(functionCall: FunctionCall(name: "write_file", args: ["path": .string(path), "content": .string("hi")]))]))], usageMetadata: nil)
            let done = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))], usageMetadata: nil)
            // The engine's own registry (AGENTS invariant 7): a successful unattended write records
            // into it, and the default is the process-shared one.
            let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: [call, done]),
                                    protectionEnabled: false, sessionPeerCount: 0, recentWrites: RecentWrites())
            let cid = state.createNewConversation(isBackground: true, select: false)
            state.setJobProfile(for: cid, .mutating)
            state.setWorkspace(for: cid, path: c(t.proj))
            state.setSandboxGrant(for: cid, t.grant)
            await engine.processInput("go", source: "job:x", conversationId: cid)
            let results = state.conversations.first { $0.id == cid }?.history.flatMap { $0.parts }
                .compactMap { $0.functionResponse?.response["result"]?.stringValue } ?? []
            return (results.joined(separator: "\n"), state)
        }
        let plain = try await turn("out.md")
        #expect(plain.result.contains("Successfully wrote to \(c(t.proj))/out.md"))
        #expect(FileManager.default.fileExists(atPath: c(t.proj, "out.md")))
        let viaLink = try await turn("link/x.md")
        #expect(viaLink.result.contains(GrantedFileError.symlink(component: "link").message), "Foundation would have followed the link into proj/real; the walk refused it")
        #expect(!FileManager.default.fileExists(atPath: real.appendingPathComponent("x.md").path))
    }

    @Test("a component toggled link → directory → link across the three instants is refused: the gate consumes the decision, the executor has no fallback (H1)")
    func toggleBetweenDecisionAndGateIsRefused() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let sub = t.proj.appendingPathComponent("sub")
        let target = c(t.proj, "sub/authorized_keys")
        // t1 — the dispatcher decides while `sub` is a link to somewhere outside: nil.
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: t.base.appendingPathComponent("project"))
        let decided = t.grant.allowedMount(toolName: "write_file", details: target, cwd: c(t.proj))
        #expect(decided == nil)
        // t2/t3 — the attacker's `cmd &` swaps it back to a real directory before the gate runs.
        try FileManager.default.removeItem(at: sub)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(t.grant.allowedMount(toolName: "write_file", details: target, cwd: c(t.proj)) != nil, "a gate that recomputed would now say yes")
        let (app, cid) = background(t, grant: t.grant)
        let ok = await app.requestApproval(toolName: "write_file", details: target, args: ["path": .string(target)],
                                           workspace: c(t.proj), conversationId: cid, grantedMount: decided)
        #expect(!ok, "the gate consumes the decision it was handed")
        #expect(app.takeBackgroundDenials(for: cid).first?.grantNearest == c(t.proj))
        // t4 — and had it somehow reached the executor with that nil decision, while `sub` is a link again:
        try FileManager.default.removeItem(at: sub)
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: t.base.appendingPathComponent("project"))
        let out = await ToolExecutor().execute(name: "write_file", args: ["path": .string(target), "content": .string("ssh-ed25519 …")],
                                               cwd: c(t.proj), grant: t.grant, grantedMount: decided)
        #expect(out == ToolExecutor.notDecidedInsideGrant("write_file"))
        #expect(!FileManager.default.fileExists(atPath: c(t.project, "authorized_keys")))
    }
}
