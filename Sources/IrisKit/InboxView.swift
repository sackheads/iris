import SwiftUI

/// The mailbox (#920 Task 5): the open items and the opened one's detail, with the response area
/// switched on `responseMode.inboxAffordance` (`InboxUIModel.swift`). Not a `Conversation` — its
/// selection lives on `AppState.selectedInboxItemId`, never `selectedConversationId`.
struct InboxView: View {
    let state: AppState

    @State private var chosenOptionId: String?
    @State private var freeText: String = ""
    @State private var lastOutcome: String?
    @State private var submitting = false

    private var items: [InboxItem] {
        (try? state.store.inbox.openItems()) ?? []
    }

    private var selected: InboxItem? {
        guard let id = state.selectedInboxItemId else { return nil }
        return items.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(
                get: { state.selectedInboxItemId },
                set: { newId in
                    state.selectedInboxItemId = newId
                    chosenOptionId = nil
                    freeText = ""
                    lastOutcome = nil
                }
            )) {
                ForEach(items, id: \.id) { item in
                    inboxRowSummary(item).tag(Optional(item.id))
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            .listStyle(.sidebar)

            Divider()

            if let item = selected {
                detail(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack {
                    Spacer()
                    Text(items.isEmpty ? "No open items." : "Select an item.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Inbox")
    }

    // MARK: List row

    private func inboxRowSummary(_ item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.title).font(.subheadline).lineLimit(1)
                Spacer()
                stateChip(for: item)
            }
            HStack(spacing: 6) {
                Text(item.emitterLabel).font(.caption2).foregroundColor(.secondary)
                Text("·").font(.caption2).foregroundColor(.secondary)
                Text(item.createdAt, style: .relative).font(.caption2).foregroundColor(.secondary)
            }
            Text(item.situation).font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func stateChip(for item: InboxItem) -> some View {
        let overdue = InboxUIModel.isOverdue(item, now: Date())
        return Text(overdue ? "Overdue" : item.state.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(overdue ? Color.red.opacity(0.8) : Color.secondary.opacity(0.25)))
            .foregroundColor(overdue ? .white : .secondary)
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(for item: InboxItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title).font(.title3.bold())
                HStack(spacing: 6) {
                    Text("from \(item.emitterLabel)").font(.caption).foregroundColor(.secondary)
                    if item.emitterTainted {
                        Label("read outside content", systemImage: "exclamationmark.shield")
                            .font(.caption2).foregroundColor(.orange)
                    }
                }

                Text(item.situation).font(.body)

                switch item.responseMode.inboxAffordance {
                case .optionsAndFreeform:
                    optionsSection(item)
                    freeTextSection(item, required: false)
                case .freeformOnly:
                    freeTextSection(item, required: true)
                case .timedVetoCountdown:
                    countdownSection(item)
                    optionsSection(item)
                    freeTextSection(item, required: false)
                case .dismissOnly:
                    EmptyView()
                }

                if let lastOutcome {
                    Text(lastOutcome).font(.caption).foregroundColor(.secondary)
                }

                footer(for: item)
            }
            .padding()
        }
        .id(item.id)
    }

    private func optionsSection(_ item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(item.options, id: \.id) { option in
                Button {
                    chosenOptionId = option.id
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: chosenOptionId == option.id ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label).font(.body)
                            if !option.pros.isEmpty {
                                Text("For: " + option.pros.joined(separator: ", ")).font(.caption).foregroundColor(.green)
                            }
                            if !option.cons.isEmpty {
                                Text("Against: " + option.cons.joined(separator: ", ")).font(.caption).foregroundColor(.red)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func freeTextSection(_ item: InboxItem, required: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(required ? "Your answer" : "Or write your own").font(.caption).foregroundColor(.secondary)
            TextEditor(text: $freeText)
                .frame(minHeight: 60, maxHeight: 120)
                .font(.body)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            routingDisclosure(item)
            Button(submitting ? "Submitting…" : "Submit") { submit(item) }
                .disabled(submitting || (chosenOptionId == nil && freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        }
    }

    /// Where Submit sends Brian's answer, shown immediately above the button — at the moment of
    /// deciding, not after. `routeBack` is the *emitter's* own text (#920 spec), and
    /// `submitInboxAnswer` routes Brian's answer, under his user authority, to exactly those
    /// targets: an emitter can name any session, so this is informed consent, not a courtesy
    /// (planner, #920 Task 5 security requirement; dev-3's #936 review of the hazard). Falls back
    /// to the emitter itself, matching `submitInboxAnswer`'s own fallback when `routeBack` is empty.
    private func routingDisclosure(_ item: InboxItem) -> some View {
        let targets = InboxUIModel.answerRouteTargets(item)
        return VStack(alignment: .leading, spacing: 2) {
            Label("Your answer, with your authority, goes to: \(targets.joined(separator: ", "))",
                  systemImage: "arrow.turn.up.right")
                .font(.caption.weight(.semibold))
            if !item.notify.isEmpty {
                Text("Also notifying: \(item.notify.joined(separator: ", "))")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func countdownSection(_ item: InboxItem) -> some View {
        let overdue = InboxUIModel.isOverdue(item, now: Date())
        return HStack {
            Image(systemName: overdue ? "exclamationmark.triangle.fill" : "clock")
                .foregroundColor(overdue ? .red : .secondary)
            if let deadline = item.deadline {
                Text(overdue
                     ? (item.emitterTainted ? "Past deadline — held for review (read outside content)." : "Past deadline.")
                     : "Default applies \(Text(deadline, style: .relative)) from now.")
                    .font(.caption)
                    .foregroundColor(overdue ? .red : .secondary)
            }
        }
    }

    private func footer(for item: InboxItem) -> some View {
        Group {
            if item.responseMode == .notification {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                    Button("Dismiss") { dismiss(item) }
                        .disabled(submitting)
                }
            }
        }
    }

    // MARK: Actions

    private func submit(_ item: InboxItem) {
        submitting = true
        let choice = chosenOptionId
        let text = freeText
        Task {
            let outcome = await state.engine.submitInboxAnswer(itemId: item.id, choice: choice, freeText: text)
            await MainActor.run {
                submitting = false
                lastOutcome = Self.describe(outcome)
                if case .refused = outcome { } else { state.selectedInboxItemId = nil }
            }
        }
    }

    /// Notification items take no answer (`submitInboxAnswer` refuses them, by design), so
    /// dismissing one closes it directly rather than routing through the answer path.
    private func dismiss(_ item: InboxItem) {
        submitting = true
        Task {
            _ = try? state.store.inbox.setState(itemId: item.id, .closed)
            await MainActor.run {
                submitting = false
                state.selectedInboxItemId = nil
            }
        }
    }

    private static func describe(_ outcome: IrisEngine.InboxSubmitOutcome) -> String {
        switch outcome {
        case .delivered(let n): return "Delivered to \(n) session\(n == 1 ? "" : "s")."
        case .awaitingDelivery: return "Recorded. Waiting for a live session to deliver to."
        case .mixed(let delivered, let awaiting): return "Delivered to \(delivered), waiting on \(awaiting) more."
        case .refused(let reason): return reason
        }
    }
}
