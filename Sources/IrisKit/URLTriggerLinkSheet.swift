import AppKit
import SwiftUI

/// A link `/jobs url … on` minted, for the one sheet that shows it (plan note 17).
struct RevealedURLTrigger: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// What `off` and `delete` match on: a rename does not orphan the sheet.
    let jobId: UUID
    let jobName: String
    let url: String
}

/// The three pasteboard calls Copy makes, so a test can see their order.
protocol LinkPasteboard {
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int
    func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: LinkPasteboard {}

/// Shows a URL trigger's link once, with Copy. The link is never written to the conversation:
/// every message is persisted in plain text, where an approved host `run_command` could read it.
/// Copying puts it on the pasteboard, which is the owner's choice and lasts until the next copy.
struct URLTriggerLinkSheet: View {
    let link: RevealedURLTrigger
    let onDone: () -> Void

    /// The nspasteboard.org markers: clipboard-history managers skip a concealed or transient
    /// item instead of keeping the link on disk.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// For this Mac only, so Universal Clipboard does not carry the link to the owner's other
    /// devices, and marked so clipboard history does not keep it. The markers go on before the
    /// link: a clipboard manager polling between two writes must never find the link unmarked.
    static func copy(_ url: String, to pasteboard: some LinkPasteboard) {
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        _ = pasteboard.setData(Data(), forType: concealedType)
        _ = pasteboard.setData(Data(), forType: transientType)
        _ = pasteboard.setString(url, forType: .string)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Link for \(link.jobName)").font(.headline)
            Text(verbatim: link.url)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text(JobsCommand.urlSheetText(link.jobName)).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                // Copy is the default, not Done: Return must never end the reveal, because a stray
                // one would lose a link that cannot be shown again (Task 28 step 4). Copying twice
                // is harmless.
                Button("Copy") { Self.copy(link.url, to: NSPasteboard.general) }
                    .keyboardShortcut(.defaultAction)
                Button("Done", action: onDone)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
