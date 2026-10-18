import SwiftUI

/// The sidebar row's trailing mark. A red pip while the conversation needs the person (#466, the
/// owner's pick), else a blue dot while a reply there is unread (#592); red wins when both apply.
/// The look lives here alone, so changing it is a one-file change. Static, so Reduce Motion has
/// nothing to change (#538), and drawn from system colours, which bring their own light and dark
/// variants.
struct ConversationMark: ViewModifier {
    /// What the row is waiting on (#466), or nil.
    let needsHuman: String?
    /// A reply landed while the person was not looking (#592).
    let unread: Bool
    /// `.increased` on a selected row, whose accent fill would swallow a coloured dot.
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Self.Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            content
            if let mark {
                Spacer(minLength: 0)
                Circle()
                    .fill(prominence == .increased ? Color.white : mark.color)
                    .frame(width: 7, height: 7)
                    .help(mark.label)
                    .accessibilityLabel(mark.label)
            }
        }
    }

    private var mark: (color: Color, label: String)? {
        switch Self.kind(needsHuman: needsHuman, unread: unread) {
        case .needsHuman(let reason): return (Color(nsColor: .systemRed), "Needs you: \(reason)")
        case .unread: return (Color(nsColor: .systemBlue), "Unread reply")
        case nil: return nil
        }
    }

    enum Kind: Equatable { case needsHuman(String), unread }

    /// Which mark a row carries: needing the person wins over an unread reply.
    static func kind(needsHuman: String?, unread: Bool) -> Kind? {
        if let needsHuman { return .needsHuman(needsHuman) }
        return unread ? .unread : nil
    }
}

extension View {
    /// The row's mark: needs you (#466), else unread reply (#592).
    func conversationMark(needsHuman: String?, unread: Bool) -> some View {
        modifier(ConversationMark(needsHuman: needsHuman, unread: unread))
    }
}
