import Testing
import Foundation
@testable import IrisKit

/// #871: the canary warns when too many of its recent checks send a second request, and the
/// Settings switch turns the second request off. No test waits real time.
@Suite("Canary hedge rate warning (#871)", .timeLimit(.minutes(1)))
struct HedgeRateMonitorTests {
    /// `calls` calls begin; those in `hedged` (by index) fire. Returns the warnings, with their call index.
    private func drive(_ monitor: HedgeRateMonitor, calls: Int, hedged: Set<Int>) -> [(Int, HedgeRateMonitor.Rate)] {
        var warnings: [(Int, HedgeRateMonitor.Rate)] = []
        for i in 0..<calls {
            let call = monitor.began()
            if hedged.contains(i), let rate = monitor.fired(call) { warnings.append((i, rate)) }
        }
        return warnings
    }

    @Test("the rate the design expects, 2.5%, never warns")
    func designRateIsQuiet() {
        let monitor = HedgeRateMonitor(window: 100, minCalls: 20)
        // 5 in 200 calls, spread: the share in any 100 stays under 5%.
        #expect(drive(monitor, calls: 200, hedged: [10, 50, 90, 130, 170]).isEmpty)
    }

    @Test("past 5% of the window it warns, once, with the counts")
    func warnsOnce() {
        let monitor = HedgeRateMonitor(window: 100, minCalls: 20)
        // Every tenth call hedges: 10%. It warns at the first call with 20 calls behind it (2 of 20).
        let warnings = drive(monitor, calls: 100, hedged: Set(stride(from: 9, to: 100, by: 10)))
        #expect(warnings.count == 1)
        #expect(warnings.first?.0 == 19)
        #expect(warnings.first?.1 == .init(hedged: 2, calls: 20))
    }

    @Test("exactly 5% is not over it")
    func boundary() {
        let monitor = HedgeRateMonitor(window: 100, minCalls: 20)
        #expect(drive(monitor, calls: 100, hedged: [20, 40, 60, 80, 99]).isEmpty, "5 of 100 is 5%, not above")
        let over = HedgeRateMonitor(window: 100, minCalls: 20)
        #expect(drive(over, calls: 100, hedged: [20, 40, 60, 80, 90, 99]).count == 1, "5 of 91 calls is over, and it is one warning")
    }

    @Test("fewer than the minimum number of calls never warns, however many hedge")
    func smallSample() {
        let monitor = HedgeRateMonitor(window: 100, minCalls: 20)
        #expect(drive(monitor, calls: 19, hedged: Set(0..<19)).isEmpty)
    }

    @Test("it warns again only after the rate has recovered")
    func rearms() {
        let monitor = HedgeRateMonitor(window: 20, minCalls: 10)
        let first = drive(monitor, calls: 20, hedged: Set(0..<20))
        #expect(first.count == 1, "a spell is one warning, not one per hedge")
        // 20 clean calls push every hedge out of the window and re-arm it.
        #expect(drive(monitor, calls: 20, hedged: []).isEmpty)
        let second = drive(monitor, calls: 20, hedged: Set(0..<20))
        #expect(second.count == 1)
    }

    @Test("a hedge for a call that has slid out of the window is ignored")
    func slidOut() {
        let monitor = HedgeRateMonitor(window: 10, minCalls: 5)
        let old = monitor.began()
        for _ in 0..<10 { _ = monitor.began() }
        #expect(monitor.fired(old) == nil)
    }

    @Test("the warning names the counts and where to turn it off")
    func wording() {
        let text = HedgeRateMonitor.warning(.init(hedged: 6, calls: 40))
        #expect(text.contains("6 of its last 40") && text.contains("15%") && text.contains("Settings"))
    }

    // MARK: the engine

    private static func answer(_ text: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))], usageMetadata: nil)
    }

    final class Notices: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        func add(_ t: String) { lock.withLock { texts.append(t) } }
        var all: [String] { lock.withLock { texts } }
    }

    /// An engine whose first request never answers and whose delay is already over, so every call hedges.
    private static func stalling(monitor: HedgeRateMonitor, notices: Notices, enabled: Bool) -> CloudAuxiliaryEngine {
        var engine = CloudAuxiliaryEngine()
        engine.role = "canary-test"
        engine.model = { nil }
        engine.hedgeAfter = 20
        engine.hedgeEnabled = { enabled }
        engine.hedgeMonitor = monitor
        engine.hedgeSleep = { _ in }
        engine.notice = { notices.add($0) }
        engine.send = { _, _ in
            try await Task.sleep(for: .seconds(3600)); return answer("FIRST")
        }
        engine.sendFresh = { _, _ in answer("SECOND") }
        return engine
    }

    @Test("engine: calls that all hedge produce one warning through the notice path")
    func engineWarns() async throws {
        let notices = Notices()
        let engine = Self.stalling(monitor: HedgeRateMonitor(window: 20, minCalls: 5), notices: notices, enabled: true)
        for _ in 0..<8 {
            let task = Task { try await engine.generate(prompt: "p", jsonSchema: nil) }
            #expect(try await value(of: task, within: 10) == "SECOND")
        }
        #expect(notices.all.count == 1)
        #expect(notices.all.first?.contains("of its last 5 checks") == true)
    }

    @Test("engine: with the setting off one request is sent and nothing is counted")
    func engineOff() async throws {
        let notices = Notices()
        let monitor = HedgeRateMonitor(window: 20, minCalls: 1)
        var engine = Self.stalling(monitor: monitor, notices: notices, enabled: false)
        engine.send = { _, _ in Self.answer("ONLY") }
        for _ in 0..<5 {
            let task = Task { try await engine.generate(prompt: "p", jsonSchema: nil) }
            #expect(try await value(of: task, within: 10) == "ONLY")
        }
        #expect(notices.all.isEmpty)
    }

    @Test("the setting defaults on, is stored, and reads back")
    func settingRoundTrip() {
        let name = "iris-hedge-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let config = ConfigManager(store: store)
        #expect(config.tier3Hedge == true, "unset reads as on, as it has been since #871")
        config.tier3Hedge = false
        #expect(ConfigManager(store: store).tier3Hedge == false)
    }
}
