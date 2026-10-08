import Testing
import Foundation
@testable import IrisKit

@Suite("SlashCommandItem Tests")
struct SlashCommandItemTests {

    @Test("matches returns all commands when input is '/'")
    func testMatchesSlash() {
        let matches = SlashCommandItem.matches(for: "/")
        #expect(matches.count == SlashCommandItem.allCommands.count)
    }

    @Test("matches filters commands by prefix")
    func testMatchesPrefix() {
        let goalMatches = SlashCommandItem.matches(for: "/g")
        #expect(goalMatches.count == 1)
        #expect(goalMatches.first?.command == "/goal")

        let vMatches = SlashCommandItem.matches(for: "/v")
        #expect(vMatches.count == 1)
        #expect(vMatches.first?.command == "/vibecop init")

        let refMatches = SlashCommandItem.matches(for: "/re")
        #expect(refMatches.count == 2) // /reflect and /rename
    }

    @Test("matches returns empty when typing arguments after space")
    func testMatchesWithSpaceReturnsEmpty() {
        #expect(SlashCommandItem.matches(for: "/goal Build something").isEmpty)
        #expect(SlashCommandItem.matches(for: "/skills ").isEmpty)
    }

    @Test("matches returns empty for non-slash input")
    func testMatchesNonSlashInput() {
        #expect(SlashCommandItem.matches(for: "hello").isEmpty)
        #expect(SlashCommandItem.matches(for: "").isEmpty)
    }
}
