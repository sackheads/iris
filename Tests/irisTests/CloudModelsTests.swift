import Testing
import Foundation
@testable import IrisKit

/// #1346: `CloudModels` is the one list a paid run reads, and a paid row needs a current listed price. The expiry and
/// age rules run on a catalog of their own; the shipped table is checked for structure only, never against a clock,
/// so a re-pin can't break these tests and CI can't go red by the calendar (planner, #1346 review).
@Suite("CloudModels: one row per paid model, each with a current listed price (#1346)")
struct CloudModelsTests {
    private static func day(_ s: String) -> Date { CloudModels.parse(s)!.addingTimeInterval(12 * 3600) }

    /// A table of its own: one dated row, one undated, a price list from 2030-06-01.
    private static let fake = CloudModels.Catalog(
        rows: [CloudModels.Row(provider: .gemini, id: "gemini-3.8-flash", priceValidUntil: "2030-06-30"),
               CloudModels.Row(provider: .anthropic, id: "claude-opus-5-5")],
        asOf: "2030-06-01", prices: .snapshot)

    // MARK: the shipped table, structure only

    @Test("every shipped row resolves a price, its date parses, and each provider has exactly one bench primary")
    func shippedStructure() {
        for row in CloudModels.rows {
            #expect(EvalCost.rates(provider: row.provider, model: row.id) != nil, "\(row.id) has no snapshot price")
            if let until = row.priceValidUntil { #expect(CloudModels.parse(until) != nil, "\(row.id): \(until) is not yyyy-MM-dd") }
        }
        #expect(Set(CloudModels.rows.map { "\($0.provider)/\($0.id)" }).count == CloudModels.rows.count, "one row per model")
        for provider in Set(CloudModels.rows.map(\.provider)) where CloudModels.rows.contains(where: { $0.provider == provider && $0.bench != .no }) {
            #expect(CloudModels.rows.filter { $0.provider == provider && $0.bench == .primary }.count == 1, "\(provider)")
        }
        #expect(CloudModels.parse(ModelPriceSnapshot.asOf) != nil)
    }

    @Test("the bench takes gemini-4-hydrogen (primary, at medium), gemini-3.8-flash (#1351's baseline) and claude-opus-5-5")
    func benchModels() {
        #expect(BenchCloudTarget.allowed == ["gemini-4-hydrogen": .gemini, "gemini-3.8-flash": .gemini, "claude-opus-5-5": .anthropic])
        #expect(CloudModels.row(provider: .gemini, id: "gemini-4-hydrogen")?.bench == .primary)
        #expect(CloudModels.row(provider: .gemini, id: "gemini-4-hydrogen")?.thinkingLevel == "medium")
        #expect(CloudModels.row(provider: .gemini, id: "gemini-3.8-flash")?.bench == .allowed)
    }

    /// The snapshot is LiteLLM's table; Google's own page is the authority. "$1.50" input, "$7.50" output (thinking
    /// included), "$0.075" context caching, per 1M tokens, Standard paid tier: https://aistudio.google.com/docs/pricing,
    /// fetched 2026-11-23. A drift in a later re-pin shows up here, in review.
    @Test("the snapshot's gemini-4-hydrogen price is Google's listed one")
    func hydrogenMatchesTheDocs() throws {
        let r = try #require(EvalCost.rates(provider: .gemini, model: "gemini-4-hydrogen"))
        #expect(r.input == 1.5e-06 && r.output == 7.5e-06 && r.cacheRead == 7.5e-08, "\(r)")
    }

    // MARK: the rules, on a table of their own

    @Test("a listed model with a current price and a fresh list runs, through the last valid day")
    func currentRuns() {
        #expect(CloudModels.paidRefusal(provider: .gemini, id: "gemini-3.8-flash", now: Self.day("2030-06-02"), catalog: Self.fake) == nil)
        #expect(CloudModels.paidRefusal(provider: .gemini, id: "gemini-3.8-flash", now: Self.day("2030-06-30"), catalog: Self.fake) == nil)
        #expect(CloudModels.paidRefusal(provider: .anthropic, id: "claude-opus-5-5", now: Self.day("2030-07-16"), catalog: Self.fake) == nil,
                "day 45 of the list still runs")
    }

    @Test("refused: a model with no row, a price past its date, a list more than 45 days old")
    func refusals() throws {
        let noRow = try #require(CloudModels.paidRefusal(provider: .gemini, id: "gemini-made-up-9", now: Self.day("2030-06-02"), catalog: Self.fake))
        #expect(noRow.contains("not in CloudModels.rows") && noRow.contains("--max-dollars can't be enforced"))
        let dated = try #require(CloudModels.paidRefusal(provider: .gemini, id: "gemini-3.8-flash", now: Self.day("2030-07-01"), catalog: Self.fake))
        #expect(dated.contains("valid through 2030-06-30"), "\(dated)")
        let stale = try #require(CloudModels.paidRefusal(provider: .anthropic, id: "claude-opus-5-5", now: Self.day("2030-07-17"), catalog: Self.fake))
        #expect(stale.contains("more than 45 days ago"), "\(stale)")
    }

    @Test("a row the price list lacks is refused, not charged at a guess")
    func unpricedRowRefused() throws {
        let unpriced = CloudModels.Catalog(rows: Self.fake.rows, asOf: "2030-06-01", prices: PriceTable(parsing: ""))
        let why = try #require(CloudModels.paidRefusal(provider: .gemini, id: "gemini-3.8-flash", now: Self.day("2030-06-02"), catalog: unpriced))
        #expect(why.contains("no listed price for gemini/gemini-3.8-flash"))
    }

    @Test("a bench run past its row's date is refused before the ledger reserves anything")
    func benchReserveRefusesPastTheDate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1346b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("ledger.jsonl").path
        let ledger = try SpendLedger(path: path, arm: "a", cap: 3)
        let target = BenchCloudTarget(provider: .gemini, model: "gemini-3.8-flash", canary: .bypassed, maxDollars: 3, ledgerPath: path)
        guard case .refused(let why) = try BenchCloudTarget.reserveRun(target, in: ledger, now: Self.day("2030-07-01"), catalog: Self.fake) else {
            Issue.record("a run past its price date reserved"); return
        }
        #expect(why.contains("valid through 2030-06-30"))
        #expect(try ledger.total() == 0, "nothing reserved")
        guard case .reserved = try BenchCloudTarget.reserveRun(target, in: ledger, now: Self.day("2030-06-02"), catalog: Self.fake) else {
            Issue.record("a current run was refused"); return
        }
    }
}
