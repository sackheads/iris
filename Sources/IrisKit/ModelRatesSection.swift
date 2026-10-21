import SwiftUI

/// Settings → Models → Subagent providers → Prices (#239 3c): what each model a subagent or the
/// primary can use is charged at in a job run, where that price comes from, and a typed rate to
/// set it. A typed rate is a guarded setting; a lower delegated (or higher primary) rate than the
/// snapshot's is held to its bound and shown as clamped.
struct ModelRatesSection: View {
    @Bindable var config: ConfigManager
    let registry: [RegisteredProvider]
    var book: PriceBook = .shared
    var refresher: ModelPriceRefresher = .shared

    @State private var editing: RateDraft?
    @State private var revision = 0
    @State private var checking = false
    @State private var status: ModelPriceRefresher.Status = .never

    struct Row: Identifiable {
        let key: String
        let label: String
        let model: String
        let family: String?
        let side: PriceSide
        let loopback: Bool
        var id: String { key }
    }

    /// The sentence the editor shows when a typed rate couldn't be kept.
    static let notSaved = "Not saved: Iris couldn't read its Keychain item at launch, so it can't keep a typed rate. The price list's rate still applies."

    var body: some View {
        let _ = revision
        let typed = config.subagentRates
        Section(header: Text("Prices").font(.headline)) {
            Text("In a job run, a subagent on another model is charged at that model's price, converted to the primary's weighted tokens. Prices come from LiteLLM's public list, fetched daily, or the copy bundled with Iris; a rate you type here replaces them.")
                .font(.caption).foregroundColor(.secondary)
            ForEach(rows()) { row in rateRow(row, typed: typed) }
            HStack {
                Button(checking ? "Checking prices…" : "Check prices now") { checkNow() }
                    .disabled(checking)
                Text(Self.statusText(status)).font(.caption).foregroundColor(.secondary)
            }
        }
        .onAppear { status = refresher.status }
        .sheet(item: $editing) { draft in
            RateEditor(draft: draft) { rates in
                var all = config.subagentRates
                all[draft.row.key] = rates
                config.subagentRates = all
                // Read back (#733 review): with the Keychain item unreadable the guarded write is
                // blocked, and closing as if it were set would leave the price list's rate in force.
                guard config.subagentRates[draft.row.key] == rates else { return Self.notSaved }
                book.setTyped(config.subagentRates)
                revision += 1
                return nil
            }
        }
    }

    /// The primary's tier models, then each usable subagent provider's models.
    func rows() -> [Row] {
        let primary = LLMProvider(rawValue: config.primaryProvider) ?? .gemini
        var out = config.tierModels(of: primary).uniqued().map {
            Row(key: TypedRates.primaryKey(model: $0), label: "Primary", model: $0, family: PriceFamily.of(primary),
                side: .primary, loopback: false)
        }
        for provider in registry where provider.usable && !provider.isPrimary {
            let endpoint = config.subagentEndpoints.first { $0.id == provider.id }
            let family = provider.isBuiltIn ? LLMProvider.allCases.first { ProviderSlug.id(of: $0) == provider.id }.map(PriceFamily.of)
                : endpoint.flatMap { $0.priceFamily ?? PriceFamily.forHost(of: $0.baseURL) }
            let loopback = endpoint.map { PriceFamily.isLoopback($0.baseURL) } ?? false
            out += provider.models.map {
                Row(key: TypedRates.key(providerId: provider.id, model: $0), label: provider.name, model: $0, family: family,
                    side: .delegated, loopback: loopback)
            }
        }
        return out
    }

