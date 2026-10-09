import Testing
import Foundation
@testable import IrisKit

/// #417: `create_skill`/`update_skill` can now write the `title`/`tags` OKF frontmatter that
/// `/reflect` grooming (AppState.swift) and SYSTEM.md's Memory Formatting section ask every
/// skill to carry, closing the gap that pushed the model to `write_file` instead. Each test here
/// uses its own `IrisPaths(root:)` over a temp directory (invariant 7) — never `~/.iris`.
@Suite("Skill tool frontmatter (#417)")
struct SkillToolFrontmatterTests {
    private func tempPaths() throws -> IrisPaths {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-skill-fm-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()
        return paths
    }

    @Test("create_skill with title and tags writes that frontmatter")
    func createSkillWritesTitleAndTags() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let result = await ToolExecutor.shared.createSkill(
            name: "gke-debug",
            description: "Debug stuck GKE worker nodes",
            body: "1. Run kubectl get nodes",
            title: "GKE Node Debugging",
            tags: ["kubernetes", "gcp"],
            paths: paths
        )
        #expect(result.contains("Successfully saved skill"))

        let content = try String(contentsOf: paths.skillsDir.appendingPathComponent("gke-debug/SKILL.md"), encoding: .utf8)
        #expect(content.contains("title: GKE Node Debugging"))
        #expect(content.contains("tags: [\"kubernetes\", \"gcp\"]"))
        #expect(content.contains("name: gke-debug"))
        #expect(content.contains("description: Debug stuck GKE worker nodes"))
    }

    @Test("create_skill without title or tags omits those frontmatter lines")
    func createSkillOmitsUnsetFields() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        _ = await ToolExecutor.shared.createSkill(name: "plain-skill", description: "d", body: "b", paths: paths)
        let content = try String(contentsOf: paths.skillsDir.appendingPathComponent("plain-skill/SKILL.md"), encoding: .utf8)
        #expect(!content.contains("title:"))
        #expect(!content.contains("tags:"))
    }

    @Test("update_skill keeps title and tags it wasn't given")
    func updateSkillPreservesUnmentionedFields() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        _ = await ToolExecutor.shared.createSkill(
            name: "k8s-pod-debug", description: "Initial description", body: "Original body",
            title: "Pod Debugging", tags: ["kubernetes", "debugging"], paths: paths
        )

        // Updates only the body; title/tags are not named in this call.
        let result = await ToolExecutor.shared.updateSkill(
            name: "k8s-pod-debug", description: nil, body: "Updated body content", paths: paths
        )
        #expect(result.contains("Successfully updated skill"))

        let content = try String(contentsOf: paths.skillsDir.appendingPathComponent("k8s-pod-debug/SKILL.md"), encoding: .utf8)
        #expect(content.contains("title: Pod Debugging"), "title survives an update that doesn't mention it")
        #expect(content.contains("tags: [\"kubernetes\", \"debugging\"]"), "tags survive an update that doesn't mention it")
        #expect(content.contains("description: Initial description"), "description survives too, since this call didn't change it")
        #expect(content.contains("Updated body content"))
    }

    @Test("update_skill changes title/tags only when given, leaving the other and description alone")
    func updateSkillChangesOnlyGivenFields() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        _ = await ToolExecutor.shared.createSkill(
            name: "deploy-recipe", description: "Deploy the service", body: "Steps",
            title: "Deploy Recipe", tags: ["deploy"], paths: paths
        )

        let result = await ToolExecutor.shared.updateSkill(
            name: "deploy-recipe", description: nil, body: nil, title: nil, tags: ["deploy", "ops"], paths: paths
        )
        #expect(result.contains("Successfully updated skill"))

        let content = try String(contentsOf: paths.skillsDir.appendingPathComponent("deploy-recipe/SKILL.md"), encoding: .utf8)
        #expect(content.contains("title: Deploy Recipe"), "title untouched by a call that only named tags")
        #expect(content.contains("tags: [\"deploy\", \"ops\"]"), "tags updated to the new list")
        #expect(content.contains("description: Deploy the service"))
    }

    @Test("write_file to a skill's SKILL.md invalidates the prompt cache and warns on a name/folder mismatch")
    func writeFileToSkillInvalidatesCacheAndWarns() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        var executor = ToolExecutor()
        executor.irisPaths = paths

        let skillFolder = paths.skillsDir.appendingPathComponent("hand-written")
        try FileManager.default.createDirectory(at: skillFolder, withIntermediateDirectories: true)
        let skillPath = skillFolder.appendingPathComponent("SKILL.md").path
        let mismatched = """
        ---
        name: totally-different-name
        description: Hand-written skill
        ---

        Body text.
        """
        let result = await executor.execute(
            name: "write_file",
            args: ["path": .string(skillPath), "content": .string(mismatched)]
        )
        #expect(result.contains("Successfully wrote to"))
        #expect(result.contains("Skill prompt cache invalidated."),
                "a write_file landing on a skill's own SKILL.md must invalidate the cached system prompt")
        #expect(result.contains("does not match its folder"),
                "a name/folder mismatch is surfaced as a warning, not silently accepted")
        #expect(FileManager.default.fileExists(atPath: skillPath), "the content the caller wrote is what landed, unmodified")
        let onDisk = try String(contentsOf: URL(fileURLWithPath: skillPath), encoding: .utf8)
        #expect(onDisk == mismatched, "write_file does not route a skill write through update_skill's OKF reconstruction")
    }

    @Test("write_file to a well-formed skill's SKILL.md invalidates the cache with no warning")
    func writeFileToWellFormedSkillHasNoWarning() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        var executor = ToolExecutor()
        executor.irisPaths = paths

        let skillFolder = paths.skillsDir.appendingPathComponent("my-skill")
        try FileManager.default.createDirectory(at: skillFolder, withIntermediateDirectories: true)
        let skillPath = skillFolder.appendingPathComponent("SKILL.md").path
        let okf = """
        ---
        name: my-skill
        description: A fine, matching skill
        ---

        Body text.
        """
        let result = await executor.execute(
            name: "write_file",
            args: ["path": .string(skillPath), "content": .string(okf)]
        )
        #expect(result.contains("Skill prompt cache invalidated."))
        #expect(!result.contains("Warning"))
    }

    @Test("write_file elsewhere under the skills dir (not a SKILL.md) is an ordinary write")
    func writeFileToNonSkillMdIsUnaffected() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        var executor = ToolExecutor()
        executor.irisPaths = paths

        let sidecarFolder = paths.skillsDir.appendingPathComponent("my-skill")
        try FileManager.default.createDirectory(at: sidecarFolder, withIntermediateDirectories: true)
        let sidecarPath = sidecarFolder.appendingPathComponent("notes.txt").path
        let result = await executor.execute(
            name: "write_file",
            args: ["path": .string(sidecarPath), "content": .string("just notes")]
        )
        #expect(result.contains("Successfully wrote to"))
        #expect(!result.contains("Skill prompt cache invalidated."))
    }

    @Test("the tags schema declares ARRAY items (Gemini 400s without it)")
    func tagsSchemaHasItems() async {
        let tools = await ToolExecutor.shared.getTools()
        for toolName in ["create_skill", "update_skill"] {
            let tool = try! #require(tools.first { $0.name == toolName })
            let tagsSchema = try! #require(tool.parameters?.properties?["tags"])
            #expect(tagsSchema.type == "ARRAY")
            #expect(tagsSchema.items?.type == "STRING", "\(toolName).tags is missing `items` — Gemini will reject it")
        }
        #expect(tools.arrayItemsViolations().isEmpty)
    }

    @Test("a tags argument that isn't a list of strings is refused, not silently dropped")
    func malformedTagsRefused() async {
        let result = await ToolExecutor.shared.execute(
            name: "create_skill",
            args: ["name": .string("x"), "description": .string("d"), "body": .string("b"),
                   "tags": .array([.int(1), .int(2)])]
        )
        #expect(result.hasPrefix("Error:"))
        #expect(result.contains("tags"))
    }

    @Test("a name/folder mismatch in a hand-written skill loads with a warning, not a refusal")
    func mismatchedSkillStillLoads() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let dir = paths.skillsDir.appendingPathComponent("my-folder")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let okf = """
        ---
        name: a-different-name
        description: Still loads
        ---

        Body.
        """
        try okf.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let skills = await SkillManager.shared.listSkills(paths: paths)
        #expect(skills.count == 1, "a mismatched name/folder is not refused — it still loads")
        let skill = try #require(skills.first)
        #expect(skill.name == "a-different-name")
        #expect(skill.warning?.contains("does not match its folder") == true)
    }

    @Test("two skills sharing a display name both get a duplicate-name warning")
    func duplicateNamesWarn() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        for folder in ["skill-a", "skill-b"] {
            let dir = paths.skillsDir.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let okf = """
            ---
            name: shared-name
            description: One of two with the same name
            ---

            Body.
            """
            try okf.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }

        let skills = await SkillManager.shared.listSkills(paths: paths)
        #expect(skills.count == 2)
        for skill in skills {
            #expect(skill.warning?.contains("duplicate skill name") == true, Comment(rawValue: skill.folderName))
        }
    }

    @Test("a skill with no frontmatter oddities gets no warning")
    func noWarningForAnOrdinarySkill() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        _ = await ToolExecutor.shared.createSkill(name: "ordinary", description: "d", body: "b", paths: paths)
        let skills = await SkillManager.shared.listSkills(paths: paths)
        #expect(skills.count == 1)
        #expect(skills.first?.warning == nil)
    }
}
