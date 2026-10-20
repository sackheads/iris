import SwiftUI

/// Settings → Advanced → "Session attachments" (#469 §7.6 J): how much the attachment exchange
/// holds, and its ceiling. A new attachment that would pass the ceiling is refused, naming this.
@MainActor
struct SessionAttachmentsSection: View {
    @Bindable var config: ConfigManager = .shared
    @State private var totalBytes: Int64?

    var body: some View {
        Section(header: Text("Session attachments").font(.headline)) {
            HStack {
                Text("Stored")
                Spacer()
                Text(totalBytes.map { ArtifactError.size($0) } ?? "…").foregroundStyle(.secondary)
            }
            Stepper(value: $config.artifactExchangeCapMB, in: 256...20_480, step: 256) {
                HStack {
                    Text("Limit")
                    Spacer()
                    Text(ArtifactError.size(Int64(config.artifactExchangeCapMB) * 1024 * 1024)).foregroundStyle(.secondary)
                }
            }
            Text("Files sessions hand each other with send_to_session. Each is kept while a conversation that sent or received it exists, then for a week.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        let paths = IrisPaths.default
        totalBytes = await Task.detached { ArtifactStore(paths: paths).totalBytes() }.value
    }
}
