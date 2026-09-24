import Testing
import Foundation
@testable import iris

/// #282 §0.13 — the descriptor walk. Temp directories only; every "outside" is a sibling temp dir
/// the test checks stayed empty.
@Suite("Granted writes go through a descriptor walk (#282)")
struct GrantedWriteTests {
    struct Tree {
        let base: URL; let root: URL; let outside: URL
        func tearDown() { try? FileManager.default.removeItem(at: base) }
        var access: GrantedFileAccess { GrantedFileAccess(root: root.path) }
        func names(_ dir: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? [] }
    }

    private func tree() throws -> Tree {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-gwalk-\(UUID().uuidString)")
        let root = base.appendingPathComponent("mount"), outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        return Tree(base: base, root: root, outside: outside)
    }

    @Test("a write through the walk lands, atomically, with no staging file left behind; a second write replaces")
    func writeLands() throws {
        let t = try tree(); defer { t.tearDown() }
        try t.access.write(relative: ["sub", "x.md"], content: "one")
        #expect(try String(contentsOf: t.root.appendingPathComponent("sub/x.md"), encoding: .utf8) == "one")
        #expect(t.names(t.root.appendingPathComponent("sub")) == ["x.md"], "the staging file was renamed away, not left")
        try t.access.write(relative: ["sub", "x.md"], content: "two")
        #expect(try String(contentsOf: t.root.appendingPathComponent("sub/x.md"), encoding: .utf8) == "two")
        try t.access.write(relative: ["top.md"], content: "")
        #expect(try String(contentsOf: t.root.appendingPathComponent("top.md"), encoding: .utf8) == "")
    }

