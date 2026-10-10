import Testing
import Foundation
@testable import IrisKit

@Suite("Session card A2A fields")
struct SessionCardFieldsTests {
    @Test("a card stored before part 2 decodes with no lane and no skills")
    func legacyCardDecodes() throws {
        let json = #"{"name":"spec-writer","description":"drafting","updatedAt":0}"#
        let card = try JSONDecoder().decode(SessionCard.self, from: Data(json.utf8))
        #expect(card.name == "spec-writer")
        #expect(card.lane == nil)
        #expect(card.skills.isEmpty)
    }

    @Test("lane and skills round-trip")
    func roundTrip() throws {
        let skill = AgentSkill(id: "review-pr", name: "Review a PR", description: "Reviews one PR",
                               tags: ["github"], examples: ["review PR 12"])
        let card = SessionCard(name: "pr-minder", description: "watching PRs", lane: "github", skills: [skill])
        let back = try JSONDecoder().decode(SessionCard.self, from: JSONEncoder().encode(card))
        #expect(back.lane == "github")
        #expect(back.skills == [skill])
    }

    @Test("a skill missing tags or examples decodes with empty lists")
    func sparseSkillDecodes() throws {
        let json = #"{"id":"a","name":"A","description":"d"}"#
        let skill = try JSONDecoder().decode(AgentSkill.self, from: Data(json.utf8))
        #expect(skill.tags.isEmpty && skill.examples.isEmpty)
    }
}
