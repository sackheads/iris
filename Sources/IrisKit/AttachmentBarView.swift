import SwiftUI
import AppKit

public struct AttachmentChipView: View {
    public let attachment: FileAttachment
    public var onRemove: (() -> Void)? = nil

    public init(attachment: FileAttachment, onRemove: (() -> Void)? = nil) {
        self.attachment = attachment
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: 6) {
            if attachment.category == .image, let nsImage = NSImage(contentsOf: attachment.fileURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                    .cornerRadius(4)
            } else {
                Image(systemName: iconName(for: attachment.category))
                    .foregroundColor(.accentColor)
                    .font(.system(size: 16))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(formattedSize(attachment.fileSize))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if let onRemove = onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func iconName(for category: AttachmentCategory) -> String {
        switch category {
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .text: return "doc.plaintext"
        case .image: return "photo"
        case .unknown: return "paperclip"
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

public struct AttachmentBarView: View {
    @Binding public var attachments: [FileAttachment]

    public init(attachments: Binding<[FileAttachment]>) {
        self._attachments = attachments
    }

    public var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        AttachmentChipView(attachment: attachment) {
                            attachments.removeAll { $0.id == attachment.id }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }
}
