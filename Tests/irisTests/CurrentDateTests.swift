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
}
