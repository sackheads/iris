import AppKit
import SwiftUI

/// #1397: Settings → Security's per-library guard choice. The only writer of `config/library-guard.json`: a turn
/// can't reach it (a protected write), and nothing reads `EXTERNAL_LIBRARIES.md` for it.
struct LibraryGuardSettingsSection: View {
    var store: LibraryGuardStore = .shared
    @State private var entries: [LibraryGuardStore.Entry] = []
    @State private var unreadable = false
    @State private var failure: String?

    var body: some View {
        Section(header: Text("Libraries: how notes you keep are checked").font(.headline)) {
            Text("For folders of notes you wrote yourself, such as an Obsidian vault. A note read from one is still "
                 + "treated as outside text; this only chooses who runs the Tier 3 check, for notes read with read_file. "
                 + "Command output (cat, grep) is checked by the Tier 3 engine above.")
                .font(.caption).foregroundColor(.secondary)
            if unreadable {
                Text("library-guard.json can't be read, so every tool result is checked on this Mac only until it's "
                     + "fixed. Remove it from \(IrisPaths.standard.agentFacing("~/.iris/config/")) or add a library again to rewrite it.")
                    .font(.caption).foregroundColor(.red)
            }
            ForEach(entries, id: \.root) { entry in
                HStack {
                    Text(entry.root).lineLimit(1).truncationMode(.middle).help(entry.root)
                    Spacer()
                    Picker("", selection: Binding(get: { entry.mode }, set: { store.set(root: entry.root, mode: $0); reload() })) {
                        Text("On this Mac").tag(LibraryGuardMode.local)
                        Text("Cloud").tag(LibraryGuardMode.cloud)
                        Text("No check").tag(LibraryGuardMode.none)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Button(role: .destructive) { store.remove(root: entry.root); reload() } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
                if entry.mode == .local {
                    Text("The check runs on this Mac. A note Iris reads still goes to your chat model.")
                        .font(.caption).foregroundColor(.secondary)
                } else if entry.mode == .cloud {
                    Text("Each note read from here is also sent to your cloud canary's provider for the check, which can differ from your chat provider.")
                        .font(.caption).foregroundColor(.orange)
                } else if entry.mode == .none {
                    Text("No Tier 3 check. The structural strip still runs, and the note still marks the conversation "
                         + "as having read outside text.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if let failure {
                Text("A library's own canary last failed: \(failure). Its reads are blocked until it runs.")
                    .font(.caption).foregroundColor(.red)
            }
            Button("Add Library Folder…") { addFolder() }
        }
        .onAppear { reload() }
    }

    private func reload() {
        entries = store.entries()
        unreadable = store.isUnreadable
        failure = GuardTierHealth.current.libraryCanaryFailure
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Library"
        if panel.runModal() == .OK, let url = panel.url {
            store.set(root: url.path, mode: .local)
            reload()
        }
    }
}
