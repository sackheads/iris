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

    // MARK: - PR review follow-ups (iris-86)

    /// Blocking finding: `update_skill` used to render only `SkillFrontmatterField.scalarValue`
    /// (the first line's text) for `description` when the call didn't change it, which dropped
    /// every continuation line of a folded (`>`) or literal (`|`) block scalar, or a wrapped
    /// plain scalar. `description`/`type` must now carry the existing field's raw lines over the
    /// same way `title`/`tags` already did.
    @Test("update_skill preserves a folded (>) multi-line description it wasn't asked to change")
    func updateSkillPreservesFoldedDescription() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let dir = paths.skillsDir.appendingPathComponent("folded-desc")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = """
        ---
        name: folded-desc
        description: >
          Debug stuck nodes
          in GKE clusters
        type: skill
        timestamp: 2026-01-01T00:00:00Z
        ---

        Body.
        """
        try original.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let result = await ToolExecutor.shared.updateSkill(name: "folded-desc", description: nil, body: nil,
                                                            title: "New Title", paths: paths)
        #expect(result.contains("Successfully updated skill"))

        let content = try String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(content.contains("description: >"))
        #expect(content.contains("  Debug stuck nodes"))
        #expect(content.contains("  in GKE clusters"), "every continuation line must survive, not just the first")
        #expect(content.contains("title: New Title"))
    }

    @Test("update_skill preserves a literal (|) multi-line description it wasn't asked to change")
    func updateSkillPreservesLiteralDescription() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let dir = paths.skillsDir.appendingPathComponent("literal-desc")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = """
        ---
        name: literal-desc
        description: |
          Line one.
          Line two.
        ---

        Body.
        """
        try original.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        _ = await ToolExecutor.shared.updateSkill(name: "literal-desc", description: nil, body: "New body", paths: paths)

        let content = try String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(content.contains("description: |"))
        #expect(content.contains("  Line one."))
        #expect(content.contains("  Line two."))
        #expect(content.contains("New body"))
    }

    @Test("update_skill preserves a wrapped plain-scalar description it wasn't asked to change")
    func updateSkillPreservesWrappedDescription() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let dir = paths.skillsDir.appendingPathComponent("wrapped-desc")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = """
        ---
        name: wrapped-desc
        description: Debug stuck nodes
          continued here
        ---

        Body.
        """
        try original.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        _ = await ToolExecutor.shared.updateSkill(name: "wrapped-desc", description: nil, body: nil,
                                                   tags: ["ops"], paths: paths)

        let content = try String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(content.contains("description: Debug stuck nodes"))
        #expect(content.contains("  continued here"), "the continuation line must not be dropped")
        #expect(content.contains("tags: [\"ops\"]"))
    }

    @Test("update_skill preserves a non-default type it wasn't asked to change")
    func updateSkillPreservesType() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let dir = paths.skillsDir.appendingPathComponent("typed-skill")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = """
        ---
        name: typed-skill
        description: d
        type: procedure
        ---

        Body.
        """
        try original.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        _ = await ToolExecutor.shared.updateSkill(name: "typed-skill", description: nil, body: "new body", paths: paths)

        let content = try String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(content.contains("type: procedure"), "type isn't a tool parameter at all, so it must never be reset to the default")
    }

    /// Item 2: a newline in `title` (or `description`, or a tag) must never reach the rendered
    /// frontmatter literally — it would close the `---` block early and spill the rest into the
    /// skill's body.
    @Test("a newline in title cannot close the frontmatter block early")
    func newlineInTitleIsFlattened() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let injected = "Evil\n---\ninjected: yes"
        let result = await ToolExecutor.shared.createSkill(name: "injection-attempt", description: "d", body: "b",
                                                            title: injected, paths: paths)
        #expect(result.contains("Successfully saved skill"))

        let content = try String(contentsOf: paths.skillsDir.appendingPathComponent("injection-attempt/SKILL.md"), encoding: .utf8)
        let (fields, body) = SkillFrontmatter.parse(content)
        #expect(!fields.isEmpty, "the frontmatter block must still be intact")
        #expect(SkillFrontmatter.value(fields, key: "description") == "d",
                "a flattened title must not have knocked description out of the frontmatter block")
        #expect(!body.contains("injected: yes"), "the injected line must not have spilled into the body")
    }

    /// Item 7: a value containing `: ` is ambiguous as a bare YAML scalar (it reads as another
    /// mapping pair) and must be quoted. Verified against `AgentSkillValidator`, which parses
    /// frontmatter with Yams the same way a real consumer would.
    @Test("a title containing \": \" is quoted and still parses as valid YAML")
    func titleWithColonIsQuoted() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        _ = await ToolExecutor.shared.createSkill(name: "colon-title", description: "d", body: "b",
                                                   title: "GKE: nodes", paths: paths)
        let skillDir = paths.skillsDir.appendingPathComponent("colon-title")
        let content = try String(contentsOf: skillDir.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(content.contains("title: \"GKE: nodes\""))

        let violations = AgentSkillValidator.validate(directory: skillDir)
        #expect(!violations.contains { $0.contains("not valid YAML") }, "\(violations)")
    }

    /// Item 8: escaping the closing quote before escaping backslashes leaves a tag ending in `\`
    /// with an unescaped backslash directly before the string's closing quote, which escapes the
    /// delimiter instead of ending the string. Verified against `AgentSkillValidator` (Yams).
    @Test("a tag ending in a backslash is escaped correctly and still parses as valid YAML")
    func tagEndingInBackslashIsEscaped() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        _ = await ToolExecutor.shared.createSkill(name: "backslash-tag", description: "d", body: "b",
                                                   tags: ["back\\", "plain"], paths: paths)
        let skillDir = paths.skillsDir.appendingPathComponent("backslash-tag")
        let violations = AgentSkillValidator.validate(directory: skillDir)
        #expect(!violations.contains { $0.contains("not valid YAML") }, "\(violations)")
    }

    /// Item 9: `ScheduleJobArguments.stringList` treats an empty list as "nothing asked", which
    /// is right for `mounts`/`ignore` but would make `tags: []` a silent no-op for skills, with
    /// no way to ever clear a skill's tags. `ToolExecutor.tagsArgument` must keep the three
    /// states distinguishable all the way from the raw tool-call argument.
    @Test("tagsArgument distinguishes \"not given\" from \"given empty\" from \"given a list\"")
    func tagsArgumentTriStates() {
        switch ToolExecutor.tagsArgument([:]) {
        case .success(let tags): #expect(tags == nil, "omitted entirely must mean \"leave alone\"")
        case .failure: Issue.record("tags omitted should not be a refusal")
        }
        switch ToolExecutor.tagsArgument(["tags": .null]) {
        case .success(let tags): #expect(tags == nil, "an explicit null reads the same as omitted")
        case .failure: Issue.record("tags: null should not be a refusal")
        }
        switch ToolExecutor.tagsArgument(["tags": .array([])]) {
        case .success(let tags): #expect(tags == [], "an explicit empty list must mean \"clear\", not \"leave alone\"")
        case .failure: Issue.record("tags: [] should not be a refusal")
        }
        switch ToolExecutor.tagsArgument(["tags": .array([.string("a"), .string("b")])]) {
        case .success(let tags): #expect(tags == ["a", "b"])
        case .failure: Issue.record("a well-formed list should not be a refusal")
        }
    }

    @Test("update_skill with tags: [] clears existing tags")
    func emptyTagsArrayClearsExistingTags() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        _ = await ToolExecutor.shared.createSkill(name: "clear-tags", description: "d", body: "b",
                                                   tags: ["one", "two"], paths: paths)
        let result = await ToolExecutor.shared.updateSkill(name: "clear-tags", description: nil, body: nil,
                                                            tags: [], paths: paths)
        #expect(result.contains("Successfully updated skill"))

        let content = try String(contentsOf: paths.skillsDir.appendingPathComponent("clear-tags/SKILL.md"), encoding: .utf8)
        #expect(content.contains("tags: []"))
        #expect(!content.contains("\"one\""))
    }

    /// Item 3: APFS is case-insensitive by default, so `skills/foo/skill.md` and
    /// `skills/foo/SKILL.md` name the very same file — a write to the lowercase spelling must be
    /// detected exactly like the canonical one, or it silently overwrites the real file with no
    /// cache invalidation and no warning.
    @Test("skillFileTarget detects a lowercase skill.md the same as SKILL.md")
    func skillFileTargetIsCaseInsensitive() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let folder = paths.skillsDir.appendingPathComponent("foo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(ToolExecutor.skillFileTarget(folder.path + "/skill.md", paths: paths) == "foo")
        #expect(ToolExecutor.skillFileTarget(folder.path + "/Skill.Md", paths: paths) == "foo")
    }

    /// Item 4: a path with a literal `/./ ` component (as a model might spell a relative path)
    /// must standardize before its last two components are read off, or `.` is read as the
    /// skill's folder name instead of `foo`.
    @Test("skillFileTarget standardizes a '/./ ' path component before matching")
    func skillFileTargetStandardizesDotComponent() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let folder = paths.skillsDir.appendingPathComponent("foo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dottedPath = folder.path + "/./SKILL.md"
        #expect(ToolExecutor.skillFileTarget(dottedPath, paths: paths) == "foo")
    }

    /// Item 5: a write straight to a skill folder symlink's real target, bypassing the symlink
    /// itself, must still be recognized as that skill — neither side of the usual lexical
    /// comparison looks like a symlink by the time such a path is walked, so the match has to
    /// come from resolving each of the skills dir's own entries and comparing the other way.
    @Test("skillFileTarget resolves a write straight to a skill symlink's real target")
    func skillFileTargetResolvesSymlinkTarget() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let elsewhere = paths.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = paths.skillsDir.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)

        #expect(ToolExecutor.skillFileTarget(link.path + "/SKILL.md", paths: paths) == "linked",
                "through the symlink itself")
        #expect(ToolExecutor.skillFileTarget(elsewhere.path + "/SKILL.md", paths: paths) == "linked",
                "straight to the symlink's real target")
    }

    @Test("write_file to a lowercase skill.md still invalidates the prompt cache")
    func writeFileLowercaseSkillMdInvalidatesCache() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        var executor = ToolExecutor()
        executor.irisPaths = paths
        let folder = paths.skillsDir.appendingPathComponent("foo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let result = await executor.execute(
            name: "write_file",
            args: ["path": .string(folder.path + "/skill.md"),
                   "content": .string("---\nname: foo\ndescription: d\n---\n\nBody.")]
        )
        #expect(result.contains("Skill prompt cache invalidated."))
    }

    /// Item 6: `String.components(separatedBy: .newlines)` splits `\r` and `\n` as two
    /// independent one-character delimiters, so a CRLF file produces an extra empty line per
    /// line break — and rejoining with `\n` doubles every line break in the file on every
    /// `update_skill`. The rewritten file must keep the original CRLF ending, not gain doubled
    /// LF breaks instead.
    @Test("update_skill preserves CRLF line endings without doubling them")
    func updateSkillPreservesCRLFWithoutDoubling() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let dir = paths.skillsDir.appendingPathComponent("crlf-skill")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let crlf = "---\r\nname: crlf-skill\r\ndescription: Original\r\n---\r\n\r\nLine one\r\nLine two\r\n"
        try crlf.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let result = await ToolExecutor.shared.updateSkill(name: "crlf-skill", description: nil, body: nil,
                                                            title: "New Title", paths: paths)
        #expect(result.contains("Successfully updated skill"))

        let content = try String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(content.contains("\r\n"), "the file's own CRLF ending must be preserved")
        #expect(!content.contains("\n\n"), "no line break was doubled into a blank line")

        let (_, body) = SkillFrontmatter.parse(content)
        #expect(body == "Line one\nLine two", "the body's two lines must stay two lines, not gain a blank line between them")
    }
}
