import Testing
import Foundation
@testable import IrisKit

private final class DateTurnClient: LLMClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GeminiRequest] = []
    var requests: [GeminiRequest] { lock.withLock { recorded } }
    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
        lock.withLock { recorded.append(request) }
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))],
                              usageMetadata: nil)
    }
}

/// The model is told today's date on every turn (#951), from the clock at turn time and never
/// from the cached system prompt, which would freeze it across days of uptime.
@Suite("Current date in the turn context (#951)", .timeLimit(.minutes(1)))
struct CurrentDateTests {
    // 2026-11-08 22:32:00 UTC, a Sunday.
    private let instant = Date(timeIntervalSince1970: 1_794_177_120)

    @Test("the line names weekday, date and zone, in the zone it is given")
    func formatsInTheGivenZone() throws {
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let a = IrisEngine.currentDateLine(now: instant, timeZone: la)
        let b = IrisEngine.currentDateLine(now: instant, timeZone: tokyo)
        #expect(a.hasPrefix("# Current Date\nToday is Sunday, 8 November 2026 (America/Los_Angeles)."), "\(a)")
        #expect(b.hasPrefix("# Current Date\nToday is Monday, 9 November 2026 (Asia/Tokyo)."), "\(b)")
    }

    @Test("a plain turn's request carries today's date as the last line of its system prompt, and not in the turn context")
    @MainActor
    func plainTurnCarriesTheDate() async throws {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = DateTurnClient()
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false,
                                protectionEnabled: false, sessionPeerCount: 0)
        let before = Date()
        await engine.processInput("what day is it?", source: "UI", conversationId: id)
        let request = try #require(client.requests.first)
        let texts = request.contents.flatMap(\.parts).compactMap(\.text)
        #expect(!texts.contains { $0.contains("Current Date") }, "the date must not ride the turn entry")
        let system = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
        let year = Calendar.current.component(.year, from: before)
        let line = try #require(system.components(separatedBy: "\n\n").last)
        #expect(line.hasPrefix("# Current Date\nToday is "), "\(line)")
        #expect(line.contains(String(year)), "\(line)")
    }

    @Test("the day rolling over moves only the date suffix: the composed prompt before it is byte-identical")
    @MainActor
    func dayRolloverMovesOnlyTheSuffix() async throws {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = DateTurnClient()
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false,
                                protectionEnabled: false, sessionPeerCount: 0)
        let la = TimeZone.current
        let day1 = instant, sameDay = instant.addingTimeInterval(60), day2 = instant.addingTimeInterval(2 * 86_400)
        for t in [day1, sameDay, day2] {
            await engine.setWallClockForTesting { t }
            await engine.processInput("hello", source: "UI", conversationId: id)
        }
        let systems = client.requests.map { $0.systemInstruction?.parts.compactMap(\.text).joined() ?? "" }
        try #require(systems.count == 3)
        let marker = "\n\n# Current Date\n"
        func split(_ s: String) throws -> (String, String) {
            let r = try #require(s.range(of: marker, options: .backwards))
            return (String(s[..<r.lowerBound]), String(s[r.lowerBound...]))
        }
        let (p1, d1) = try split(systems[0]), (p2, d2) = try split(systems[1]), (p3, d3) = try split(systems[2])
        #expect(p1 == p2 && p2 == p3, "the cached composition must not move")
        #expect(d1 == IrisEngine.currentDateLine(now: day1, timeZone: la).prependingBreak(), "\(d1)")
        #expect(d1 == d2, "minutes later, same day: nothing changes")
        #expect(d3 != d1 && d3.contains(IrisEngine.currentDateLine(now: day2, timeZone: la)), "\(d3)")
    }
}

private extension String {
    func prependingBreak() -> String { "\n\n" + self }
}
