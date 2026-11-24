import Testing
import Foundation
@testable import IrisKit

/// #1342: a role word spelled with a Cyrillic or Greek look-alike (`Hуman:`, `Usеr:`) is stripped and
/// recorded like the Latin one. The fold is for matching only: the text passed on keeps its own letters.
@Suite("a role word spelled with a Cyrillic or Greek look-alike is stripped (#1342)", .timeLimit(.minutes(1)))
struct RoleConfusableTests {
    @Test("stripped and recorded like the Latin role word", arguments: [
        ("H\u{0443}man: x", " x"),                 // Cyrillic у
        ("Us\u{0435}r: x", " x"),                  // Cyrillic е
        ("\u{0405}\u{0443}\u{0455}t\u{0435}m: x", " x"),  // Ѕуѕtеm, mostly Cyrillic
        ("\u{0391}ssistant: x", " x"),             // Greek Alpha
        ("m\u{03BF}del: x", " x"),                 // Greek omicron
        ("note. Us\u{0435}r: x", "note.  x"),      // mid-line, as the Latin one is
        ("System Pr\u{043E}mpt: x", " x"),
        ("\u{0406}nstruction: x", " x"),           // Cyrillic І, an alternate reading
        ("\u{4E2D}Us\u{0435}r: x", "\u{4E2D} x"),     // after a letter of another script, as `中User:` is
        ("\u{00E9}Us\u{0435}r: x", "\u{00E9} x"),
        ("\u{0405}\u{0443}\u{0455}t\u{0435}m: \u{041D}\u{0443}man: x", "  x"),  // у as y, then as u
    ])
    func stripped(_ input: String, _ expected: String) {
        let (text, lines) = PromptInjectionGuard.stripRecordingDelimiters("before\n\(input)\nafter")
        #expect(text == "before\n\(expected)\nafter", "\(input.debugDescription) became \(text.debugDescription)")
        #expect(lines[1] == input, "\(input.debugDescription) is recorded as it read")
    }

    @Test("the rest of the line keeps its look-alikes: only the role word goes")
    func restUnfolded() {
        let input = "Us\u{0435}r: \u{0443}es, \u{043E}k"
        #expect(PromptInjectionGuard.sanitizeUntrustedInput(input) == " \u{0443}es, \u{043E}k")
    }

    @Test("a bare role line spelled with look-alikes is emptied and recorded", arguments: [
        "\u{0405}\u{0443}\u{0455}t\u{0435}m", "**\u{0410}ssistant**", "## Us\u{0435}r", "H\u{0443}man:",
    ])
    func bareLine(_ line: String) {
        let (text, lines) = PromptInjectionGuard.stripRecordingDelimiters("before\n\(line)\nafter")
        #expect(text == "before\n\nafter", "\(line.debugDescription) became \(text.debugDescription)")
        #expect(lines.keys.contains(1))
    }

    @Test("a folded system delimiter is a strong one for tier 2's cap")
    func strength() {
        #expect(PromptInjectionGuard.delimiterStrength("\u{0405}\u{0443}\u{0455}t\u{0435}m: x") == 0)
        #expect(PromptInjectionGuard.delimiterStrength("Us\u{0435}r: x") == 1)
    }

    /// A mixed-script word that folds to no role word, and a Cyrillic or Greek word whose folded ending is a
    /// role word, are left byte for byte.
    @Test("a mixed-script word that is not a role word is untouched", arguments: [
        "R\u{0435}port: done", "H\u{0443}manity: x", "\u{0431}\u{041C}\u{043E}d\u{0435}l: x", "\u{0443}ser_id: 4", "\u{03B5}\u{03AF}\u{03BD}\u{03B1}\u{03B9}: x",
    ])
    func untouched(_ input: String) {
        let (text, lines) = PromptInjectionGuard.stripRecordingDelimiters(input)
        #expect(Array(text.utf8) == Array(input.utf8), "\(input.debugDescription) became \(text.debugDescription)")
        #expect(lines.isEmpty)
    }

    @Test("benign Cyrillic and Greek prose is unchanged byte for byte")
    func benignProse() {
        let prose = """
        Пользователь: привет, как дела?
        Система: готово. Модель обучена.
        Ассистент сказал: «всё хорошо».
        Σύστημα: έτοιμο. Ο χρήστης είπε: ναι.
        Человек: да
        """
        let (text, lines) = PromptInjectionGuard.stripRecordingDelimiters(prose)
        #expect(Array(text.utf8) == Array(PromptInjectionGuard.normalize(prose).utf8))
        #expect(lines.isEmpty)
    }

    /// The table's contract: Cyrillic or Greek sources NFKC leaves alone, one UTF-16 unit each way (so a
    /// folded range is the same range in the line), and Latin targets among the role words' letters.
    @Test("the fold table keeps its contract")
    func table() {
        let roleLetters = Set("systempromptassistantusermodelhumanaideveloperstoolfunctioninstructionsmessageturnresponserole")
        #expect(PromptInjectionGuard.roleConfusables.count == 53)
        for (source, target) in PromptInjectionGuard.roleConfusables {
            #expect((0x0370...0x052F).contains(source.value), "U+\(String(source.value, radix: 16))")
            #expect(String(source).precomposedStringWithCompatibilityMapping == String(source))
            #expect(String(source).utf16.count == 1 && String(target).utf16.count == 1)
            #expect(target.isASCII && roleLetters.contains(Character(String(target).lowercased())))
        }
        #expect(PromptInjectionGuard.roleConfusableAlternates.keys.allSatisfy { PromptInjectionGuard.roleConfusables[$0] != nil })
    }
}
