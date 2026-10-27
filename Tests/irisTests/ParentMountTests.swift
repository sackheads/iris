import Testing
import Foundation
@testable import IrisKit

/// #658 (a): a read-write mount holding the person's repositories is refused as its container is
/// made; the repositories a session's VM made don't count next time.
@Suite("Parent mounts refused (#658 a)", .timeLimit(.minutes(1)))
struct ParentMountTests {
    private func temp(_ label: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-658a-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return IrisPaths.realPath(dir.path)
    }

    /// A folder that looks like a clone to git: a `.git` folder.
    private func clone(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path + "/.git", withIntermediateDirectories: true)
    }

    private func manager(_ runtime: MockRuntime, home: String) -> SandboxSessionManager {
        SandboxSessionManager(runtime: runtime, image: { "img" }, startContainerSystem: { true },
                              live: LiveContainerNames(), gitGuard: GitConfigGuard(),
                              paths: IrisPaths(root: URL(fileURLWithPath: home)))
    }

    @Test("a parent of the person's repositories is refused, naming them, and no container is made")
    func parentRefused() async throws {
        let root = try temp("parent"), home = try temp("home")
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: home) }
        try clone(root + "/alpha"); try clone(root + "/beta")
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        let rt = MockRuntime()
        let out = await manager(rt, home: home).run(command: "true", conversationId: UUID(), workspace: ContainerMount(source: root))
        #expect(out.hasPrefix("Not run: \(root) holds git repositories"))
        #expect(out.contains("`\(root)/alpha`") && out.contains("`\(root)/beta`"))
        #expect(out.contains("Mount the one repository being worked on"))
        #expect(rt.createdCount == 0)
    }

    @Test("past five repositories the list is cut, saying how many more")
    func namesCapped() {
        let repos = (1...8).map { "/src/r\($0)" }
        let why = ParentMount.refusal(source: "/src", survey: .init(repositories: repos, capped: false), vmMade: [])
        #expect(why?.contains("`/src/r5`") == true)
        #expect(why?.contains("/src/r6") == false)
        #expect(why?.contains("and 3 more") == true)
    }

    @Test("a folder with no repositories is mounted, and so is one only read-only")
    func plainAndReadOnlyAllowed() async throws {
        let plain = try temp("plain"), parent = try temp("ro"), home = try temp("home")
        defer { for d in [plain, parent, home] { try? FileManager.default.removeItem(atPath: d) } }
        try clone(parent + "/alpha")
        let rt = MockRuntime()
        let m = manager(rt, home: home)
        let out = await m.run(command: "true", conversationId: UUID(), workspace: ContainerMount(source: plain),
                              extraMounts: ["\(parent):/data:ro"])
        #expect(!out.hasPrefix("Not run"), "\(out)")
        #expect(rt.createdCount == 1)
    }

    @Test("a mount whose root is a repository is allowed, nested clones of the person's included (Brian's ruling)")
    func repositoryRootAllowed() throws {
        let root = try temp("repo"), home = try temp("home")
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: home) }
        try clone(root); try clone(root + "/vendor/lib")
        let record = SandboxVMRepositories(paths: IrisPaths(root: URL(fileURLWithPath: home)))
        #expect(ParentMount.repositoryRootAllowsNestedClones)
        let (why, start) = ParentMount.check(source: root, vmRecord: record)
        #expect(why == nil)
        #expect(start == nil, "a repository root isn't walked")
        // The documented alternative: the walk below a repository root finds the nested clone, so
        // turning the ruling off refuses it by name.
        let below = ParentMount.survey(root)
        #expect(below.repositories == [root + "/vendor/lib"])
        #expect(ParentMount.refusal(source: root, survey: below, vmMade: [])?.contains("`\(root)/vendor/lib`") == true)
    }

    @Test("the walk enters no repository and no .git, and finds a gitfile and a bare repository")
    func walkShape() throws {
        let root = try temp("walk")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try clone(root + "/outer"); try clone(root + "/outer/inner")
        try FileManager.default.createDirectory(atPath: root + "/wt", withIntermediateDirectories: true)
        try "gitdir: /elsewhere\n".write(toFile: root + "/wt/.git", atomically: true, encoding: .utf8)
        for sub in ["objects", "refs"] { try FileManager.default.createDirectory(atPath: root + "/bare.git/" + sub, withIntermediateDirectories: true) }
        try "ref: refs/heads/main\n".write(toFile: root + "/bare.git/HEAD", atomically: true, encoding: .utf8)
        #expect(Set(ParentMount.survey(root).repositories) == [root + "/outer", root + "/wt", root + "/bare.git"])
    }

    @Test("a mount too large to walk is refused, naming the limit")
    func capRefused() throws {
        let root = try temp("cap")
        defer { try? FileManager.default.removeItem(atPath: root) }
        for i in 0..<5 { try FileManager.default.createDirectory(atPath: root + "/d\(i)", withIntermediateDirectories: true) }
        let survey = ParentMount.survey(root, entryCap: 3)
        #expect(survey.capped)
        let why = ParentMount.refusal(source: root, survey: survey, vmMade: [])
        #expect(why?.contains("too large to check for git repositories") == true)
        #expect(why?.contains("Mount a narrower folder") == true)
    }

    @Test("a clone the VM made is recorded when its session ends, and the next session's mount is allowed")
    func vmMadeAllowedNextSession() async throws {
        let root = try temp("vm"), home = try temp("home")
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: home) }
        let rt = MockRuntime()
        let m = manager(rt, home: home)
        let first = UUID()
        #expect(!(await m.run(command: "git clone x", conversationId: first, workspace: ContainerMount(source: root))).hasPrefix("Not run"))
        try clone(root + "/x")   // what the VM's clone left on disk
        await m.endSession(first)
        let record = SandboxVMRepositories(paths: IrisPaths(root: URL(fileURLWithPath: home)))
        #expect(record.vmMade(in: root) == [root + "/x"])
        let second = UUID()
        let out = await m.run(command: "true", conversationId: second, workspace: ContainerMount(source: root))
        #expect(!out.hasPrefix("Not run"), "\(out)")
        #expect(rt.createdCount == 2)
        // One the person made there between sessions, with none live, still counts.
        await m.endSession(second)
        try clone(root + "/mine")
        let other = await m.run(command: "true", conversationId: UUID(), workspace: ContainerMount(source: root))
        #expect(other.contains("`\(root)/mine`") && !other.contains("`\(root)/x`"))
    }

    @Test("a session a crash cut short is ended at the next launch, which only records")
    func relaunchRecords() throws {
        let root = try temp("crash"), home = try temp("home")
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: home) }
        let paths = IrisPaths(root: URL(fileURLWithPath: home))
        SandboxVMRepositories(paths: paths).began(owner: "iris-dev-a", starts: [root: []])
        SandboxVMRepositories(paths: paths).began(owner: "iris-dev-b", starts: [root: []])
        try clone(root + "/made")
        // The next process: one container is still live, the other was lost with the crash.
        let relaunched = SandboxVMRepositories(paths: paths)
        relaunched.endAbandoned(except: ["iris-dev-b"])
        #expect(relaunched.vmMade(in: root) == [root + "/made"])
        #expect(FileManager.default.fileExists(atPath: root + "/made/.git"), "nothing moved")
        let data = try Data(contentsOf: relaunched.url)
        let record = try JSONDecoder().decode(SandboxVMRepositories.Record.self, from: data)
        #expect(Array(record.live.keys) == ["iris-dev-b"])
    }

    @Test("a corrupt record is empty: no command is refused for it, and a mount is refused at worst with names")
    func corruptRecordIsEmpty() async throws {
        let plain = try temp("plain"), parent = try temp("parent"), home = try temp("home")
        defer { for d in [plain, parent, home] { try? FileManager.default.removeItem(atPath: d) } }
        let paths = IrisPaths(root: URL(fileURLWithPath: home))
        try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: SandboxVMRepositories(paths: paths).url)
        try clone(parent + "/alpha")
        #expect(SandboxVMRepositories(paths: paths).vmMade(in: parent).isEmpty)
        let rt = MockRuntime()
        let m = manager(rt, home: home)
        let id = UUID()
        #expect(!(await m.run(command: "true", conversationId: id, workspace: ContainerMount(source: plain))).hasPrefix("Not run"))
        #expect(!(await m.run(command: "true", conversationId: id, workspace: ContainerMount(source: plain))).hasPrefix("Not run"))
        let refused = await m.run(command: "true", conversationId: UUID(), workspace: ContainerMount(source: parent))
        #expect(refused.contains("`\(parent)/alpha`"))
    }

    @Test("the check runs as a container is made, not per command")
    func notPerCommand() async throws {
        let root = try temp("once"), home = try temp("home")
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: home) }
        let rt = MockRuntime()
        let m = manager(rt, home: home)
        let id = UUID()
        _ = await m.run(command: "true", conversationId: id, workspace: ContainerMount(source: root))
        try clone(root + "/later")   // made mid-session: the live session's commands still run
        let out = await m.run(command: "true", conversationId: id, workspace: ContainerMount(source: root))
        #expect(!out.hasPrefix("Not run"), "\(out)")
        #expect(rt.createdCount == 1)
    }

    @Test("the one-off container with no conversation refuses a parent too, and runs in a plain folder")
    func oneOffRefused() async throws {
        let parent = try temp("oneoff"), plain = try temp("oneoff-plain"), home = try temp("home")
        defer { for d in [parent, plain, home] { try? FileManager.default.removeItem(atPath: d) } }
        try clone(parent + "/alpha")
        var executor = ToolExecutor()
        executor.containerBinaryPath = { "/usr/bin/true" }   // stands in for `container`
        executor.irisPaths = IrisPaths(root: URL(fileURLWithPath: home))
        func run(_ cwd: String) async -> String {
            await executor.execute(name: "run_command", args: ["command": .string("true")], cwd: cwd,
                                   conversationId: nil, useSandbox: true)
        }
        #expect(await run(parent).hasPrefix("Not run: \(parent) holds git repositories (`\(parent)/alpha`)"))
        #expect(!(await run(plain)).hasPrefix("Not run"))
    }

    @Test("a mutating job's grant is refused when the job is made, read-only mounts aside")
    func grantRefused() async throws {
        let parent = try temp("grant"), home = try temp("home")
        defer { try? FileManager.default.removeItem(atPath: parent); try? FileManager.default.removeItem(atPath: home) }
        try clone(parent + "/alpha")
        let paths = IrisPaths(root: URL(fileURLWithPath: home))
        let why = await ParentMount.grantRefusal(JobGrant(mounts: [ContainerMount(source: parent)]), paths: paths)
        #expect(why?.contains("`\(parent)/alpha`") == true)
        #expect(await ParentMount.grantRefusal(JobGrant(mounts: [ContainerMount(source: parent, readOnly: true)]), paths: paths) == nil)
    }

    @Test("a clone made while a session is live doesn't refuse a second container on the same folder, a subagent's say")
    func liveSessionCloneExcused() async throws {
        let root = try temp("live"), home = try temp("home")
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: home) }
        let rt = MockRuntime()
        let m = manager(rt, home: home)
        #expect(!(await m.run(command: "git clone x", conversationId: UUID(), workspace: ContainerMount(source: root))).hasPrefix("Not run"))
        try clone(root + "/x")
        let out = await m.run(command: "true", conversationId: UUID(), workspace: ContainerMount(source: root))
        #expect(!out.hasPrefix("Not run"), "\(out)")
        #expect(rt.createdCount == 2)
    }
}
