import Testing
import Foundation
@testable import IrisKit

@Suite("SlashCommand Integration Tests")
struct SlashCommandTests {

    @Test("allCommands includes new commands (/rules, /model, /mcp, /facts, /tokens, /new, /clear)")
    func testAllCommandsIncludesNewItems() {
        let commands = SlashCommandItem.allCommands.map { $0.command }
        #expect(commands.contains("/skills"))
        #expect(commands.contains("/rules"))
        #expect(commands.contains("/model"))
        #expect(commands.contains("/mcp"))
        #expect(commands.contains("/facts"))
        #expect(commands.contains("/tokens"))
        #expect(commands.contains("/new"))
        #expect(commands.contains("/clear"))
        #expect(commands.contains("/update"))
    }

    @Test("SkillManager.readSkillBody retrieves skill contents")
    func testSkillManagerReadSkillBody() async throws {
        try await withTempDirectory(prefix: "iris-skill-read") { root in
            let paths = IrisPaths(root: root)
            try? paths.ensureDirectories()

            let skillFolder = paths.skillsDir.appendingPathComponent("test-skill")
            try? FileManager.default.createDirectory(at: skillFolder, withIntermediateDirectories: true)
            let skillContent = """
            ---
            name: test-skill
            description: Test skill description
            ---

            # Test Skill Body
            Instructions go here.
            """
            try? skillContent.write(to: skillFolder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

            let body = await SkillManager.shared.readSkillBody(name: "test-skill", paths: paths)
            #expect(body != nil)
            #expect(body?.contains("Test Skill Body") == true)

            let nonExistent = await SkillManager.shared.readSkillBody(name: "non-existent", paths: paths)
            #expect(nonExistent == nil)
        }
    }

    @Test("FactStoreManager probes and searches facts for /facts command")
    func testFactStoreQueries() throws {
        let factStore = try FactStoreManager(inMemory: true)
        try factStore.addFact(content: "Brian Naylor works on GKE", category: "project", entity: "Brian")
        try factStore.addFact(content: "Clomp manages trading algorithms", category: "finance", entity: "Clomp")

        let brianFacts = try factStore.probe(entity: "Brian")
        #expect(brianFacts.count == 1)
        #expect(brianFacts.first?.content.contains("GKE") == true)

        let searchFacts = try factStore.search(query: "trading")
        #expect(searchFacts.count == 1)
        #expect(searchFacts.first?.content.contains("trading") == true)
    }
}
