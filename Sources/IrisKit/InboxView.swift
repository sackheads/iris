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

    /// Open items, needing attention, then awaiting-delivery ones (answered, but with no live
    /// recipient yet) so an answered item does not simply vanish once Brian has acted on it
    /// (dev-3's #943 review finding 3). `inboxRevision` is read so a write anywhere else (an
    /// emit, a submit, a redeliver) invalidates this rather than leaving it stale (finding 2).
    private var items: [InboxItem] {
        _ = state.inboxRevision
        return InboxUIModel.mailboxItems(open: (try? state.store.inbox.openItems()) ?? [],
                                         awaitingDelivery: (try? state.store.inbox.awaitingDeliveryItems()) ?? [])
    }

    private var selected: InboxItem? {
        guard let id = state.selectedInboxItemId else { return nil }
        return items.first { $0.id == id }
    }

    var body: some View {
        // HSplitView draws its own draggable divider, so the explicit Divider() below is gone
        // (#920: Brian wants the items pane horizontally resizable). The list keeps a minWidth so
        // it can't be dragged to nothing, and the old 360 maxWidth cap is dropped so the drag has
        // somewhere to go; the detail pane gets its own minWidth so a wide list can't crush it.
        HSplitView {
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
            .frame(minWidth: 240, idealWidth: 280)
            .listStyle(.sidebar)
            // The divider comes back where it was left (#1027).
            .background(SplitDividerPersistence(key: "inboxListWidth", minimum: 240))

            // One stable view in this HSplitView slot, not an if/else swapping two view
            // identities in it — the latter can make the NSSplitView it bridges to re-derive
            // (and reset) the divider position the first time the branch flips (dev-3's #987
            // review). The frame is applied once, outside the content switch.
            Group {
                if let item = selected {
                    detail(for: item).frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    VStack {
                        Spacer()
                        Text(items.isEmpty ? "No open items." : "Select an item.")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // A follow-up replaces the question under the same item id, so a choice or text meant for
        // the old one must not stay armed for the new (dev-3's #1028 review).
        .onChange(of: selected?.lastActivityAt) {
            chosenOptionId = nil
            freeText = ""
            lastOutcome = nil
        }
        .navigationTitle("Inbox")
    }

    // MARK: List row

    private func inboxRowSummary(_ item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if item.isUnread {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                        .accessibilityLabel("Unread")
                }
                Text(item.title).font(.subheadline.weight(item.isUnread ? .semibold : .regular)).lineLimit(1)
                Spacer()
                stateChip(for: item)
            }
            HStack(spacing: 6) {
                Text(senderName(item)).font(.caption2).foregroundColor(.secondary)
                Text("·").font(.caption2).foregroundColor(.secondary)
                Text(item.createdAt, style: .relative).font(.caption2).foregroundColor(.secondary)
            }
            Text(item.situation).font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func emitterConversation(_ item: InboxItem) -> Conversation? {
        state.conversations.first { $0.id == item.emitter }
    }

    private func senderName(_ item: InboxItem) -> String {
        InboxUIModel.senderName(of: item, conversationTitle: emitterConversation(item)?.title)
    }

    /// "from <name>", which opens the session that raised the item while it still exists.
    @ViewBuilder
    private func fromLabel(_ item: InboxItem) -> some View {
        if let conv = emitterConversation(item), !conv.isArchived {
            Button("from \(senderName(item))") { state.selectConversation(conv.id) }
                .buttonStyle(.link).font(.caption)
                .help("Open the session that raised this")
        } else {
            Text("from \(senderName(item)) (session closed)").font(.caption).foregroundColor(.secondary)
        }
    }

    private func stateChip(for item: InboxItem) -> some View {
        let overdue = InboxUIModel.isOverdue(item, now: Date())
        return Text(overdue ? "Overdue" : stateLabel(item.state))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(overdue ? Color.red.opacity(0.8) : Color.secondary.opacity(0.25)))
            .foregroundColor(overdue ? .white : .secondary)
    }

    private func stateLabel(_ state: InboxItemState) -> String {
        switch state {
        case .open: return "Open"
        case .answered: return "Answered"
        case .awaitingDelivery: return "Awaiting delivery"
        case .closed: return "Closed"
        case .stale: return "Stale"
        }
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(for item: InboxItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title).font(.title3.bold())
                HStack(spacing: 6) {
                    fromLabel(item)
                    if item.emitterTainted {
                        Label("read outside content", systemImage: "exclamationmark.shield")
                            .font(.caption2).foregroundColor(.orange)
                    }
                }

                Text(item.situation).font(.body)

                // #943 review finding 3: awaitingDeliveryItems() surfaces an item Brian already
                // answered (no live recipient yet) so it doesn't vanish — but it is read-only
                // here: re-offering the response area would invite submitting a second answer,
                // which `submitInboxAnswer` would only refuse (`.notAnswerable`), confusingly.
                if item.state == .open {
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
                } else if let answer = item.answer {
                    answeredSummary(answer, item: item)
                }

                historySection(item)

                if let lastOutcome {
                    Text(lastOutcome).font(.caption).foregroundColor(.secondary)
                }

                footer(for: item)
            }
            .padding()
        }
        .id(item.id)
        // Looking at it is what reads it; a follow-up that lands while it is open changes
        // `lastActivityAt`, which runs this again.
        .task(id: item.lastActivityAt) { markViewed(item) }
    }

    private func markViewed(_ item: InboxItem) {
        guard item.isUnread else { return }
        try? state.store.inbox.markViewed(itemId: item.id, at: Date())
        state.bumpInboxRevision()
    }

    /// The thread before the current ask: the original question, answers and follow-ups, oldest
    /// first (#1024). Only drawn once there is something earlier than what is already on screen:
    /// a follow-up replaces the item's title, situation and options with its own, so without this
    /// Brian would never see what was asked or answered before.
    @ViewBuilder
    private func historySection(_ item: InboxItem) -> some View {
        let entries = historyEntries(item)
        if !entries.isEmpty {
            DisclosureGroup("History (\(entries.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries, id: \.seq) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(InboxUIModel.historyKindLabel(entry.kind)).font(.caption.weight(.semibold))
                                Text(entry.at, style: .relative).font(.caption2).foregroundColor(.secondary)
                            }
                            Text(entry.body).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    /// `inboxRevision` is read so a follow-up or an answer written elsewhere redraws the history.
    private func historyEntries(_ item: InboxItem) -> [InboxThreadEntry] {
        _ = state.inboxRevision
        return InboxUIModel.history(of: (try? state.store.inbox.thread(itemId: item.id)) ?? [])
    }

    /// A read-only summary of Brian's own answer, for an item no longer `.open` (finding 3).
    private func answeredSummary(_ answer: InboxAnswer, item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let chosen = answer.chosenOptionId, let option = item.options.first(where: { $0.id == chosen }) {
                Text("You chose: \(option.label)").font(.body)
            }
            if let text = answer.freeText {
                Text("You wrote: \(text)").font(.body)
            }
        }
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
    /// deciding, not after. `routeBack` is the *emitter's* own text (#920 spec), and an emitter
    /// could aim Brian's decision at an arbitrary session, so this is informed consent, not a
    /// courtesy (planner, #920 Task 5 security requirement; dev-3's #936 review of the hazard).
    /// Reads `IrisEngine.inboxHumanRouteTargets`/`inboxNotifyTargets` — the single authoritative
    /// resolvers `submitInboxAnswer` itself uses (#944) — rather than re-deriving the rule here,
    /// so the disclosure cannot drift from the real routing or show a label the emitter chose
    /// (dev-3's #943 review finding 1).
    private func routingDisclosure(_ item: InboxItem) -> some View {
        let targets = IrisEngine.inboxHumanRouteTargets(item: item).map { routeDescription($0, item: item) }
        let notify = IrisEngine.inboxNotifyTargets(item: item).map { routeDescription($0, item: item) }
        return VStack(alignment: .leading, spacing: 2) {
            Label("Your answer, with your authority, goes to: \(targets.joined(separator: ", "))",
                  systemImage: "arrow.turn.up.right")
                .font(.caption.weight(.semibold))
            if !notify.isEmpty {
                Text("Also notifying: \(notify.joined(separator: ", "))")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    /// Resolves a role target to its current holder's own label (the emitter case needs no
    /// resolution — `item.emitterLabel` already has it) and hands the wording itself to
    /// `InboxUIModel.routeTargetDescription`, which is the pure, tested half (SwiftUI-free, same
    /// split as the rest of this file).
    private func routeDescription(_ target: String, item: InboxItem) -> String {
        let role = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .hasPrefix("role:") ? String(target.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(5)) : nil
        let holderLabel = role.flatMap { role in
            SessionRoles.holder(of: role, in: state.conversations)
                .flatMap { id in state.conversations.first { $0.id == id }?.sessionCard?.name }
        }
        return InboxUIModel.routeTargetDescription(target, emitterId: item.emitter, emitterLabel: item.emitterLabel,
                                                    roleHolderLabel: holderLabel)
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
                state.bumpInboxRevision()
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
