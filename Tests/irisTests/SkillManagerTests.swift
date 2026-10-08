import Testing
import Foundation
@testable import IrisKit

@Suite("SkillManager Tests")
struct SkillManagerTests {

    private func tempPaths(_ setup: (IrisPaths) -> Void) -> IrisPaths {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-skills-\(UUID().uuidString)")
        let p = IrisPaths(root: root)
        try? p.ensureDirectories()
        setup(p)
        return p
    }

    // Regression: first-party skill files must NOT be run through the untrusted-data guard,
    // which strips the `---` OKF frontmatter delimiters so `description:` never parses.
    @Test("discoverSkills surfaces the OKF description (frontmatter not stripped)")
    func testDiscoverSurfacesDescription() async {
        let okf = """
        ---
        type: skill
        title: Library Management
        description: Maintain your permanent OKF library.
        tags: [library]
        timestamp: 2026-07-15
        ---

        # Library Management
        Body.
        """
        let p = tempPaths { p in
            let dir = p.skillsDir.appendingPathComponent("library")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? okf.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        let summary = await SkillManager.shared.discoverSkills(paths: p)
        #expect(summary.contains("Maintain your permanent OKF library."))
        #expect(!summary.contains("No description provided"))
        // OKF uses `title:` (not `name:`); discovery should display it rather than the folder.
        #expect(summary.contains("## Skill: Library Management"))
    }

    // Regression: SOUL is the persona; it must be returned raw, not wrapped in
    // <untrusted_context> (the tag SYSTEM.md instructs the model to ignore).
    @Test("loadSOUL returns the raw persona, not wrapped as untrusted")
    func testLoadSoulRaw() async {
        let p = tempPaths { p in
            try? "You are Iris. Be warm and direct.".write(to: p.soulMd, atomically: true, encoding: .utf8)
        }
        let soul = await SkillManager.shared.loadSOUL(paths: p)
        #expect(soul == "You are Iris. Be warm and direct.")
        #expect(!soul.contains("<untrusted_context"))
    }

    @Test("loadCustomRules auto-loads rules and ignores hidden files")
    func testLoadCustomRules() async {
        let p = tempPaths { p in
            try? "Rule content 1".write(to: p.rulesDir.appendingPathComponent("01_rule.md"), atomically: true, encoding: .utf8)
            try? "DS_Store binary noise".write(to: p.rulesDir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        }
        let rules = await SkillManager.shared.loadCustomRules(paths: p)
        #expect(rules.contains("# Rule: 01_rule.md"))
        #expect(rules.contains("Rule content 1"))
        #expect(!rules.contains(".DS_Store"))
    }
}
