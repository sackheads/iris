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
        #expect(mount.source == c(t.proj), "the covering entry is chosen case-insensitively")
        #expect(t.grant.relativeComponents(of: upper, cwd: nil, under: mount) == ["out.md"], "and the walk starts at the granted root, so on any volume the write lands in the granted directory")
        #expect(!t.grant.allows(toolName: "write_file", details: t.base.appendingPathComponent("PROJECT/out.md").path, cwd: nil, sandboxed: false), "case-insensitive is not prefix-insensitive")
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
