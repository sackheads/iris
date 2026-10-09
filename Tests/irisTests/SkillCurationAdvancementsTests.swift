import Testing
import Foundation
@testable import IrisKit

@Suite("Skill Curation & Bundles Tests")
struct SkillCurationAdvancementsTests {

    @Test("SkillBundleManager creates, saves, lists, and retrieves skill bundles")
    func testSkillBundleManager() throws {
        let tempRoot = try tempDirectory(prefix: "iris-bundle-test")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let paths = IrisPaths(root: tempRoot)
        try paths.ensureDirectories()

        let bundle = SkillBundle(name: "writing-day", description: "Writing day tools", skillNames: ["humanizer", "ideation", "obsidian"])
        try SkillBundleManager.shared.saveBundle(bundle, paths: paths)

        let loaded = SkillBundleManager.shared.listBundles(paths: paths)
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "writing-day")
        #expect(loaded.first?.skillNames == ["humanizer", "ideation", "obsidian"])

        let fetched = SkillBundleManager.shared.getBundle(name: "writing-day", paths: paths)
        #expect(fetched != nil)
        #expect(fetched?.skillNames.contains("obsidian") == true)
    }

    @Test("JourneyManager builds timeline from frontmatter timestamps")
    func testJourneyManager() async throws {
        let tempRoot = try tempDirectory(prefix: "iris-journey-test")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let paths = IrisPaths(root: tempRoot)
        try paths.ensureDirectories()

        // Create sample skill with frontmatter
        let skillFolder = paths.skillsDir.appendingPathComponent("k8s-debug")
        try FileManager.default.createDirectory(at: skillFolder, withIntermediateDirectories: true)
        let skillContent = """
        ---
        name: k8s-debug
        description: Debug Kubernetes cluster issues
        type: skill
        timestamp: 2026-07-28T12:00:00Z
        ---

        # K8s Debug Steps
        1. kubectl get pods
        """
        try skillContent.write(to: skillFolder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let items = await JourneyManager.shared.buildTimeline(paths: paths)
        #expect(!items.isEmpty)
        let skillItem = items.first { $0.title.contains("k8s-debug") }
        #expect(skillItem != nil)
        #expect(skillItem?.category == "Skill")

        let markdown = JourneyManager.shared.formatTimelineMarkdown(items: items)
        #expect(markdown.contains("Iris Learning Journey Timeline"))
        #expect(markdown.contains("k8s-debug"))
    }

    @Test("SkillCurator scans skills, prunes empty ones, and outputs REPORT.md")
    func testSkillCurator() async throws {
        let tempRoot = try tempDirectory(prefix: "iris-curator-test")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let paths = IrisPaths(root: tempRoot)
        try paths.ensureDirectories()

        // Create 1 valid skill and 1 empty corrupt skill
        let validFolder = paths.skillsDir.appendingPathComponent("valid-skill")
        try FileManager.default.createDirectory(at: validFolder, withIntermediateDirectories: true)
        try "--- \nname: valid-skill\ndescription: Valid skill\n---\n\nValid body content here.".write(to: validFolder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let corruptFolder = paths.skillsDir.appendingPathComponent("corrupt-skill")
        try FileManager.default.createDirectory(at: corruptFolder, withIntermediateDirectories: true)
        try "".write(to: corruptFolder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let report = await SkillCurator.shared.curateSkills(paths: paths)
        #expect(report.totalSkillsScanned == 2)
        #expect(report.validSkillsCount == 1)
        #expect(report.prunedSkillsCount == 1)
        #expect(report.prunedSkillNames.contains("corrupt-skill"))

        let reportFile = paths.memoryDir.appendingPathComponent("curator/REPORT.md")
        #expect(FileManager.default.fileExists(atPath: reportFile.path))

        let trashDir = paths.memoryDir.appendingPathComponent("trash/skills")
        #expect(FileManager.default.fileExists(atPath: trashDir.path))

        let reportContent = try String(contentsOf: reportFile, encoding: .utf8)
        #expect(reportContent.contains("Iris Skill Curator Report"))
        #expect(reportContent.contains("corrupt-skill"))
    }

    @Test("SkillManager filters discoverSkills when activeBundle is set")
    func testSkillManagerSelectiveBundleFiltering() async throws {
        let tempRoot = try tempDirectory(prefix: "iris-discover-bundle-test")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let paths = IrisPaths(root: tempRoot)
        try paths.ensureDirectories()

        // Create 2 skills
        let s1 = paths.skillsDir.appendingPathComponent("humanizer")
        try FileManager.default.createDirectory(at: s1, withIntermediateDirectories: true)
        try "---\nname: humanizer\ndescription: Humanize text\n---\n\nBody 1".write(to: s1.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let s2 = paths.skillsDir.appendingPathComponent("k8s-debug")
        try FileManager.default.createDirectory(at: s2, withIntermediateDirectories: true)
        try "---\nname: k8s-debug\ndescription: K8s debug\n---\n\nBody 2".write(to: s2.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        // Without active bundle -> returns both
        let allPrompt = await SkillManager.shared.discoverSkills(paths: paths, activeBundle: nil)
        #expect(allPrompt.contains("humanizer"))
        #expect(allPrompt.contains("k8s-debug"))

        // With active bundle 'writing-day' (only humanizer) -> returns only humanizer
        let bundle = SkillBundle(name: "writing-day", description: "Writing day", skillNames: ["humanizer"])
        let bundlePrompt = await SkillManager.shared.discoverSkills(paths: paths, activeBundle: bundle)
        #expect(bundlePrompt.contains("humanizer"))
        #expect(!bundlePrompt.contains("k8s-debug"))
    }
}
