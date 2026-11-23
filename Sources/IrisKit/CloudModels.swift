import Foundation

/// #1346: the cloud models a paid run may call (`iris --eval`, `iris --bench --cloud-primary`, `iris --guard-probe`),
/// one row each, so a new model is one row here plus a re-pin of the price snapshot, not three edits. A paid run
/// needs the model's row, its listed price (`ModelPriceSnapshot`), and a price that is still current: either
/// missing, or past `priceValidUntil`, or a snapshot older than `maxSnapshotAgeDays`, refuses the run before any
/// call, because `--max-dollars` can only cap what the ledger is told a call costs. A stale price under-caps: the
/// list price of gemini-4-argon doubles on 2026-12-01, and the snapshot would still charge the old one (#1350).
///
/// IDs and dates from the providers' own pages, fetched 2026-11-23: https://aistudio.google.com/docs/pricing and
/// https://aistudio.google.com/docs/models (Gemini), https://platform.claude.com/docs/en/about-claude/models/overview
/// (Claude). A model the snapshot has no row for can't be listed here: `CloudModelsTests` pins that every row
/// resolves a price.
enum CloudModels {
    /// What `--bench --cloud-primary` makes of a model: its budget was calibrated on these (#916, bench854).
    enum Bench: Equatable, Sendable {
        case no
        /// Accepted, but not the default: a baseline arm (#1351 compares Hydrogen against 3.8-flash).
        case allowed
        /// The provider's default bench model; one per provider.
        case primary
    }

    struct Row: Equatable, Sendable {
        let provider: LLMProvider
        let id: String
        /// The last day the snapshot's price is the list price, as `yyyy-MM-dd`; nil when no change is announced.
        var priceValidUntil: String? = nil
        var bench: Bench = .no
        /// The Gemini thinking level a bench or probe run asks for when none is named, or nil for the provider's.
        var thinkingLevel: String? = nil
    }

    /// The rows, and the date of the price list they are checked against. Injectable, so the expiry and age logic is
    /// tested on a table of its own and the shipped one is never compared against a clock (planner, #1346 review).
    struct Catalog: Sendable {
        var rows: [Row]
        /// `ModelPriceSnapshot.asOf` for the shipped table.
        var asOf: String
        var prices: PriceTable

        func row(provider: LLMProvider, id: String) -> Row? {
            rows.first { $0.provider == provider && $0.id == id }
        }
    }

    static let shipped = Catalog(rows: rows, asOf: ModelPriceSnapshot.asOf, prices: .snapshot)

    static let rows: [Row] = [
        // Brian, 2026-11-23: "Switch to hydrogen, effort medium" for paid bench and probe runs. "$1.50" input, "$7.50"
        // output, no dated change announced (`CloudModelsTests` pins the snapshot's row to those).
        Row(provider: .gemini, id: "gemini-4-hydrogen", bench: .primary, thinkingLevel: "medium"),
        Row(provider: .gemini, id: "gemini-4-neon"),
        // "$2.00 through November 30, 2026." / "$4.00 starting December 1, 2026." (input; output $10 to $20)
        Row(provider: .gemini, id: "gemini-4-argon", priceValidUntil: "2026-11-30"),
        Row(provider: .gemini, id: "gemini-4-carbon", priceValidUntil: "2026-11-30"),
        // "$0.75 through December 31, 2026." / "$1.50 starting January 1, 2027." (input; output $3.75 to $7.50).
        // Still a bench arm: #1351's baseline.
        Row(provider: .gemini, id: "gemini-3.8-flash", priceValidUntil: "2026-12-31", bench: .allowed),
        Row(provider: .gemini, id: "gemini-3.6-flash", priceValidUntil: "2026-12-31"),
        Row(provider: .gemini, id: "gemini-3.5-flash-lite"),
        Row(provider: .anthropic, id: "claude-fable-5-2"),
        Row(provider: .anthropic, id: "claude-opus-5-5", bench: .primary),
        Row(provider: .anthropic, id: "claude-sonnet-5-5"),
        Row(provider: .anthropic, id: "claude-haiku-5-5"),
    ]

    /// A snapshot older than this refuses every paid run: prices move, and an old one may under-charge.
    static let maxSnapshotAgeDays = 45

    static func row(provider: LLMProvider, id: String) -> Row? { shipped.row(provider: provider, id: id) }

    /// Why a paid run on `provider`'s `id` must not start, or nil.
    static func paidRefusal(provider: LLMProvider, id: String, now: Date = Date(), catalog: Catalog = shipped) -> String? {
        let name = "\(provider.rawValue.lowercased())/\(id)"
        let cap = "--max-dollars can't be enforced without a current listed price, so the run is refused."
        let fix = "The price list (Sources/IrisKit/ModelPriceSnapshot.swift, a snapshot of LiteLLM's table) is generated, not edited: move the pin in scripts/gen-model-prices.py (--commit <sha> --as-of <date>) to a LiteLLM commit with current prices and rerun it"
        guard let row = catalog.row(provider: provider, id: id) else {
            return "\(name) is not in CloudModels.rows (Sources/IrisKit/CloudModels.swift), the models a paid run may call: \(cap) Add a row for it there; its price must also be in the price list, and if it isn't: \(fix)."
        }
        guard EvalCost.rates(provider: provider, model: id, table: catalog.prices) != nil else {
            return "no listed price for \(name): \(cap) \(fix)."
        }
        let today = day(now)
        if let until = row.priceValidUntil, today > until {
            return "the listed price for \(name) was valid through \(until), and the provider has changed it since: \(cap) \(fix), then update the row's priceValidUntil."
        }
        if let asOfDate = parse(catalog.asOf), let limit = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: maxSnapshotAgeDays, to: asOfDate), today > day(limit) {
            return "the price list is from \(catalog.asOf), more than \(maxSnapshotAgeDays) days ago: \(cap) \(fix)."
        }
        return nil
    }

    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    static func day(_ date: Date) -> String { formatter().string(from: date) }
    static func parse(_ day: String) -> Date? { formatter().date(from: day) }
}
