import Testing
import Foundation
@testable import iris

@Suite("SkillCreation Tests")
struct SkillCreationTests {

    @Test("createSkill creates directory, SKILL.md with OKF frontmatter, and body")
    func testCreateSkill() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-skill-test-\(UUID().uuidString)")
        let paths = IrisPaths(root: tempRoot)
        try paths.ensureDirectories()

        let skillName = "gke-debug-routine"
        let skillDesc = "Debug stuck GKE worker nodes"
        let skillBody = """
        # Steps
        1. Run `kubectl get nodes`
        2. Check `journalctl -u kubelet`
        """

        let result = await ToolExecutor.shared.createSkill(
            name: skillName,
            description: skillDesc,
            body: skillBody,
            paths: paths
        )

        #expect(result.contains("Successfully saved skill"))

        let skillFile = paths.skillsDir.appendingPathComponent("gke-debug-routine/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: skillFile.path))

        let content = try String(contentsOf: skillFile, encoding: .utf8)
        #expect(content.contains("name: gke-debug-routine"))
        #expect(content.contains("description: Debug stuck GKE worker nodes"))
        #expect(content.contains("type: skill"))
        #expect(content.contains("journalctl -u kubelet"))

        // Verify SkillManager discovers the new skill
        let skills = await SkillManager.shared.listSkills(paths: paths)
        #expect(skills.count == 1)
        #expect(skills.first?.name == "gke-debug-routine")
        #expect(skills.first?.description == skillDesc)
    }

    @Test("deleteSkill removes skill directory and file")
    func testDeleteSkill() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-skill-delete-\(UUID().uuidString)")
        let paths = IrisPaths(root: tempRoot)
        try paths.ensureDirectories()

        _ = await ToolExecutor.shared.createSkill(
            name: "temp-skill",
            description: "Temporary skill to delete",
            body: "Delete me",
            paths: paths
        )

        let deleteResult = await ToolExecutor.shared.deleteSkill(name: "temp-skill", paths: paths)
        #expect(deleteResult.contains("Successfully deleted skill"))

        let skillFolder = paths.skillsDir.appendingPathComponent("temp-skill")
        #expect(!FileManager.default.fileExists(atPath: skillFolder.path))
    }

    /// All three skill tools slug the name through one helper (`ToolExecutor.skillFolder(named:)`,
    /// #187 §4), so a delete finds what a create made. `deleteSkill` used to lowercase and trim
    /// without replacing spaces or underscores, which made `delete_skill("my skill")` report "not
    /// found" for a folder that was sitting right there.
    @Test("deleteSkill finds a skill whose name was slugged on the way in")
    func testDeleteSkillSlugsTheName() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-skill-slug-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let paths = IrisPaths(root: tempRoot)
        try paths.ensureDirectories()

        for (given, slug) in [("My Skill", "my-skill"), ("my_other_skill", "my-other-skill")] {
            _ = await ToolExecutor.shared.createSkill(name: given, description: "d", body: "b",
                                                      paths: paths)
            let folder = paths.skillsDir.appendingPathComponent(slug)
            #expect(FileManager.default.fileExists(atPath: folder.path),
                    Comment(rawValue: "createSkill slugged \(given) to \(slug)"))

            let result = await ToolExecutor.shared.deleteSkill(name: given, paths: paths)
            #expect(result.contains("Successfully deleted skill"), Comment(rawValue: given))
            #expect(!FileManager.default.fileExists(atPath: folder.path), Comment(rawValue: given))
        }
    }

    @Test("updateSkill modifies body/description while preserving skill name")
    func testUpdateSkill() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-skill-update-\(UUID().uuidString)")
        let paths = IrisPaths(root: tempRoot)
        try paths.ensureDirectories()

        _ = await ToolExecutor.shared.createSkill(
            name: "k8s-pod-debug",
            description: "Initial description",
            body: "Original body",
            paths: paths
        )

        let updateResult = await ToolExecutor.shared.updateSkill(
            name: "k8s-pod-debug",
            description: "Updated description",
            body: "Updated body content with new steps",
            paths: paths
        )

        #expect(updateResult.contains("Successfully updated skill"))

        let skillFile = paths.skillsDir.appendingPathComponent("k8s-pod-debug/SKILL.md")
        let content = try String(contentsOf: skillFile, encoding: .utf8)
        #expect(content.contains("description: Updated description"))
        #expect(content.contains("Updated body content with new steps"))
    }
}