    private func rateRow(_ row: Row, typed: [String: TokenRates]) -> some View {
        let rate = book.resolve(family: row.family, model: row.model, side: row.side, loopback: row.loopback,
                                endpointName: row.family == nil ? row.label : nil, typedKey: row.key)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.label).font(.body.bold())
                Text(row.model).font(.caption.monospaced())
                Spacer()
                if !row.loopback {
                    Button("Set rate…") { editing = RateDraft(row: row, current: typed[row.key] ?? rate.rates) }
                    if typed[row.key] != nil {
                        Button("Clear") {
                            var all = config.subagentRates
                            all[row.key] = nil
                            config.subagentRates = all
                            book.setTyped(config.subagentRates)
                            revision += 1
                        }
                    }
                }
            }
            Text(row.loopback ? "A server on this Mac: no charge of its own; its tokens count at the primary's weights."
                 : Self.rateText(rate.rates) + " · " + Self.sourceText(rate))
                .font(.caption).foregroundColor(rate.estimated ? .orange : .secondary)
        }
    }

    private func checkNow() {
        checking = true
        Task {
            status = await refresher.refreshNow()
            checking = false
            revision += 1
        }
    }

    static func perMTok(_ x: Double) -> String { String(format: "$%.4g", x * 1_000_000) }

    static func rateText(_ r: TokenRates) -> String {
        "in \(perMTok(r.input)) · out \(perMTok(r.output)) · cache read \(perMTok(r.cacheRead)) per MTok"
    }

    static func sourceText(_ r: ResolvedRate) -> String {
        let base: String
        switch r.source {
        case .litellm, .openrouter: base = "fetched" + (r.asOf.map { " \($0)" } ?? "")
        case .snapshot: base = "bundled list" + (r.asOf.map { " of \($0)" } ?? "")
        case .settings: base = "your rate"
        case .settingsClamped: base = "your rate, held to its bound"
        case .fallback: base = "no known rate"
        case .loopback: base = "this Mac"
        }
        return r.estimated ? base + ", estimated" + (r.note.map { ": \($0)" } ?? "") : base
    }

    static func statusText(_ s: ModelPriceRefresher.Status) -> String {
        switch s {
        case .never: "Not fetched since launch."
        case .fetched(let asOf): "Fetched \(asOf)."
        case .failed(let why): why
        }
    }
}

struct RateDraft: Identifiable {
    let row: ModelRatesSection.Row
    var input: String
    var output: String
    var cacheRead: String
    var id: String { row.key }

    init(row: ModelRatesSection.Row, current: TokenRates) {
        self.row = row
        input = Self.text(current.input)
        output = Self.text(current.output)
        cacheRead = Self.text(current.cacheRead)
    }

    static func text(_ perToken: Double) -> String { String(format: "%g", perToken * 1_000_000) }

    /// The typed figures as per-token rates, or nil when one isn't a number or breaks a field rule.
    var rates: TokenRates? {
        func parse(_ s: String) -> Double? {
            Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")).map { $0 / 1_000_000 }
        }
        guard let i = parse(input), let o = parse(output), let r = parse(cacheRead) else { return nil }
        let rates = TokenRates(input: i, output: o, cacheRead: r, cacheWrite: nil)
        return PriceGuards.fieldsValid(rates) ? rates : nil
    }

    /// What the rate will actually be charged at, and whether its bound moved it.
    var charged: (rates: TokenRates, clamped: Bool)? {
        rates.map { TypedRates.clamp($0, side: row.side, snapshotRow: row.family.flatMap { PriceTable.snapshot.rate(family: $0, model: row.model) }) }
    }
}

private struct RateEditor: View {
    @State var draft: RateDraft
    /// Saves, or says why it couldn't; the sheet stays open then.
    let save: (TokenRates) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var refusal: String?

    var body: some View {
        Form {
            Text("\(draft.row.label) · \(draft.row.model)").font(.headline)
            Text("Dollars per million tokens.").font(.caption).foregroundColor(.secondary)
            TextField("Input", text: $draft.input)
            TextField("Output", text: $draft.output)
            TextField("Cache read", text: $draft.cacheRead)
            if let charged = draft.charged {
                if charged.clamped {
                    Text("Held to its bound: charged at " + ModelRatesSection.rateText(charged.rates) + ".")
                        .font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if TypedRates.lowersBudgetUse(charged.rates, family: draft.row.family, side: draft.row.side, model: draft.row.model) {
                    Text(draft.row.side == .delegated ? TypedRates.lowersBudgetWarning : TypedRates.lowersSubagentBudgetWarning)
                        .font(.caption).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Every rate must be a number above zero, and cache read no more than input.")
                    .font(.caption).foregroundColor(.red)
            }
            if let refusal {
                Text(refusal).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    guard let rates = draft.rates else { return }
                    refusal = save(rates)
                    if refusal == nil { dismiss() }
                }
                .disabled(draft.rates == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
