import Testing
import Foundation
@testable import iris

/// #284. `skillFolder(named:)` slugged a name — lowercase, trim, spaces and underscores to dashes
/// — and appended it to `skillsDir` without ever refusing `..`, `/` or an empty result. The slug
/// leaves `..` and `/` untouched, so the three skill tools could act outside the skills directory.
///
/// Measured before the fix, against `~/.iris/skills`:
///
///     "../../x"  -> /Users/me/x
///     "../evil"  -> /Users/me/.iris/evil
///     ".."       -> /Users/me/.iris        <- delete_skill removes the whole Iris directory
///     ""         -> /Users/me/.iris/skills <- delete_skill removes every skill
///
/// Temp `IrisPaths` throughout: a test that can delete `~/.iris` must never be pointed at it
/// (invariant 7).
@Suite("Skill names cannot escape the skills directory (#284)")
struct SkillFolderTraversalTests {

    private func tempPaths() throws -> IrisPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-284-\(UUID().uuidString)", isDirectory: true)
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()
        return paths
    }

    /// Every spelling that resolved outside the skills directory, plus the two that resolved *to*
    /// it — an empty slug and a bare `..` are the ones that cost a whole tree rather than one folder.
    @Test("a name that resolves outside the skills directory, or to it, is refused")
    func traversalRefused() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        for name in ["../../x", "../evil", "..", "", "   ", "a/../../b", "../", "./..",
                     "/etc/passwd", "nested/skill", ".", " . "] {
            #expect(ToolExecutor.skillFolder(named: name, paths: paths) == nil,
                    "\(name.debugDescription) must not produce a folder")
        }
    }

    @Test("an ordinary name still resolves, slugged as before")
    func ordinaryNamesStillWork() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        #expect(ToolExecutor.skillFolder(named: "My Skill", paths: paths)?.lastPathComponent == "my-skill")
        #expect(ToolExecutor.skillFolder(named: "  under_score  ", paths: paths)?.lastPathComponent == "under-score")
        #expect(ToolExecutor.skillFolder(named: "ok-skill", paths: paths)?.path
                == paths.skillsDir.appendingPathComponent("ok-skill").path)
    }

    /// The consequence that matters: the tool refuses rather than removing the tree. Asserted on
    /// the filesystem, not only on the sentence, because the sentence is not what does the damage.
    @Test("delete_skill with a traversing name removes nothing and says so")
    func deleteRefusesAndRemovesNothing() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let victim = paths.root.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let realSkill = paths.skillsDir.appendingPathComponent("keeper", isDirectory: true)
        try FileManager.default.createDirectory(at: realSkill, withIntermediateDirectories: true)

        let executor = ToolExecutor()
        for name in ["..", "../memory", "", "."] {
            let result = await executor.deleteSkill(name: name, paths: paths)
            #expect(result.lowercased().contains("not a valid skill name"), "got: \(result)")
        }
        #expect(FileManager.default.fileExists(atPath: victim.path), "~/.iris/memory equivalent survived")
        #expect(FileManager.default.fileExists(atPath: paths.skillsDir.path), "the skills directory survived")
        #expect(FileManager.default.fileExists(atPath: realSkill.path), "an unrelated skill survived")
    }

    /// Review finding: `standardizedFileURL` strips a leading `/private` only when the path exists,
    /// so a root spelled that way made the guard compare `/tmp/...` against `/private/tmp/...` and
    /// refuse every *new* name while letting updates through. `/private/tmp` is a real root —
    /// `TMPDIR=/private/tmp`, the perf lane's volatile copy — so this is not a hypothetical spelling.
    @Test("an ordinary new name resolves under a root spelled through /private")
    func privateSpelledRootAccepts() throws {
        let root = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("iris-284-\(UUID().uuidString)", isDirectory: true)
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(paths.skillsDir.path.hasPrefix("/private/"), "the fixture must keep the spelling under test")
        #expect(ToolExecutor.skillFolder(named: "brand-new", paths: paths) != nil,
                "a new skill under a /private-spelled root must resolve")
        #expect(ToolExecutor.skillFolder(named: "..", paths: paths) == nil, "and the refusals still hold")
        #expect(ToolExecutor.skillFolder(named: ".", paths: paths) == nil)
    }

    @Test("create_skill and update_skill refuse a traversing name and write nothing outside")
    func writesRefused() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let executor = ToolExecutor()

        // `.` and `""` are in here as well as in the delete test: their damage on a write is a
        // `SKILL.md` dropped into the skills directory itself rather than into a skill's folder.
        for name in ["../escaped", ".", ""] {
            let created = await executor.createSkill(name: name, description: "d", body: "b", paths: paths)
            #expect(created.lowercased().contains("not a valid skill name"), "create \(name.debugDescription): \(created)")
            let updated = await executor.updateSkill(name: name, description: "d", body: "b", paths: paths)
            #expect(updated.lowercased().contains("not a valid skill name"), "update \(name.debugDescription): \(updated)")
        }
        #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("escaped").path))
        #expect(!FileManager.default.fileExists(atPath: paths.skillsDir.appendingPathComponent("SKILL.md").path),
                "nothing may land in the skills directory itself")
    }
}
