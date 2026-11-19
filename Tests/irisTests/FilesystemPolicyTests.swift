import Testing
import Foundation
@testable import IrisKit

/// #974 Task 8 (C5): the owner's `read_file`/`write_file` keep today's unrestricted host access;
/// a non-owner binding is confined to its `fsRoots` grant (empty grant = confined to nothing) and,
/// on top of that, is always denied a fixed set of credential/config stores on the host -- even
/// one of its granted roots cannot reach into them, and neither can a symlink or a `..` that
/// resolves there.
@Suite("FilesystemPolicy (#974 Task 8, C5)")
struct FilesystemPolicyTests {
    private func owner() -> AccessBinding { AccessBinding(profile: .owner, principal: .main, isOwner: true) }
    private func nonOwner(fsRoots: Set<String> = []) -> AccessBinding {
        AccessBinding(profile: AccessProfile(fsRoots: fsRoots), principal: .main, isOwner: false)
    }

    // MARK: resolve

    @Test("an owner binding is always unrestricted, whatever grant is passed")
    func ownerIsUnrestricted() {
        #expect(FilesystemPolicy.resolve(binding: owner(), grant: nil) == .unrestrictedOwner)
        #expect(FilesystemPolicy.resolve(binding: owner(), grant: JobGrant(mounts: [ContainerMount(source: "/tmp", target: "/tmp", readOnly: false)])) == .unrestrictedOwner)
    }

    @Test("a non-owner binding is confined, even with no grant at all (empty grant = confined to nothing)")
    func nonOwnerIsConfined() {
        #expect(FilesystemPolicy.resolve(binding: nonOwner(), grant: nil) == .confined(JobGrant()))
        let grant = JobGrant(mounts: [ContainerMount(source: "/tmp/work", target: "/tmp/work", readOnly: false)])
        #expect(FilesystemPolicy.resolve(binding: nonOwner(), grant: grant) == .confined(grant))
    }

    // MARK: the non-owner host-read denial set -- Review Focus 4

