import AppKit
import SwiftUI

/// A link `/jobs url … on` minted, for the one sheet that shows it (plan note 17).
struct RevealedURLTrigger: Identifiable, Equatable, Sendable {
    let id = UUID()
    let jobName: String
    let url: String
}

/// Shows a URL trigger's link once, with Copy. The link is never written to the conversation:
/// every message is persisted in plain text, where an approved host `run_command` could read it.
/// Copying puts it on the pasteboard, which is the owner's choice and lasts until the next copy.
struct URLTriggerLinkSheet: View {
    let link: RevealedURLTrigger
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Link for \(link.jobName)").font(.headline)
            Text(verbatim: link.url)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text(JobsCommand.urlSheetText(link.jobName)).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.url, forType: .string)
                }
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
