import SwiftUI

/// Settings → Advanced → "Goal Workspaces" (#126). Manual, per-item cleanup only — no automatic
/// sweep this slice. Eligibility is scoped to `IrisPaths.default.workspacesDir`: only directories
/// directly under that root are ever listed, because `GoalWorkspace.resolve` confines creation to
/// it (see `WorkspaceInventory`).
@MainActor
struct GoalWorkspacesSection: View {
    let state: AppState

    @State private var entries: [WorkspaceEntry] = []
    @State private var sizesByURL: [URL: Int64] = [:]
    @State private var confirmingDelete: WorkspaceEntry?
    @State private var confirmingDeleteAllOrphans = false
    @State private var actionError: String?

    private var orphanCount: Int { entries.filter(\.isOrphan).count }

    var body: some View {
        Section(header: Text("Goal Workspaces").font(.headline)) {
            if entries.isEmpty {
                Text("No goal workspaces")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    row(for: entry)
                }
            }

            HStack {
                Button("Refresh") { refresh() }
                if orphanCount > 0 {
                    Button("Delete all orphans…", role: .destructive) { confirmingDeleteAllOrphans = true }
                }
                Spacer()
            }

            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { refresh() }
        .confirmationDialog(
            confirmingDelete.map { "Delete “\($0.name)”? It will be moved to the Trash." } ?? "",
            isPresented: Binding(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } })
        ) {
            if let entry = confirmingDelete {
                Button("Move to Trash", role: .destructive) { delete(entry) }
            }
        }
        .confirmationDialog(
            "Delete \(orphanCount) orphaned workspace\(orphanCount == 1 ? "" : "s")? They will be moved to the Trash.",
            isPresented: $confirmingDeleteAllOrphans
        ) {
            Button("Move to Trash", role: .destructive) { deleteAllOrphans() }
        }
    }

    @ViewBuilder
    private func row(for entry: WorkspaceEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).fontWeight(.medium)
                HStack(spacing: 6) {
                    if entry.isOrphan {
                        Text("orphan")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .clipShape(Capsule())
                    } else if let title = entry.ownerTitle {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let modifiedAt = entry.modifiedAt {
                        Text(modifiedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(sizeText(for: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Delete", role: .destructive) { confirmingDelete = entry }
                .disabled(entry.ownerHasActiveGoal)
                .help(entry.ownerHasActiveGoal
                      ? "This workspace's goal is still active — stop it before deleting."
                      : "Move this workspace to the Trash.")
        }
    }

    private func sizeText(for entry: WorkspaceEntry) -> String {
        guard let bytes = sizesByURL[entry.url] else { return "…" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func refresh() {
        let conversations = state.conversations.map {
            (id: $0.id, title: $0.title, workspacePath: $0.workspacePath, activeGoal: $0.activeGoal)
        }
        entries = WorkspaceInventory.scan(root: IrisPaths.default.workspacesDir, conversations: conversations)
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        for entry in entries {
            loadSize(for: entry.url)
        }
    }

    /// Runs the filesystem walk off the main actor via `Task.detached`, then hops back to publish
    /// the result — `scan` itself never computes size, exactly so this can stay off the render path.
    private func loadSize(for url: URL) {
        guard sizesByURL[url] == nil else { return }
        Task {
            let size = await Task.detached { WorkspaceInventory.directorySize(url) }.value
            sizesByURL[url] = size
        }
    }

    private func delete(_ entry: WorkspaceEntry) {
        confirmingDelete = nil
        do {
            let outcome = try state.deleteWorkspace(entry)
            switch outcome {
            case .trashed:
                actionError = nil
            case .refusedActiveGoal(let title):
                actionError = "\(title)'s goal is still active; stop it before deleting this workspace."
            case .refusedOutsideRoot:
                actionError = "Could not delete \(entry.name): it is no longer inside the workspaces folder."
            }
        } catch {
            actionError = "Could not delete \(entry.name): \(error.localizedDescription)"
        }
        refresh()
    }

    /// Re-scans against LIVE `state.conversations` immediately before deleting anything: the
    /// `entries` snapshot this section renders from is only as fresh as the last appear/Refresh, so
    /// a workspace a new or renamed goal adopted in the meantime must not be trashed just because
    /// it still reads as an orphan in that stale snapshot (review finding, round 1).
    private func deleteAllOrphans() {
        confirmingDeleteAllOrphans = false
        let candidateURLs = Set(entries.filter(\.isOrphan).map(\.url))
        guard !candidateURLs.isEmpty else { return }

        let liveConversations = state.conversations.map {
            (id: $0.id, title: $0.title, workspacePath: $0.workspacePath, activeGoal: $0.activeGoal)
        }
        let liveEntries = WorkspaceInventory.scan(root: IrisPaths.default.workspacesDir, conversations: liveConversations)
        let liveByURL = Dictionary(uniqueKeysWithValues: liveEntries.map { ($0.url, $0) })

        var trashedCount = 0
        var failedNames: [String] = []
        var adoptedNames: [String] = []

        for url in candidateURLs {
            guard let liveEntry = liveByURL[url] else { continue } // vanished since the snapshot; nothing to do
            guard liveEntry.isOrphan else {
                adoptedNames.append(liveEntry.name)
                continue
            }
            do {
                if case .trashed = try state.deleteWorkspace(liveEntry) {
                    trashedCount += 1
                } else {
                    // Shouldn't happen for a confirmed orphan straight out of `liveEntries`, but
                    // don't silently swallow a refusal if it ever does.
                    failedNames.append(liveEntry.name)
                }
            } catch {
                failedNames.append(liveEntry.name)
            }
        }

        var summary = "\(trashedCount) of \(candidateURLs.count) moved to the Trash"
        if !failedNames.isEmpty { summary += "; failed: \(failedNames.joined(separator: ", "))" }
        if !adoptedNames.isEmpty { summary += "; skipped (no longer orphaned): \(adoptedNames.joined(separator: ", "))" }
        actionError = (failedNames.isEmpty && adoptedNames.isEmpty) ? nil : summary
        refresh()
    }
}
