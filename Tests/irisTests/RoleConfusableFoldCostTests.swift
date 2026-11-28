import CryptoKit
import Foundation
import Testing
@testable import IrisKit

/// #1385: the look-alike fold (#1342) once folded a line twice for every letter pattern on every pass, so text
/// with a table letter on nearly every line (Russian, Greek) stripped about 4 times slower than on main. The
/// fold is now built once per pass and rebuilt only when a pattern changes the line. Not `@MainActor`: the
/// strip is synchronous and heavy, so it must not hold the main thread (#642).
@Suite("the look-alike fold costs one fold per pass, not one per pattern (#1385)", .serialized, .timeLimit(.minutes(1)))
struct RoleConfusableFoldCostTests {
    /// A deterministic mix of role words in Latin and look-alike spellings, Cyrillic and Greek words, ASCII words,
    /// structure and chat tokens, nested and glued forms, so the strip, the folds and the fixed-point loop all act.
    static func corpus(lines: Int = 3_000) -> String {
        let tokens = [
            "user:", "Us\u{0435}r:", "H\u{0443}man:", "\u{0405}\u{0443}\u{0455}t\u{0435}m:", "system:", "\u{0391}ssistant:",
            "m\u{03BF}del:", "\u{0406}nstruction:", "System Pr\u{043E}mpt:", "\u{4E2D}Us\u{0435}r:", "\u{0416}Us\u{0435}r:",
            "\u{0431}\u{041C}\u{043E}d\u{0435}l:", "\u{03B5}\u{03AF}\u{03BD}\u{03B1}\u{03B9}:", "R\u{0435}port:", "filesystem:",
            "Пользователь:", "привет", "готово", "Σύστημα:", "έτοιμο", "hello", "world", "note.", "(user: x)", "---", "###",
            "<|im_start|>", "<|im_end|>", "mo---del:", "Us---\u{0435}r:", "sys###t\u{0435}m:", "**User**", "## Us\u{0435}r",
            "\u{0443}ser_id:", "H\u{0443}manity:", "ok", "x", "—", "«всё»", "\u{03BF}k",
        ]
        var seed: UInt64 = 0x1385
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        return (0..<lines).map { _ in
            let count = next(4) == 0 ? 1 : 1 + next(7)
            return (0..<count).map { _ in tokens[next(tokens.count)] }.joined(separator: next(3) == 0 ? "" : " ")
        }.joined(separator: "\n")
    }

    static func digest(_ result: (text: String, delimiterLines: [Int: String])) -> String {
        var bytes = Data(result.text.utf8)
        for key in result.delimiterLines.keys.sorted() { bytes.append(Data("\n#\(key)=\(result.delimiterLines[key]!)".utf8)) }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The strip of `corpus()` at ae7a2936, the per-pattern fold #1381's reviewers approved: the text and every
    /// recorded line, hashed. Rebuilding the fold once per pass must not change a byte of either.
    static let ae7a2936Digest = "fb9534f2729a82d8b290f351acaf4a4dc1835919d11bac52e8d305ff3166bbd4"

    @Test("the output is byte-identical to the per-pattern fold's")
    func byteIdentical() {
        let result = PromptInjectionGuard.stripRecordingDelimiters(Self.corpus())
        #expect(result.delimiterLines.count == 2065, "the corpus still exercises the strip")
        #expect(Self.digest(result) == Self.ae7a2936Digest)
    }

    static let russianProse = """
    Сегодня утром мы обсудили план работы на неделю. Отчёт о проделанной работе готов, его можно отправить.
    Пользователь спросил, когда будет готова новая версия; ответ: в пятницу, если тесты пройдут успешно.
    Система работает стабильно, ошибок в журнале нет. Модель обучена на новых данных и показывает хорошие результаты.
    Ο χρήστης είπε ότι το σύστημα είναι έτοιμο. Όλα τα αρχεία αποθηκεύτηκαν σωστά, και η αναφορά στάλθηκε.
    """

    /// The strip's folds and folded-line searches for `text`, counted through `PromptInjectionGuard.foldCounter`.
    static func counts(_ text: String) -> (folds: Int, searches: Int) {
        let counter = PromptInjectionGuard.FoldCounter()
        PromptInjectionGuard.$foldCounter.withValue(counter) { _ = PromptInjectionGuard.stripRecordingDelimiters(text) }
        return (counter.folds, counter.foldedSearches)
    }

    /// Counted rather than timed: a wall-time ratio on a shared CI runner came in at 3.54 against a 3.5 bound on a
    /// commit the merge queue had passed (main run 46114119217), so it measured the runner, not the fold.
    @Test("Russian and Greek prose folds each line a bounded number of times, not once per pattern")
    func foldCountIsBounded() {
        let prose = Array(repeating: Self.russianProse, count: 400).joined(separator: "\n")
        let lines = prose.split(separator: "\n", omittingEmptySubsequences: false).count
        let (folds, searches) = Self.counts(prose)
        // One pass (the prose has nothing to strip), and each line folded once both ways in it. Folding per pattern,
        // as ae7a2936 did, is a multiple of the pattern count.
        #expect(folds <= 2 * lines, "\(folds) folds for \(lines) lines")
        // No word of `malRolePatterns` is in any fold, so no pattern searches one (the 4.1-to-2.2 step of #1385).
        #expect(searches == 0, "\(searches) pattern searches of folded lines")
    }

    @Test("the mixed corpus, which strips, folds a line again only when a pattern has changed it")
    func corpusFoldCount() {
        let corpus = Self.corpus()
        let lines = corpus.split(separator: "\n", omittingEmptySubsequences: false).count
        let (folds, searches) = Self.counts(corpus)
        // As shipped: 19,760 folds and 28,313 searches for 3,000 lines. A fold per pattern, without the per-line cache,
        // is 156,104; searching folds with no role word in them is 56,430 searches.
        #expect(folds <= 8 * lines, "\(folds) folds for \(lines) lines")
        #expect(searches <= 12 * lines, "\(searches) pattern searches of folded lines")
    }
}
