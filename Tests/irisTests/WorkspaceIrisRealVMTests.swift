import Testing
import Foundation
@testable import IrisKit

/// #617 on a real VM: a workspace mounted the way Iris mounts it (`SandboxSessionManager.mountList`)
/// leaves its `.iris/` unwritable from inside, by any route, and the host files unchanged. Opt-in
/// like `SandboxRealVMTests` (`IRIS_REAL_VM=1`). The removal cases are a suite of their own,
/// `WorkspaceIrisRealVMRemovalTests`, behind a second opt-in.
enum WorkspaceIrisVM {
    /// A throwaway workspace with `.iris/vibecop.md` and `.iris/permissions.json`, prepared and
    /// mounted as the session path does, and a container over it.
    static func withWorkspace(_ body: (CLIContainerRuntime, String, String) async throws -> Void) async throws {
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("iris-617-vm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let host = IrisPaths.realPath(ws.path)
        defer { try? FileManager.default.removeItem(atPath: host) }
        guard case .ready = WorkspaceIrisDir.prepareForMount(host) else { Issue.record("prepare refused"); return }
        try "original\n".write(toFile: host + "/.iris/vibecop.md", atomically: false, encoding: .utf8)
        try "[]".write(toFile: host + "/.iris/permissions.json", atomically: false, encoding: .utf8)
        try "hi\n".write(toFile: host + "/other.txt", atomically: false, encoding: .utf8)
        let rt = RealContainer.runtime()
        let name = RealContainer.uniqueName(617)
        defer { RealContainer.delete(name) }
        try await rt.createDetached(name: name, image: RealContainer.image,
                                    mounts: SandboxSessionManager.mountList(workspace: ContainerMount(source: host), extra: []),
                                    workdir: host, network: .default)
        try await body(rt, name, host)
        #expect(try String(contentsOfFile: host + "/.iris/vibecop.md", encoding: .utf8) == "original\n")
        #expect(try String(contentsOfFile: host + "/.iris/permissions.json", encoding: .utf8) == "[]")
    }

    /// Runs each command in the VM and records any that succeeded.
    static func expectAllFail(_ commands: [String], rt: CLIContainerRuntime, name: String, host: String) async throws {
        for command in commands {
            let result = try await rt.exec(name: name, workdir: host, command: command, timeoutSeconds: 60)
            #expect(result.exitCode != 0, "succeeded in the VM: \(command)")
        }
    }
}

@Suite("Workspace .iris is read-only in a real VM (#617)", .serialized,
       .enabled(if: RealContainer.isAvailable, "opt-in: IRIS_REAL_VM=1, with the container runtime started and \(RealContainer.image) local"),
       .timeLimit(.minutes(5)))
struct WorkspaceIrisRealVMTests {
    @Test("no write, move, chmod, link or remount reaches .iris, and the host files are unchanged")
    func nothingWrites() async throws {
        try await WorkspaceIrisVM.withWorkspace { rt, name, host in
            let check = try await rt.exec(name: name, workdir: host, command: "grep ' \(host)/.iris ' /proc/mounts", timeoutSeconds: 30)
            #expect(check.stdout.contains(" ro,") || check.stdout.contains(" ro "), "mounted read-only: \(check.stdout)")
            try await WorkspaceIrisVM.expectAllFail([
                "echo x > .iris/vibecop.md", "echo x >> .iris/vibecop.md", "echo x > .iris/new.md",
                "truncate -s0 .iris/vibecop.md", "touch .iris/vibecop.md", "cp other.txt .iris/vibecop.md",
                "mv .iris moved", "mv other.txt .iris", "mkdir -p /tmp/e && mv /tmp/e .iris",
                "chmod 777 .iris/vibecop.md", "chmod 777 .iris",
                "ln -s /tmp .iris/link", "ln .iris/vibecop.md handle",
                "mount -o remount,rw .iris", "umount .iris",
            ], rt: rt, name: name, host: host)
        }
    }
}

/// Removals need an opt-in of their own, `IRIS_REAL_VM_REMOVALS=1` beside `IRIS_REAL_VM=1`: a person
/// runs these on purpose, never as a side effect of a filter that also matched this suite (#617).
@Suite("Workspace .iris cannot be removed in a real VM (#617)", .serialized,
       .enabled(if: RealContainer.isAvailable && ProcessInfo.processInfo.environment["IRIS_REAL_VM_REMOVALS"] == "1",
                "opt-in: IRIS_REAL_VM=1 and IRIS_REAL_VM_REMOVALS=1, with the container runtime started and \(RealContainer.image) local"),
       .timeLimit(.minutes(5)))
struct WorkspaceIrisRealVMRemovalTests {
    @Test("rm and rm -rf of .iris and its files fail in the VM, and the host files are unchanged")
    func nothingRemoves() async throws {
        try await WorkspaceIrisVM.withWorkspace { rt, name, host in
            try await WorkspaceIrisVM.expectAllFail([
                "rm .iris/vibecop.md", "rm -f .iris/permissions.json", "rm -rf .iris", "rm -rf .iris/*",
                "find .iris -mindepth 1 -delete",
            ], rt: rt, name: name, host: host)
        }
    }
}

/// #623 on a real VM: a repository mounted the way Iris mounts it keeps its hooks and its `.git`
/// itself out of the VM's reach, while everything a commit writes stays writable. Plain shell, not
/// git: the image need not have git.
@Suite("The sandbox's own git dir in a real VM (#658)", .serialized,
       .enabled(if: RealContainer.isAvailable, "opt-in: IRIS_REAL_VM=1, with the container runtime started and \(RealContainer.image) local"),
       .timeLimit(.minutes(10)))
struct SandboxGitRealVMTests {
    /// Notes the manager posts for the person, collected.
    final class Notes: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ s: String) { lock.lock(); all.append(s); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return all.joined(separator: "\n") }
    }

    /// A session over `workspace` whose image has git (installed on first use; needs the network).
    private func session(_ dir: String, workspace: String) async throws -> (SandboxSessionManager, UUID, Notes) {
        let manager = SandboxSessionManager(runtime: RealContainer.runtime(), image: { RealContainer.image },
                                            gitGuard: GitConfigGuard(), paths: IrisPaths(root: URL(fileURLWithPath: dir + "/iris-home")))
        let id = UUID()
        let notes = Notes()
        let setUp = await manager.run(command: "(apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git) >/dev/null 2>&1; git config --global safe.directory '*' && git config --global user.email v@v && git config --global user.name v && git --version",
                                      conversationId: id, workspace: ContainerMount(source: workspace), timeoutSeconds: 600)
        try #require(setUp.contains("git version"), "git in the VM: \(setUp)")
        return (manager, id, notes)
    }

    private func run(_ manager: SandboxSessionManager, _ id: UUID, _ notes: Notes, _ workspace: String, _ command: String) async -> String {
        await manager.run(command: command, conversationId: id, workspace: ContainerMount(source: workspace), timeoutSeconds: 120,
                          onNote: { notes.add($0) })
    }

    private func fingerprint(_ gitDir: String) -> [String: Data] {
        var out: [String: Data] = [:]
        for name in ["config", "hooks", "modules/s/config", "info/exclude"] {
            let path = gitDir + "/" + name
            if let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
                for n in names { out[name + "/" + n] = FileManager.default.contents(atPath: path + "/" + n) }
            } else {
                out[name] = FileManager.default.contents(atPath: path)
            }
        }
        return out
    }

    @Test("VM commits reach the host branch as a ref and index move with a note; nothing the VM writes in its git dir runs on the host")
    func commitsAndRepros() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        try await GitFixture.sh("git branch -m main && git init -q -b main \(dir)/sub && git -C \(dir)/sub -c user.email=a@b -c user.name=a commit -q --allow-empty -m s && git -c protocol.file.allow=always submodule -q add \(dir)/sub s && git commit -qm sub",
                                in: ws, env: env)
        let (manager, id, notes) = try await session(dir, workspace: ws)
        defer { Task { await manager.closeSession(id) } }
        let mark = dir + "/RAN"
        try "#!/bin/sh\ntouch \(mark)-$1\n".write(toFile: ws + "/evil.sh", atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ws + "/evil.sh")
        let before = fingerprint(ws + "/.git")
        let old = try await GitFixture.sh("git rev-parse main", in: ws, env: env).out.trimmingCharacters(in: .whitespacesAndNewlines)

        let commit = await run(manager, id, notes, ws, "echo vm > v.txt && git add v.txt && git commit -qm vm && git log --oneline -1")
        #expect(commit.contains("vm"), "\(commit)")
        let new = try await GitFixture.sh("git rev-parse main", in: ws, env: env).out.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(new != old, "the host branch moved")
        #expect(notes.text.contains("Moved main \(old.prefix(7))..\(new.prefix(7)) (1 commit from the sandbox)"), "\(notes.text)")
        #expect(try await GitFixture.sh("git status --porcelain -- v.txt", in: ws, env: env).out.isEmpty, "the host index has the VM's commit")

        // The repros from #632, #651 and #657, written in the VM: they land in the VM's own git dir.
        let e = ws + "/evil.sh"
        let plant = await run(manager, id, notes, ws, """
            git config core.fsmonitor '\(e) fsmonitor' && git config core.hooksPath /tmp && git config core.pager '\(e) pager' && \
            git config diff.external '\(e) diffext' && git config filter.f.clean '\(e) clean' && git config diff.d.textconv '\(e) textconv' && \
            git config alias.st '-c core.fsmonitor=\(e) status' && git config include.path /tmp/inc && git config core.worktree /tmp && \
            git config submodule.s.update '!\(e) subupdate' && git -C s config core.fsmonitor '\(e) subfsmonitor' && \
            printf '#!/bin/sh\\n\(e) hook\\n' > .git/hooks/post-checkout && chmod +x .git/hooks/post-checkout && echo planted
            """)
        #expect(plant.contains("planted"), "\(plant)")
        #expect(fingerprint(ws + "/.git") == before, "the host's config, hooks, module config and exclude are byte-identical")
        for command in ["git status", "git diff", "git log -p -2", "git submodule status", "git checkout -q -b x", "git checkout -q main"] {
            _ = try await GitFixture.sh(command, in: ws, env: env)
        }
        let ran = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("RAN-") }
        #expect(ran.isEmpty, "nothing planted ran on the host: \(ran)")

        // The one file the VM shares with host git: a submodule's pointer, redirected. Moved aside.
        let redirect = await run(manager, id, notes, ws, "git init -q --bare .evil && printf 'gitdir: ../.evil\\n' > s/.git && echo done")
        #expect(redirect.contains("moved it aside"), "\(redirect)")
        #expect(!FileManager.default.fileExists(atPath: ws + "/s/.git"))
    }

    @Test("in a linked worktree the VM's copy is found through the worktree's own .git file, and its commits reach that worktree's branch")
    func worktree() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git branch -m main && git worktree add -q -b wtb ../wt", in: dir + "/ws", env: env)
        let wt = dir + "/wt"
        let before = fingerprint(dir + "/ws/.git")
        let (manager, id, notes) = try await session(dir, workspace: wt)
        defer { Task { await manager.closeSession(id) } }
        let old = try await GitFixture.sh("git rev-parse wtb", in: wt, env: env).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = await run(manager, id, notes, wt, "echo w > w.txt && git add w.txt && git commit -qm w && git rev-parse --git-common-dir")
        #expect(r.contains(dir + "/ws/.git") || r.contains(IrisPaths.realPath(dir + "/ws/.git")), "\(r)")
        let new = try await GitFixture.sh("git rev-parse wtb", in: wt, env: env).out.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(new != old && notes.text.contains("Moved wtb"), "\(notes.text)")
        #expect(try await GitFixture.sh("git rev-parse main", in: dir + "/ws", env: env).out.trimmingCharacters(in: .whitespacesAndNewlines) != new,
                "the main checkout's branch did not move")
        #expect(fingerprint(dir + "/ws/.git") == before, "the host common dir's config and hooks are untouched")
    }
}
