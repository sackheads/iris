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

    @Test("the section names weekday, date, time and zone in the zone it is given")
    func formatsInTheGivenZone() throws {
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let a = IrisEngine.currentDateSection(now: instant, timeZone: la)
        let b = IrisEngine.currentDateSection(now: instant, timeZone: tokyo)
        #expect(a.heading == "Current Date and Time")
        #expect(a.body == "Sunday, 8 November 2026, 14:32 PST (America/Los_Angeles)", "\(a.body)")
        #expect(b.body == "Monday, 9 November 2026, 07:32 GMT+9 (Asia/Tokyo)", "\(b.body)")
    }

    @Test("a plain turn's request carries the date in its turn_context, and the system prompt does not")
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
        let block = request.contents.flatMap(\.parts).compactMap(\.text).first { $0.hasPrefix("<turn_context>") } ?? ""
        #expect(block.contains("# Current Date and Time\n"), "\(block)")
        let year = Calendar.current.component(.year, from: before)
        #expect(block.contains(String(year)), "\(block)")
        let system = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
        #expect(!system.contains("Current Date and Time"))
    }
}
