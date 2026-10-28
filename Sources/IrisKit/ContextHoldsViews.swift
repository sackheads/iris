import SwiftUI

/// #813: the composer chip for standing-context writes held in this conversation. It shows at
/// the end of a turn, never mid-turn, and lists each item's first line so that approving a batch
/// is a glance, not blind. Height-capped (Invariant 8).
struct ContextHoldsChip: View {
    let state: AppState
    let conversationId: UUID
    @State private var reviewing = false

    private var items: [PendingContextWrite] { state.pendingContextWrites(shownIn: conversationId) }

    var body: some View {
        ScrollView { content }
            .frame(maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.orange.opacity(0.08))
            .cornerRadius(8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(items.count) memory change\(items.count == 1 ? "" : "s") waiting for your OK")
            .sheet(isPresented: $reviewing) {
                ContextHoldsReview(state: state, conversationId: conversationId) { reviewing = false }
            }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.raised").foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(items.count) memory change\(items.count == 1 ? "" : "s") waiting for your OK")
                    .font(.caption.bold())
                Text("This conversation read text from outside, so changes to what Iris remembers wait for you.")
                    .font(.caption2).foregroundColor(.secondary)
                ForEach(items) { item in
                    Text(verbatim: "• \(item.firstLine)").font(.caption2).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Button("Approve all") { Task { await state.approveAllContextWrites(shownIn: conversationId) } }
                Button("Review…") { reviewing = true }
            }
        }
        .padding(8)
    }
}

/// #813: every held item in full, approved or declined one at a time. An item whose target
/// changed since it was held says so and needs its own "Replace current".
struct ContextHoldsReview: View {
    let state: AppState
    let conversationId: UUID
    let done: () -> Void
    @State private var changed: Set<UUID> = []

    private var items: [PendingContextWrite] { state.pendingContextWrites(shownIn: conversationId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Memory changes waiting for your OK").font(.headline)
            Text("This conversation read text that you and Iris didn't write, such as a web page, a file or a command's output. Text like that can carry instructions, so changes it could have caused to SOUL, your profile, memory, facts, skills or rules are kept here until you decide.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if items.isEmpty {
                        Text("Nothing is waiting.").foregroundColor(.secondary)
                    }
                    ForEach(items) { item in row(item) }
                }
            }
            .frame(maxHeight: 520)
            HStack {
                Button("Decline all") { state.rejectAllContextWrites(shownIn: conversationId) }
                Spacer()
                Button("Approve all") { Task { await state.approveAllContextWrites(shownIn: conversationId) } }
                Button("Done") { done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520)
    }

    private func row(_ item: PendingContextWrite) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: item.firstLine).font(.callout.bold())
            if let body = Self.preview(item) {
                Text(verbatim: body)
                    .font(.caption.monospaced())
                    .lineLimit(12)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(4)
            }
            if changed.contains(item.id) {
                Text("This file changed after the change was proposed. Approving replaces what's there now.")
                    .font(.caption).foregroundColor(.orange)
            }
            HStack {
                Button("Decline") { state.rejectContextWrite(item.id) }
                if changed.contains(item.id) {
                    Button("Replace current") { Task { await state.approveContextWrite(item.id, replacingChanged: true) } }
                } else {
                    Button("Approve") {
                        Task {
                            if await state.approveContextWrite(item.id) == .targetChanged { changed.insert(item.id) }
                        }
                    }
                }
            }
        }
    }

    /// The text the change would write, or what a delete would remove.
    static func preview(_ item: PendingContextWrite) -> String? {
        if item.toolName == "delete_skill" {
            return item.targetPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        }
        for key in ["content", "body", "description"] {
            if let text = item.args[key]?.stringValue, !text.isEmpty { return text }
        }
        return nil
    }
}