    @Test("a symlink as an intermediate component is refused, and nothing lands outside")
    func intermediateSymlinkRefused() throws {
        let t = try tree(); defer { t.tearDown() }
        try FileManager.default.createSymbolicLink(at: t.root.appendingPathComponent("link"), withDestinationURL: t.outside)
        #expect(throws: GrantedFileError.symlink(component: "link")) {
            try t.access.write(relative: ["link", "x.md"], content: "leak")
        }
        #expect(t.names(t.outside).isEmpty)
        #expect(throws: GrantedFileError.symlink(component: "link")) { _ = try t.access.read(relative: ["link", "x.md"]) }
    }

    @Test("a symlink as the final component is refused rather than followed or replaced")
    func finalSymlinkRefused() throws {
        let t = try tree(); defer { t.tearDown() }
        let target = t.outside.appendingPathComponent("target.md")
        try "keep".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: t.root.appendingPathComponent("out.md"), withDestinationURL: target)
        #expect(throws: GrantedFileError.symlink(component: "out.md")) {
            try t.access.write(relative: ["out.md"], content: "leak")
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect(t.names(t.root) == ["out.md", "sub"], "the link itself is left where it was")
        #expect(throws: GrantedFileError.symlink(component: "out.md")) { _ = try t.access.read(relative: ["out.md"]) }
        // A directory where a file was named is refused with its own sentence (L2) before anything is staged.
        #expect(throws: GrantedFileError.isADirectory(component: "sub")) { try t.access.write(relative: ["sub"], content: "x") }
        #expect(t.names(t.root) == ["out.md", "sub"])
    }

    @Test("a component swapped for a symlink after the allow and before the write is refused (the §0.13 race)")
    func swapAfterAllowRefused() throws {
        let t = try tree(); defer { t.tearDown() }
        // The allow, as the dispatcher makes it: the path is judged, `sub` is a real directory.
        let sub = t.root.appendingPathComponent("sub")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: sub.path, isDirectory: &isDir) && isDir.boolValue)
        // The swap, as a background `cmd &` in the container would make it on the identity-mapped mount.
        try FileManager.default.removeItem(at: sub)
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: t.outside)
        // The write, with the components decided before the swap.
        #expect(throws: GrantedFileError.symlink(component: "sub")) {
            try t.access.write(relative: ["sub", "x.md"], content: "leak")
        }
        #expect(t.names(t.outside).isEmpty)
    }

    @Test("the staging file is created inside the final directory's descriptor, exclusively, and matches the watches' sibling rule")
    func stagingStaysInside() throws {
        let t = try tree(); defer { t.tearDown() }
        let staging = GrantedFileAccess.defaultStagingName("x.md")
        #expect(staging.hasPrefix("x.md.sb-"))
        #expect(RecentWrites.isAtomicTempSibling(staging, of: "x.md"), "a watch absorbs the staging file as the run's own write")
        // A fixed staging name that already exists: O_EXCL refuses, and the existing file is untouched.
        let fixed = GrantedFileAccess(root: t.root.path, stagingName: { _ in "x.md.sb-fixed" })
        try "occupied".write(to: t.root.appendingPathComponent("sub/x.md.sb-fixed"), atomically: true, encoding: .utf8)
        #expect(throws: GrantedFileError.stagingExists("x.md.sb-fixed")) {
            try fixed.write(relative: ["sub", "x.md"], content: "new")
        }
        #expect(try String(contentsOf: t.root.appendingPathComponent("sub/x.md.sb-fixed"), encoding: .utf8) == "occupied")
        #expect(!FileManager.default.fileExists(atPath: t.root.appendingPathComponent("sub/x.md").path))
        // A root that is itself a symlink is refused by step 2 of the root open (its real path does
        // not canonicalise back to the stored spelling), naming the swapped component.
        let linkRoot = t.base.appendingPathComponent("rootlink")
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: t.root)
        #expect(throws: GrantedFileError.symlink(component: "rootlink")) {
            try GrantedFileAccess(root: linkRoot.path).write(relative: ["y.md"], content: "x")
        }
    }

    @Test("the walk refuses .., ., empty and slash-bearing components itself, before any syscall (H2)")
    func dotDotRefusedByTheWalk() throws {
        let t = try tree(); defer { t.tearDown() }
        // Measured without the guard: `..` is a real directory entry, `openat(O_DIRECTORY|O_NOFOLLOW)` opens it,
        // and esc.md lands outside the root. The guard is the walk's own; it does not rely on the allow having run.
        #expect(throws: GrantedFileError.badComponent("..")) { try t.access.write(relative: ["..", "outside", "esc.md"], content: "leak") }
        #expect(throws: GrantedFileError.badComponent("..")) { try t.access.write(relative: ["sub", "..", "x.md"], content: "leak") }
        #expect(throws: GrantedFileError.badComponent("..")) { _ = try t.access.read(relative: ["..", "outside", "esc.md"]) }
        #expect(throws: GrantedFileError.badComponent(".")) { try t.access.write(relative: [".", "x.md"], content: "x") }
        #expect(throws: GrantedFileError.badComponent("")) { try t.access.write(relative: ["", "x.md"], content: "x") }
        #expect(throws: GrantedFileError.badComponent("a/b")) { try t.access.write(relative: ["a/b"], content: "x") }
        #expect(t.names(t.outside).isEmpty)
        #expect(t.names(t.root) == ["sub"], "nothing was created at all")
    }

    @Test("a nested mount root is reached by the same walk: an intermediate of the root swapped for a link is refused (M2)")
    func nestedRootIntermediateSwapRefused() throws {
        let t = try tree(); defer { t.tearDown() }
        // The grant's inner entry is `mount/inner/leaf`; `mount/` is read-write, so a command can rename `inner`.
        let leaf = t.root.appendingPathComponent("inner/leaf")
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: t.outside.appendingPathComponent("leaf"), withIntermediateDirectories: true)
        let access = GrantedFileAccess(root: leaf.path)
        try access.write(relative: ["ok.md"], content: "in")            // before the swap: lands
        try FileManager.default.removeItem(at: t.root.appendingPathComponent("inner"))
        try FileManager.default.createSymbolicLink(at: t.root.appendingPathComponent("inner"), withDestinationURL: t.outside)
        // Measured: `open(root, O_DIRECTORY|O_NOFOLLOW)` followed `inner` and z.md landed in outside/leaf.
        // Now: realpath(root) = …/outside/leaf, whose canonical form is not the stored root → refused at `inner`.
        #expect(throws: GrantedFileError.symlink(component: "inner")) { try access.write(relative: ["z.md"], content: "leak") }
        #expect(throws: GrantedFileError.symlink(component: "inner")) { _ = try access.read(relative: ["ok.md"]) }
        #expect(t.names(t.outside.appendingPathComponent("leaf")).isEmpty)
    }

    @Test("a root under the system symlinks — /var/folders, /tmp — opens and writes, staging inside (N-H1)")
    func rootUnderTmpIsWalkable() throws {
        // Every root in this suite lives under NSTemporaryDirectory() (`/var/folders/…`, and `/var` is a
        // symlink to `/private/var`), so the suite itself proves the firmlink case; this test says so
        // out loud and adds the `/tmp` spelling the Verification demo uses.
        let t = try tree(); defer { t.tearDown() }
        #expect(t.root.path.hasPrefix("/var/") || t.root.path.hasPrefix("/private/var/"))
        #expect(IrisPaths.canonicalPath(t.root.path) == t.root.path, "the stored (canonical) spelling is what the walk is handed")
        try t.access.write(relative: ["sub", "tmp.md"], content: "ok")
        #expect(try t.access.read(relative: ["sub", "tmp.md"]) == "ok")
        #expect(t.names(t.root.appendingPathComponent("sub")) == ["tmp.md"])

        let tmp = URL(fileURLWithPath: "/tmp").appendingPathComponent("iris-gwalk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let stored = IrisPaths.canonicalPath(tmp.path)
        #expect(stored.hasPrefix("/tmp/"), "canonicalPath strips /private (measured)")
        try GrantedFileAccess(root: stored).write(relative: ["hello.md"], content: "demo")
        #expect(try String(contentsOf: tmp.appendingPathComponent("hello.md"), encoding: .utf8) == "demo")

        // A root that no longer resolves is its own refusal, not a symlink sentence.
        try FileManager.default.removeItem(at: tmp)
        #expect(throws: GrantedFileError.rootUnavailable(stored)) { try GrantedFileAccess(root: stored).write(relative: ["x"], content: "x") }
    }

    @Test("read_file walks the same way: content back, a missing file named, no descent through a link")
    func readThroughTheWalk() throws {
        let t = try tree(); defer { t.tearDown() }
        try "hello".write(to: t.root.appendingPathComponent("sub/r.md"), atomically: true, encoding: .utf8)
        #expect(try t.access.read(relative: ["sub", "r.md"]) == "hello")
        #expect(throws: GrantedFileError.missing(component: "gone.md")) { _ = try t.access.read(relative: ["sub", "gone.md"]) }
        #expect(throws: GrantedFileError.missing(component: "nodir")) { _ = try t.access.read(relative: ["nodir", "r.md"]) }
        #expect(throws: GrantedFileError.notADirectory(component: "r.md")) { _ = try t.access.read(relative: ["sub", "r.md", "deeper"]) }
        #expect(throws: GrantedFileError.emptyPath) { _ = try t.access.read(relative: []) }
    }

    @Test("read refuses a directory and a FIFO with their own sentences, and the FIFO answer comes back promptly")
    func readRefusesNonRegularFiles() async throws {
        let t = try tree(); defer { t.tearDown() }
        #expect(throws: GrantedFileError.isADirectory(component: "sub")) { _ = try t.access.read(relative: ["sub"]) }
        // Measured by review: a plain `open(O_RDONLY)` of a FIFO blocks until a writer appears, which
        // would park a job's run on the watchdog. The walk opens `O_NONBLOCK`, asks `fstat`, and refuses.
        let fifo = t.root.appendingPathComponent("sub/pipe")
        #expect(mkfifo(fifo.path, 0o644) == 0)
        enum Outcome: Equatable { case threw(GrantedFileError), readBack, timedOut }
        let access = t.access
        let (outcomes, sink) = AsyncStream<Outcome>.makeStream()
        Task.detached {
            do { _ = try access.read(relative: ["sub", "pipe"]); sink.yield(.readBack) }
            catch let error as GrantedFileError { sink.yield(.threw(error)) }
            catch { sink.yield(.readBack) }
        }
        Task.detached { try? await Task.sleep(for: .seconds(5)); sink.yield(.timedOut) }
        var first: Outcome = .timedOut
        for await outcome in outcomes { first = outcome; break }
        #expect(first == .threw(.notARegularFile(component: "pipe")))
    }

    @Test("a root spelled with one trailing slash is walked as its canonical spelling, as relativeComponents reads it")
    func trailingSlashRootIsWalked() throws {
        let t = try tree(); defer { t.tearDown() }
        try GrantedFileAccess(root: t.root.path + "/").write(relative: ["slash.md"], content: "ok")
        #expect(try String(contentsOf: t.root.appendingPathComponent("slash.md"), encoding: .utf8) == "ok")
        #expect(try GrantedFileAccess(root: t.root.path + "/").read(relative: ["slash.md"]) == "ok")
    }

    @Test("the executor's granted pair return the tool's sentences, and execute(grantedMount:) routes to them")
    func executorRoutesToTheWalk() async throws {
        let t = try tree(); defer { t.tearDown() }
        let executor = ToolExecutor()
        let mount = ContainerMount(source: t.root.path)
        let grant = JobGrant(mounts: [mount])
        let target = t.root.appendingPathComponent("sub/e.md").path
        let wrote = await executor.execute(name: "write_file", args: ["path": .string(target), "content": .string("via walk")],
                                           cwd: t.root.path, grant: grant, grantedMount: mount)
        #expect(wrote == "Successfully wrote to \(target)", "the sentence writtenPaths reads, so the self-write filter is fed as before")
        #expect(try String(contentsOf: URL(fileURLWithPath: target), encoding: .utf8) == "via walk")
        #expect(await executor.execute(name: "read_file", args: ["path": .string("sub/e.md")], cwd: t.root.path,
                                       grant: grant, grantedMount: mount) == "via walk")

        // A path a hook rewrote out from under the decided mount is refused, never re-routed to Foundation.
        // (`execute` receives the hook layer's `execArgs` — iris.swift:3249 — so this IS the post-hook path;
        // `HookManager.shared` is process-global and is not driven from a test, invariant 7.)
        let elsewhere = t.outside.appendingPathComponent("h.md").path
        #expect(await executor.execute(name: "write_file", args: ["path": .string(elsewhere), "content": .string("x")],
                                       cwd: t.root.path, grant: grant, grantedMount: mount)
                == ToolExecutor.notUnderGrantedDirectory(t.root.path))
        // …including one that is spelled under the mount and climbs out with `..` (H2).
        #expect(await executor.execute(name: "write_file", args: ["path": .string(t.root.path + "/../outside/h.md"), "content": .string("x")],
                                       cwd: t.root.path, grant: grant, grantedMount: mount)
                == ToolExecutor.notUnderGrantedDirectory(t.root.path))
        #expect(t.names(t.outside).isEmpty)

        // A granted conversation whose decision was nil: refused, never Foundation (H1 — the invariant).
        let inside = t.root.appendingPathComponent("sub/undecided.md").path
        #expect(await executor.execute(name: "write_file", args: ["path": .string(inside), "content": .string("x")],
                                       cwd: t.root.path, grant: grant, grantedMount: nil)
                == ToolExecutor.notDecidedInsideGrant("write_file"))
        #expect(await executor.execute(name: "read_file", args: ["path": .string(inside)], cwd: t.root.path, grant: grant, grantedMount: nil)
                == ToolExecutor.notDecidedInsideGrant("read_file"))
        #expect(!FileManager.default.fileExists(atPath: inside))

        // Through a link inside the mount: the walk's sentence, not a write.
        try FileManager.default.createSymbolicLink(at: t.root.appendingPathComponent("link"), withDestinationURL: t.outside)
        let viaLink = await executor.execute(name: "write_file", args: ["path": .string("link/x.md"), "content": .string("x")],
                                             cwd: t.root.path, grant: grant, grantedMount: mount)
        #expect(viaLink == "Error writing file: \(GrantedFileError.symlink(component: "link").message)")

        // No decided mount: today's Foundation path, unchanged (an attended call, or an approved/allowlisted one).
        let plain = await executor.execute(name: "write_file", args: ["path": .string(elsewhere), "content": .string("plain")], cwd: nil)
        #expect(plain == "Successfully wrote to \(elsewhere)")
    }
}
