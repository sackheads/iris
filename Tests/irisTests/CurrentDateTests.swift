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

/// The model is told today's date in the system prompt (#951), from the clock at turn time and
/// never from the cached base prompt, and gets exact wall-clock time on demand via `current_time`
/// (#1093) so `<turn_context>` stays empty on plain turns and sessions need not shell out to `date`.
@Suite("Current date and time (#951, #1093)", .timeLimit(.minutes(1)))
struct CurrentDateTests {
    // 2026-11-08 22:32:00 UTC, a Sunday.
    private let instant = Date(timeIntervalSince1970: 1_794_177_120)

    @Test("the line names weekday, date and zone, in the zone it is given, and points to current_time only when offered")
    func formatsInTheGivenZone() throws {
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let a = IrisEngine.currentDateLine(now: instant, timeZone: la)
        let b = IrisEngine.currentDateLine(now: instant, timeZone: tokyo)
        let withoutTool = IrisEngine.currentDateLine(now: instant, timeZone: la, hasCurrentTimeTool: false)
        #expect(a.hasPrefix("# Current Date\nToday is Sunday, 8 November 2026 (America/Los_Angeles)."), "\(a)")
        #expect(b.hasPrefix("# Current Date\nToday is Monday, 9 November 2026 (Asia/Tokyo)."), "\(b)")
        #expect(a.contains(IrisEngine.currentTimeTool), "\(a)")
        #expect(!withoutTool.contains(IrisEngine.currentTimeTool), "\(withoutTool)")
    }

    @Test("an evaluator or profile-narrowed turn without current_time omits the current_time nudge from currentDateLine (#1093)")
    @MainActor
    func omitsCurrentTimeNudgeWhenToolNotOffered() async throws {
        let app = AppState()
        app.conversations.removeAll()
        let evalId = UUID()
        app.createNewConversation(id: evalId)
        let evalClient = DateTurnClient()
        let evalEngine = IrisEngine(state: app, tier: .medium, principal: .evaluator, client: evalClient,
                                    retryDelays: [], streamResponses: false,
                                    protectionEnabled: false, sessionPeerCount: 0)
        await evalEngine.setWallClockForTesting { [instant] in instant }
        await evalEngine.processInput("grade", source: "GoalEvaluator", conversationId: evalId)
        let evalSystem = try #require(evalClient.requests.first?.systemInstruction?.parts.compactMap(\.text).joined())
        #expect(!evalSystem.contains(IrisEngine.currentTimeTool), "\(evalSystem)")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1093-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentProfileStore(paths: IrisPaths(root: root))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("---\ntools: [read_file]\n---\nNarrow.\n".utf8)
            .write(to: store.directory.appendingPathComponent("narrow.md"))
        app.agentProfiles = store
        let parent = app.createNewConversation(select: false, agentProfile: "narrow")
        let child = app.createNewConversation(isSubagent: true, select: false)
        app.linkDelegate(child, of: parent)
        let subClient = DateTurnClient()
        let subEngine = IrisEngine(state: app, tier: .medium, principal: .subagent, roleLabel: "helper",
                                   client: subClient, retryDelays: [], streamResponses: false,
                                   protectionEnabled: false, sessionPeerCount: 0)
        await subEngine.setWallClockForTesting { [instant] in instant }
        await subEngine.processInput("check", source: "System", conversationId: child)
        let subSystem = try #require(subClient.requests.first?.systemInstruction?.parts.compactMap(\.text).joined())
        #expect(!subSystem.contains(IrisEngine.currentTimeTool), "\(subSystem)")
    }

    @Test("formatCurrentTime formats UTC ISO 8601 with seconds and the given local HH:mm + IANA zone (#1093)")
    func formatsCurrentTime() throws {
        // 2026-11-12 21:39:18 UTC -> 16:39 America/Toronto (EST, UTC-5).
        let nov12 = Date(timeIntervalSince1970: 1_794_519_558)
        let toronto = try #require(TimeZone(identifier: "America/Toronto"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let a = IrisEngine.formatCurrentTime(now: nov12, timeZone: toronto)
        let b = IrisEngine.formatCurrentTime(now: nov12, timeZone: tokyo)
        #expect(a == "2026-11-12T21:39:18Z (16:39 America/Toronto)")
        #expect(b == "2026-11-12T21:39:18Z (06:39 Asia/Tokyo)")
        let utcPart = try #require(a.split(separator: " ").first.map(String.init))
        #expect(ISO8601DateFormatter().date(from: utcPart) == nov12,
                "the UTC half must parse under default ISO8601DateFormatter so model-copied deadlines work")
    }

    @Test("run_command's description sends a clock check to current_time (#1093)")
    func runCommandDescriptionMentionsCurrentTime() async throws {
        let tools = await ToolExecutor.shared.getTools(workspaceToolsEnabled: false)
        let desc = try #require(tools.first { $0.name == "run_command" }?.description)
        #expect(desc.contains(IrisEngine.currentTimeTool))
    }

    @Test("current_time returns the engine's wallClock and does not taint the conversation (#1093)")
    @MainActor
    func currentTimeToolReturnsClockWithoutTaint() async throws {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let call = GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: IrisEngine.currentTimeTool, args: [:], id: "t1"))]))],
                                  usageMetadata: nil)
        let done = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))],
                                  usageMetadata: nil)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main,
                                client: FakeLLMClient(responses: [call, done]),
                                retryDelays: [], streamResponses: false,
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.setWallClockForTesting { [instant] in instant }
        await engine.processInput("what time is it?", source: "UI", conversationId: id)
        let conv = try #require(app.conversations.first { $0.id == id })
        let response = conv.history.flatMap(\.parts).compactMap { part -> String? in
            guard part.functionResponse?.name == IrisEngine.currentTimeTool,
                  case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.first
        #expect(response == IrisEngine.formatCurrentTime(now: instant))
        #expect(!conv.hasUntrustedToolOutput, "current_time is Iris's own clock, not outside content")
    }

    @Test("a plain turn's request carries today's date in the system prompt, not in the message list")
    @MainActor
    func plainTurnCarriesDateLine() async throws {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = DateTurnClient()
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false,
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("what day is it?", source: "UI", conversationId: id)
        let request = try #require(client.requests.first)
        let texts = request.contents.flatMap(\.parts).compactMap(\.text)
        #expect(!texts.contains { $0.contains("Current Date") }, "the date line must not ride the turn entry")
        let system = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
        let line = try #require(system.components(separatedBy: "\n\n").last)
        #expect(line.hasPrefix("# Current Date\nToday is "), "\(line)")
        #expect(line.contains(String(Calendar(identifier: .gregorian).component(.year, from: Date()))), "\(line)")
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
