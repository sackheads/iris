import Testing
import Foundation
@testable import IrisKit

/// #579: a conversation takes its first message as its title only while it has no name of its own.
@MainActor
@Suite("First-message title (#579)")
struct FirstMessageTitleTests {
    private func title(_ app: AppState, _ id: UUID) -> String? {
        app.conversations.first { $0.id == id }?.title
    }

    @Test("a fresh conversation still takes the first 30 characters of its first message")
    func freshConversationIsTitled() {
        let app = AppState()
        let id = app.createNewConversation(select: false)
        #expect(title(app, id) == Conversation.defaultTitle)
        app.appendMessage(role: .user, content: "Question 1: what does the next step look like?", to: id)
        #expect(title(app, id) == "Question 1: what does the next...")
        app.appendMessage(role: .user, content: "a second message renames nothing", to: id)
        #expect(title(app, id) == "Question 1: what does the next...")

        let short = app.createNewConversation(select: false)
        app.appendMessage(role: .user, content: "hi", to: short)
        #expect(title(app, short) == "hi")
    }

    @Test("a conversation renamed before its first message keeps the name it was given")
    func renamedThenSentKeepsItsName() {
        let app = AppState()
        let id = app.createNewConversation(select: false)
        #expect(app.renameConversation(id: id, newTitle: "Trip planning") == nil)
        app.appendMessage(role: .user, content: "Where should we go in May?", to: id)
        #expect(title(app, id) == "Trip planning")
    }

    @Test("a conversation created with a title keeps it")
    func createdWithATitleKeepsIt() {
        let app = AppState()
        let id = app.createNewConversation(title: "#541 stream probe", select: false)
        app.appendMessage(role: .user, content: "Question 1: what does the next step look like?", to: id)
        #expect(title(app, id) == "#541 stream probe")
    }

    @Test("a conversation the store read back untitled still takes its first message")
    func untitledRowIsTitled() {
        let app = AppState()
        let id = UUID()
        app.conversations.append(Conversation(id: id, title: Conversation.untitledTitle))
        app.appendMessage(role: .user, content: "picking up", to: id)
        #expect(title(app, id) == "picking up")
    }
}
