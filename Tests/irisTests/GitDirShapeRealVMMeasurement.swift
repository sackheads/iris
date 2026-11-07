import Testing
import Foundation
@testable import IrisKit

/// #907 premise check, NOT the fix: is the `.git`-shape skeleton (`objects/`, `refs/heads/`) that
/// #907's finding needs reachable from an unattended `run_command` in a read-write grant, or did
/// the finding assume a host step nobody can actually reach? #907's own measurement built the
/// skeleton by hand on the host, standing in for a VM `mkdir`, and said so was unverified. This is
/// that verification, not part of the gate's own test (which still needs writing once this is
/// answered). Opt-in like `SandboxRealVMTests` (`IRIS_REAL_VM=1`).
@Suite("git-dir skeleton reachability premise (#907)",
       .enabled(if: RealContainer.isAvailable, "opt-in: IRIS_REAL_VM=1, with the container runtime started and \(RealContainer.image) local"),
       .timeLimit(.minutes(2)))
struct GitDirShapeRealVMMeasurementTests {
    @Test("a run_command mkdir in the rw mount reaches the host, and WorkspaceGitDir sees the resulting shape")
    func skeletonReachableUnattended() async throws {
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("iris-907-vm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let host = IrisPaths.realPath(ws.path)
        defer { try? FileManager.default.removeItem(atPath: host) }

        let manager = SandboxSessionManager(runtime: RealContainer.runtime(), image: { RealContainer.image },
                                            gitGuard: GitConfigGuard(), paths: IrisPaths(root: ws.appendingPathComponent("iris-home")))
        let id = UUID()
        defer { Task { await manager.closeSession(id) } }

        // The run_command shape of #907's premise: no write_file, just a plain mkdir, as a planted
        // unattended request in a --grant-write job would issue.
        let out = await manager.run(command: "mkdir -p evil.git/objects evil.git/refs/heads && echo made",
                                    conversationId: id, workspace: ContainerMount(source: host), timeoutSeconds: 60)
        #expect(out.contains("made"), "mkdir did not report success in the VM: \(out)")

        var isDir: ObjCBool = false
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: host + "/evil.git/objects", isDirectory: &isDir) && isDir.boolValue,
                "objects/ did not reach the host at \(host)/evil.git/objects")
        #expect(fm.fileExists(atPath: host + "/evil.git/refs/heads", isDirectory: &isDir) && isDir.boolValue,
                "refs/heads/ did not reach the host at \(host)/evil.git/refs/heads")

        // #907's own premise, as it stood before this PR's fix: a write to evil.git/config with
        // objects/refs present but no HEAD yet. `WorkspaceGitDir.isGitPath` now refuses it
        // (`completesGitDirShape`); this is a premise check, not a regression test for that fix —
        // see GitDirHostWriteTests for the fix's own coverage.
        #expect(WorkspaceGitDir.isGitPath(host + "/evil.git/config", cwd: nil))
    }

    /// The planner's follow-up: `WorkspaceGitDir` is only ever consulted for `write_file`
    /// (`PermissionManager.writesGitDir`). Does an unattended `run_command` writing the same bytes
    /// via shell redirection land on the host directly, walking around that gate entirely? If so,
    /// a write_file-only fix closes one door while this one stays open.
    @Test("run_command shell redirection into config/HEAD reaches the host, with no gate in its way")
    func runCommandBypassesTheWriteFileGate() async throws {
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("iris-907-bypass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let host = IrisPaths.realPath(ws.path)
        defer { try? FileManager.default.removeItem(atPath: host) }

        let manager = SandboxSessionManager(runtime: RealContainer.runtime(), image: { RealContainer.image },
                                            gitGuard: GitConfigGuard(), paths: IrisPaths(root: ws.appendingPathComponent("iris-home")))
        let id = UUID()
        defer { Task { await manager.closeSession(id) } }

        let out = await manager.run(command: "mkdir -p evil.git/objects evil.git/refs/heads && echo '[core]\\n\\tfsmonitor = /tmp/evil.sh' > evil.git/config && printf 'ref: refs/heads/main\\n' > evil.git/HEAD && echo done",
                                    conversationId: id, workspace: ContainerMount(source: host), timeoutSeconds: 60)
        #expect(out.contains("done"), "command did not report success in the VM: \(out)")

        let configWrote = (try? String(contentsOfFile: host + "/evil.git/config", encoding: .utf8)) ?? ""
        let headWrote = (try? String(contentsOfFile: host + "/evil.git/HEAD", encoding: .utf8)) ?? ""
        #expect(configWrote.contains("fsmonitor"), "config did not land on the host via run_command redirection: got \(configWrote.debugDescription)")
        #expect(!headWrote.isEmpty, "HEAD did not land on the host via run_command redirection")
    }
}
