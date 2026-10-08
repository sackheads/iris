import XCTest
import SwiftUI
@testable import IrisKit

final class AttachmentIntegrationTests: XCTestCase {
    var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    @MainActor
    func testChatMessageWithAttachmentsCreation() {
        let fileURL = tempDirectory.appendingPathComponent("test.txt")
        try? "Sample content".write(to: fileURL, atomically: true, encoding: .utf8)

        let attachment = FileAttachment(
            filename: "test.txt",
            fileURL: fileURL,
            mimeType: "text/plain",
            fileSize: 14,
            category: .text
        )

        let message = ChatMessage(
            role: .user,
            content: "Check this attachment",
            attachments: [attachment]
        )

        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "Check this attachment")
        XCTAssertEqual(message.attachments.count, 1)
        XCTAssertEqual(message.attachments.first?.filename, "test.txt")
    }

    @MainActor
    func testAppStateSendMessageWithAttachments() {
        let appState = AppState.shared
        appState.createNewConversation()
        guard let convId = appState.selectedConversationId else {
            XCTFail("Failed to get selected conversation ID")
            return
        }

        let fileURL = tempDirectory.appendingPathComponent("code.swift")
        try? "print(\"Hello\")".write(to: fileURL, atomically: true, encoding: .utf8)

        let attachment = FileAttachment(
            filename: "code.swift",
            fileURL: fileURL,
            mimeType: "text/plain",
            fileSize: 14,
            category: .text
        )

        appState.sendMessage("Review this file", attachments: [attachment])

        guard let conv = appState.conversations.first(where: { $0.id == convId }) else {
            XCTFail("Conversation not found")
            return
        }

        XCTAssertFalse(conv.messages.isEmpty)
        if let userMsg = conv.messages.first(where: { $0.role == .user }) {
            XCTAssertEqual(userMsg.content, "Review this file")
            XCTAssertEqual(userMsg.attachments.count, 1)
            XCTAssertEqual(userMsg.attachments[0].filename, "code.swift")
        } else {
            XCTFail("User message with attachment not found")
        }
    }

    @MainActor
    func testAutoTitleWithEmptyTextAndAttachment() {
        let appState = AppState.shared
        appState.createNewConversation()
        guard let convId = appState.selectedConversationId else {
            XCTFail("Failed to get selected conversation ID")
            return
        }

        let fileURL = tempDirectory.appendingPathComponent("architecture.pdf")
        try? "PDF Data".write(to: fileURL, atomically: true, encoding: .utf8)

        let attachment = FileAttachment(
            filename: "architecture.pdf",
            fileURL: fileURL,
            mimeType: "application/pdf",
            fileSize: 8,
            category: .pdf
        )

        appState.sendMessage("", attachments: [attachment])

        guard let conv = appState.conversations.first(where: { $0.id == convId }) else {
            XCTFail("Conversation not found")
            return
        }

        XCTAssertTrue(conv.title.contains("architecture.pdf"))
    }
}
