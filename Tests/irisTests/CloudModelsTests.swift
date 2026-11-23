import Testing
import Foundation
@testable import IrisKit

/// #1346: `CloudModels` is the one list a paid run reads, and a paid row needs a current listed price.
@Suite("CloudModels: one row per paid model, each with a current listed price (#1346)")
struct CloudModelsTests {
    private static func day(_ s: String) -> Date { CloudModels.parse(s)!.addingTimeInterval(12 * 3600) }

    @Test("every row resolves a price in the snapshot, so no paid model can be listed without one")
    func everyRowIsPriced() {
        for row in CloudModels.rows {
            #expect(EvalCost.rates(provider: row.provider, model: row.id) != nil, "\(row.id) has no snapshot price")
            if let until = row.priceValidUntil { #expect(CloudModels.parse(until) != nil, "\(row.id): \(until) is not yyyy-MM-dd") }
        }
        #expect(Set(CloudModels.rows.map { "\($0.provider)/\($0.id)" }).count == CloudModels.rows.count, "one row per model")
    }

    @Test("the bench takes the benchPrimary rows: gemini-4-hydrogen at medium, and claude-opus-5-5")
    func benchPrimaries() {
        #expect(BenchCloudTarget.allowed == ["gemini-4-hydrogen": .gemini, "claude-opus-5-5": .anthropic])
        #expect(CloudModels.row(provider: .gemini, id: "gemini-4-hydrogen")?.thinkingLevel == "medium")
    }

    @Test("a listed model with a current price and a fresh snapshot runs")
    func currentRuns() {
        #expect(CloudModels.paidRefusal(provider: .gemini, id: "gemini-4-hydrogen", now: Self.day("2026-11-23"), asOf: "2026-11-23") == nil)
        #expect(CloudModels.paidRefusal(provider: .gemini, id: "gemini-4-argon", now: Self.day("2026-11-30"), asOf: "2026-11-23") == nil,
                "the last valid day still runs")
    }

    @Test("refused: a model with no row, a price past its date, a stale snapshot")
    func refusals() throws {
        let noRow = try #require(CloudModels.paidRefusal(provider: .gemini, id: "gemini-made-up-9", now: Self.day("2026-11-23"), asOf: "2026-11-23"))
        #expect(noRow.contains("not in CloudModels.rows") && noRow.contains("--max-dollars can't be enforced"))
        let dated = try #require(CloudModels.paidRefusal(provider: .gemini, id: "gemini-4-argon", now: Self.day("2026-12-01"), asOf: "2026-11-23"))
        #expect(dated.contains("valid through 2026-11-30"), "\(dated)")
        #expect(CloudModels.paidRefusal(provider: .gemini, id: "gemini-3.8-flash", now: Self.day("2027-01-01"), asOf: "2026-12-30") != nil,
                "3.8-flash's price doubles on 2027-01-01")
        let stale = try #require(CloudModels.paidRefusal(provider: .gemini, id: "gemini-4-hydrogen", now: Self.day("2027-01-08"), asOf: "2026-11-23"))
        #expect(stale.contains("more than 45 days ago"), "\(stale)")
        #expect(CloudModels.paidRefusal(provider: .gemini, id: "gemini-4-hydrogen", now: Self.day("2027-01-07"), asOf: "2026-11-23") == nil,
                "day 45 still runs")
    }

    @Test("a row whose model the price table lacks is refused, not charged at a guess")
    func unpricedRowRefused() throws {
        let why = try #require(CloudModels.paidRefusal(provider: .gemini, id: "gemini-4-hydrogen", now: Self.day("2026-11-23"), asOf: "2026-11-23",
                                                       table: PriceTable(parsing: "")))
        #expect(why.contains("no listed price for gemini/gemini-4-hydrogen"))
    }

    @Test("a bench run past its row's date is refused before the ledger reserves anything")
    func benchReserveRefusesStale() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1346b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("ledger.jsonl").path
        let ledger = try SpendLedger(path: path, arm: "a", cap: 3)
        let target = BenchCloudTarget(provider: .gemini, model: "gemini-4-hydrogen", canary: .bypassed, maxDollars: 3, ledgerPath: path)
        guard case .refused(let why) = try BenchCloudTarget.reserveRun(target, in: ledger, now: Self.day("2027-06-01")) else {
            Issue.record("a stale snapshot reserved a run"); return
        }
        #expect(why.contains("more than 45 days ago"))
        #expect(try ledger.total() == 0, "nothing reserved")
    }
}
