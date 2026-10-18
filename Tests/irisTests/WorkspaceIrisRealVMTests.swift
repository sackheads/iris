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
