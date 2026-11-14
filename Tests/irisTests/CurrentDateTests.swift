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

/// The model is told today's date in the system prompt (#951) and the current UTC + local time in
/// `<turn_context>` (#1093), both from the clock at turn time and never from the cached base prompt.
@Suite("Current date and time (#951, #1093)", .timeLimit(.minutes(1)))
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

    @Test("currentTimeSection formats UTC ISO 8601 with seconds and the given local HH:mm + IANA zone (#1093)")
    func formatsCurrentTimeSection() throws {
        // 2026-11-12 21:39:18 UTC -> 16:39 America/Toronto (EST, UTC-5).
        let nov12 = Date(timeIntervalSince1970: 1_794_519_558)
        let toronto = try #require(TimeZone(identifier: "America/Toronto"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let a = IrisEngine.currentTimeSection(now: nov12, timeZone: toronto)
        let b = IrisEngine.currentTimeSection(now: nov12, timeZone: tokyo)
        #expect(a == .init(heading: "Current Time", body: "2026-11-12T21:39:18Z (16:39 America/Toronto)"))
        #expect(b == .init(heading: "Current Time", body: "2026-11-12T21:39:18Z (06:39 Asia/Tokyo)"))
        let utcPart = try #require(a.body.split(separator: " ").first.map(String.init))
        #expect(ISO8601DateFormatter().date(from: utcPart) == nov12,
                "the UTC half must parse under default ISO8601DateFormatter so model-copied deadlines work")
    }

    @Test("a plain turn's request carries today's date in the system prompt and Current Time in turn_context (#951, #1093)")
    @MainActor
    func plainTurnCarriesDateAndTime() async throws {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = DateTurnClient()
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false,
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.setWallClockForTesting { [instant] in instant }
        await engine.processInput("what time is it?", source: "UI", conversationId: id)
        let request = try #require(client.requests.first)
        let texts = request.contents.flatMap(\.parts).compactMap(\.text)
        #expect(!texts.contains { $0.contains("Current Date") }, "the date line must not ride the turn entry")
        let expectedTime = IrisEngine.currentTimeSection(now: instant)
        let lead = try #require(request.contents.first?.parts.first?.text)
        #expect(lead.contains("# \(expectedTime.heading)\n\(expectedTime.body)"), "\(lead)")
        let system = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
        #expect(!system.contains("# Current Time"), "the exact time must not sit in the cached system prompt")
        let line = try #require(system.components(separatedBy: "\n\n").last)
        #expect(line.hasPrefix("# Current Date\nToday is "), "\(line)")
        #expect(line.contains("2026"), "\(line)")
    }

    @Test("an evaluator turn omits Current Time from turn_context (#1093)")
    @MainActor
    func evaluatorOmitsCurrentTime() async throws {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = DateTurnClient()
        let engine = IrisEngine(state: app, tier: .medium, principal: .evaluator, client: client,
                                retryDelays: [], streamResponses: false,
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.setWallClockForTesting { [instant] in instant }
        await engine.processInput("grade the contract", source: "GoalEvaluator", conversationId: id)
        let request = try #require(client.requests.first)
        let texts = request.contents.flatMap(\.parts).compactMap(\.text)
        #expect(!texts.contains { $0.contains("Current Time") }, "\(texts)")
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
