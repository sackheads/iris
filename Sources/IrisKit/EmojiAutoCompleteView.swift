import SwiftUI

struct EmojiAutoCompleteView: View {
    var model: EmojiTokenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "face.smiling")
                    .foregroundColor(.irisIndigo)
                    .font(.caption)
                Text("EMOJI")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { idx, item in
                    Button(action: { model.selectedIndex = idx; model.commitSelected() }) {
                        HStack(spacing: 10) {
                            Text(model.displayGlyph(for: item)).font(.title3)
                            Text(":\(item.shortcode):")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.irisIndigo)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(idx == model.selectedIndex
                                ? Color.irisIndigo.opacity(0.18)
                                : Color.primary.opacity(0.04))
                    .cornerRadius(6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(.thinMaterial)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.bottom, 4)
    }
}
