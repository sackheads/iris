import Testing
import Foundation
@testable import iris

@Suite("Agent Skill Validator Tests")
struct AgentSkillValidatorTests {
    func makeSkill(dirName: String, skillMD: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-skill-test-\(UUID().uuidString)")
            .appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let skillMD {
            try skillMD.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test("valid skill passes")
    func valid() throws {
        let dir = try makeSkill(dirName: "pdf-processing", skillMD: """
        ---
        name: pdf-processing
        description: Extract PDF text and tables. Use when handling PDFs.
        ---
        Instructions here.
        """)
        #expect(AgentSkillValidator.validate(directory: dir).isEmpty)
    }

    @Test("name rules", arguments: [
        ("PDF-Processing", false), ("-pdf", false), ("pdf-", false),
        ("pdf--processing", false), ("pdf-processing", true),
        (String(repeating: "a", count: 65), false), ("a", true)
    ])
    func nameRules(name: String, ok: Bool) {
        #expect((AgentSkillValidator.validateName(name) == nil) == ok)
    }

    @Test("CRLF-encoded SKILL.md validates")
    func crlf() throws {
        let content = """
        ---
        name: pdf-processing
        description: Extract PDF text and tables. Use when handling PDFs.
        ---
        Instructions here.
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let dir = try makeSkill(dirName: "pdf-processing", skillMD: content)
        #expect(AgentSkillValidator.validate(directory: dir).isEmpty)
    }

    @Test("missing SKILL.md is a violation")
    func missingFile() throws {
        let dir = try makeSkill(dirName: "no-skill", skillMD: nil)
        #expect(!AgentSkillValidator.validate(directory: dir).isEmpty)
    }

    @Test("name/directory mismatch is a violation")
    func mismatch() throws {
        let dir = try makeSkill(dirName: "folder-name", skillMD: """
        ---
        name: other-name
        description: Something.
        ---
        """)
        #expect(AgentSkillValidator.validate(directory: dir).contains { $0.contains("match") })
    }

    @Test("empty description is a violation")
    func emptyDescription() throws {
        let dir = try makeSkill(dirName: "desc-less", skillMD: """
        ---
        name: desc-less
        ---
        """)
        #expect(AgentSkillValidator.validate(directory: dir).contains { $0.contains("description") })
    }
}
