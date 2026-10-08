import Testing
import Foundation
@testable import IrisKit

@Suite("ShippedSkills Tests")
struct ShippedSkillsTests {

    private func tempPaths() -> IrisPaths {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-seed-\(UUID().uuidString)")
        return IrisPaths(root: root)
    }
    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test("seedIfNeeded seeds all shipped defaults from the bundle when absent")
    func testSeedsAllWhenAbsent() {
        let p = tempPaths(); defer { try? FileManager.default.removeItem(at: p.root) }
        ShippedSkills.seedIfNeeded(p)
        #expect(read(p.skillsDir.appendingPathComponent("library/SKILL.md"))?.contains("Library Management") == true)
        #expect(read(p.libraryDir.appendingPathComponent("README.md"))?.contains("Iris Library") == true)
        #expect(read(p.skillsDir.appendingPathComponent("external-libraries/SKILL.md"))?.contains("External Libraries") == true)
        #expect(read(p.libraryDir.appendingPathComponent("EXTERNAL_LIBRARIES.md"))?.contains("read-only → read-write → curated-by-iris → convert-to-okf") == true)
        #expect(read(p.skillsDir.appendingPathComponent("google-workspace/SKILL.md"))?.contains("Google Workspace") == true)
    }

    @Test("seedIfNeeded does not overwrite an existing (bot-edited) file")
    func testIdempotentNonDestructive() {
        let p = tempPaths(); defer { try? FileManager.default.removeItem(at: p.root) }
        try? p.ensureDirectories()
        let reg = p.libraryDir.appendingPathComponent("EXTERNAL_LIBRARIES.md")
        try? "MY REGISTRY".write(to: reg, atomically: true, encoding: .utf8)
        ShippedSkills.seedIfNeeded(p)
        #expect(read(reg) == "MY REGISTRY")
    }

    @Test("all bundled assets load and are non-empty")
    func testBundledAssetsLoad() {
        #expect(ShippedSkills.bundledText("library-SKILL").contains("Library Management"))
        #expect(ShippedSkills.bundledText("library-README").contains("Iris Library"))
        #expect(ShippedSkills.bundledText("external-libraries-SKILL").contains("External Libraries"))
        #expect(ShippedSkills.bundledText("external-libraries-REGISTRY").contains("Traits"))
        #expect(ShippedSkills.bundledText("google-workspace-SKILL").contains("Google Workspace"))
    }
}
