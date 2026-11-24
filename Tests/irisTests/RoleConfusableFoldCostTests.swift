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

    static func cost(_ text: String) -> Double {
        let start = TestClock.now()
        _ = PromptInjectionGuard.stripRecordingDelimiters(text)
        return TestClock.seconds(since: start)
    }

    /// A ratio, not a wall: both inputs run on the same machine in the same test, so a slow CI runner slows both.
    /// The inputs have the same number of lines and UTF-16 units; the ASCII one has no table letter, so the
    /// ratio is the fold's own cost. The two are timed in turn and the minimum of each kept, so one preempted run
    /// does not decide it. Measured locally (M4 Max): main, with no fold, 1.9–2.0; ae7a2936, folding per pattern,
    /// 7.5–7.6; folding once per pass without the role-word check, 4.1–4.4; as shipped, 2.2–2.5.
    @Test("Russian and Greek prose strips within a small multiple of ASCII text of the same size")
    func foldCostIsBounded() {
        let prose = Array(repeating: Self.russianProse, count: 400).joined(separator: "\n")
        let ascii = String(prose.unicodeScalars.map { $0.isASCII ? Character($0) : "a" })
        #expect(ascii.utf16.count == prose.utf16.count)
        _ = PromptInjectionGuard.stripRecordingDelimiters(prose)  // warm the regex caches
        var proseCost = Double.infinity, asciiCost = Double.infinity
        for _ in 0..<5 {
            proseCost = min(proseCost, Self.cost(prose))
            asciiCost = min(asciiCost, Self.cost(ascii))
        }
        let ratio = proseCost / asciiCost
        #expect(ratio < 3.5, "Russian and Greek prose cost \(ratio) times ASCII of the same size (\(proseCost) s)")
    }
}
