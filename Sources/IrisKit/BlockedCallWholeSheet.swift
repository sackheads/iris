import SwiftUI

/// The whole blocked call, as the ledger holds it (#834): what "Approve and run" will dispatch,
/// with the file it writes to and every argument uncut. A body is drawn a line at a time in a lazy
/// stack, so a very large one scrolls without laying out every line.
struct BlockedCallWholeSheet: View {
    let item: AppState.WholeCallSheet
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.whole?.toolName ?? "Blocked call")
                    .font(.system(.headline, design: .monospaced))
                Text(item.jobName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            if let message = item.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let whole = item.whole {
                if let target = whole.target {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("writes to")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(target)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(whole.fields) { field in
                            FieldView(field: field)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 320, idealHeight: 520, maxHeight: 700)
    }

    private struct FieldView: View {
        let field: BlockedCallWhole.Field
        private var lines: [Substring] { EventCard.lines(of: field.text) }

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(field.key)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let size = field.size {
                        Text(size)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : String(line))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}