    private func withHome(_ body: (String) throws -> Void) rethrows {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("iris-fs-policy-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        try body(home)
    }

    @Test("a non-owner host read of a denied store is refused", arguments: [
        "/.git-credentials", "/.netrc", "/.ssh", "/.ssh/id_rsa", "/.config/gh", "/.config/gh/hosts.yml", "/.config", "/.iris", "/.iris-dev",
    ])
    func deniedStoresAreRefused(_ suffix: String) {
        withHome { home in
            #expect(FilesystemPolicy.deniesNonOwnerHostRead(home + suffix, home: home))
        }
    }

    @Test("an ordinary path outside every denied store is not refused by this rule")
    func ordinaryPathIsNotDenied() {
        withHome { home in
            #expect(!FilesystemPolicy.deniesNonOwnerHostRead(home + "/Documents/notes.txt", home: home))
            #expect(!FilesystemPolicy.deniesNonOwnerHostRead("/tmp/work/file.txt", home: home))
        }
    }

    /// Review Focus 4, the security-critical case: a symlink that LOOKS like an ordinary path but
    /// resolves into a denied store must be caught -- the denial compares resolved (canonical)
    /// paths, never the raw spelling.
    @Test("a symlink into a denied store is refused, not just the store's own spelling")
    func symlinkIntoDeniedStoreIsRefused() throws {
        try withHome { home in
            let credStore = home + "/.config/gh"
            try FileManager.default.createDirectory(atPath: credStore, withIntermediateDirectories: true)
            try "token: secret".write(toFile: credStore + "/hosts.yml", atomically: true, encoding: .utf8)
            let decoy = home + "/Documents"
            try FileManager.default.createDirectory(atPath: decoy, withIntermediateDirectories: true)
            let link = decoy + "/notes.txt"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: credStore + "/hosts.yml")

            #expect(FilesystemPolicy.deniesNonOwnerHostRead(link, home: home),
                    "a symlink that resolves into the denied store must be refused, not treated as an ordinary file under Documents")
        }
    }

    /// Review Focus 4, the second case the planner named: a `..`-containing path that walks out of
    /// an apparently-safe directory and into a denied store.
    @Test("a `..`-containing path that walks into a denied store is refused")
    func dotDotIntoDeniedStoreIsRefused() throws {
        try withHome { home in
            let credStore = home + "/.ssh"
            try FileManager.default.createDirectory(atPath: credStore, withIntermediateDirectories: true)
            try "key material".write(toFile: credStore + "/id_rsa", atomically: true, encoding: .utf8)
            let viaDotDot = home + "/Documents/../.ssh/id_rsa"

            #expect(FilesystemPolicy.deniesNonOwnerHostRead(viaDotDot, home: home))
        }
    }

    @Test("the denial is case-insensitive, matching the rest of this codebase's path comparisons")
    func caseInsensitive() {
        withHome { home in
            #expect(FilesystemPolicy.deniesNonOwnerHostRead(home + "/.SSH/id_rsa", home: home))
        }
    }

    // MARK: wired into ToolExecutor.execute (the "today it is host-always" fix)

    private func tree() throws -> (base: URL, allowed: URL, outside: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("iris-fs-policy-exec-\(UUID().uuidString)")
        let allowed = base.appendingPathComponent("allowed")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return (base, allowed, outside)
    }

    @Test("read_file is confined to the fsRoots grant for a non-owner, with no sandboxGrant and !isBackground -- today it is host-always")
    func readFileConfinedForNonOwner() async throws {
        let (base, allowed, outside) = try tree()
        defer { try? FileManager.default.removeItem(at: base) }
        try "inside".write(to: allowed.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try "outside".write(to: outside.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
        let policy = FilesystemPolicy.resolve(binding: nonOwner(), grant: JobGrant(mounts: [ContainerMount(source: allowed.path)]))

        let insideResult = await ToolExecutor().execute(name: "read_file", args: ["path": .string(allowed.appendingPathComponent("x.txt").path)], filesystemPolicy: policy)
        #expect(insideResult.contains("inside"))

        let outsideResult = await ToolExecutor().execute(name: "read_file", args: ["path": .string(outside.appendingPathComponent("y.txt").path)], filesystemPolicy: policy)
        #expect(!outsideResult.contains("outside"), "a non-owner must not read outside its fsRoots grant: \(outsideResult)")
    }

    @Test("read_file is refused outright for a non-owner with an empty fsRoots grant")
    func readFileRefusedWithEmptyGrant() async throws {
        let (base, allowed, _) = try tree()
        defer { try? FileManager.default.removeItem(at: base) }
        try "secret".write(to: allowed.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let policy = FilesystemPolicy.resolve(binding: nonOwner(), grant: nil)

        let result = await ToolExecutor().execute(name: "read_file", args: ["path": .string(allowed.appendingPathComponent("x.txt").path)], filesystemPolicy: policy)
        #expect(!result.contains("secret"))
    }

    @Test("read_file is unaffected for an owner binding, same path, same policy resolution")
    func readFileUnaffectedForOwner() async throws {
        let (base, allowed, _) = try tree()
        defer { try? FileManager.default.removeItem(at: base) }
        try "owner content".write(to: allowed.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let policy = FilesystemPolicy.resolve(binding: owner(), grant: nil)

        let result = await ToolExecutor().execute(name: "read_file", args: ["path": .string(allowed.appendingPathComponent("x.txt").path)], filesystemPolicy: policy)
        #expect(result.contains("owner content"))
    }

    @Test("a non-owner's read_file is denied for a credential store even if it sits inside the fsRoots grant")
    func deniedStoreWinsEvenInsideTheGrant() async throws {
        let (base, allowed, _) = try tree()
        defer { try? FileManager.default.removeItem(at: base) }
        let ghDir = allowed.appendingPathComponent(".config/gh")
        try FileManager.default.createDirectory(at: ghDir, withIntermediateDirectories: true)
        try "token".write(to: ghDir.appendingPathComponent("hosts.yml"), atomically: true, encoding: .utf8)
        let policy = FilesystemPolicy.resolve(binding: nonOwner(), grant: JobGrant(mounts: [ContainerMount(source: allowed.path)]))

        let result = await ToolExecutor().execute(name: "read_file", args: ["path": .string(ghDir.appendingPathComponent("hosts.yml").path)],
                                                    filesystemPolicy: policy, home: allowed.path)
        #expect(!result.contains("token"))
    }

    @Test("write_file is confined to the fsRoots grant for a non-owner, and denied for a credential store")
    func writeFileConfinedForNonOwner() async throws {
        let (base, allowed, outside) = try tree()
        defer { try? FileManager.default.removeItem(at: base) }
        let policy = FilesystemPolicy.resolve(binding: nonOwner(), grant: JobGrant(mounts: [ContainerMount(source: allowed.path)]))

        let insideResult = await ToolExecutor().execute(name: "write_file",
                                                          args: ["path": .string(allowed.appendingPathComponent("x.txt").path), "content": .string("hi")],
                                                          filesystemPolicy: policy)
        #expect(insideResult.contains("Successfully wrote"), Comment(rawValue: insideResult))

        let outsideResult = await ToolExecutor().execute(name: "write_file",
                                                           args: ["path": .string(outside.appendingPathComponent("y.txt").path), "content": .string("hi")],
                                                           filesystemPolicy: policy)
        #expect(!outsideResult.contains("Successfully wrote"), Comment(rawValue: outsideResult))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("y.txt").path))
    }
}
