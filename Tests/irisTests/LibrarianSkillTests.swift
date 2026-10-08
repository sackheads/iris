import Testing
import Foundation
@testable import IrisKit

@Suite("Librarian Skill Seeding & Discovery Tests")
struct LibrarianSkillTests {

    private func createTempPaths() throws -> (IrisPaths, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-librarian-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let paths = IrisPaths(root: tempDir)
        try paths.ensureDirectories()
        return (paths, tempDir)
    }

    @Test("ShippedSkills seeds librarian/SKILL.md if absent")
    func testShippedSkillsSeedsLibrarian() throws {
        let (paths, tempDir) = try createTempPaths()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let librarianFile = paths.skillsDir.appendingPathComponent("librarian/SKILL.md")
        #expect(!FileManager.default.fileExists(atPath: librarianFile.path))

        ShippedSkills.seedIfNeeded(paths)

        #expect(FileManager.default.fileExists(atPath: librarianFile.path))
        let content = try String(contentsOf: librarianFile, encoding: .utf8)
        #expect(content.contains("name: librarian"))
        #expect(content.contains("# Librarian — Workspace & File Organization"))
        #expect(content.contains("docs/specs/YYYY-MM-DD-feature-name.md"))
    }

    @Test("SkillManager discovers librarian skill after seeding")
    func testSkillManagerDiscoversLibrarian() async throws {
        let (paths, tempDir) = try createTempPaths()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        ShippedSkills.seedIfNeeded(paths)

        let skills = await SkillManager.shared.listSkills(paths: paths)
        let librarian = skills.first { $0.folderName == "librarian" || $0.name == "librarian" }
        #expect(librarian != nil)
        #expect(librarian?.description.contains("Organizes workspace files") == true)

        let body = await SkillManager.shared.readSkillBody(name: "librarian", paths: paths)
        #expect(body != nil)
        #expect(body?.contains("No Loose Root Files") == true)
    }
}
