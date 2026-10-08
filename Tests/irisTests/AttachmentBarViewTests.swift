import XCTest
import SwiftUI
@testable import IrisKit

final class AttachmentBarViewTests: XCTestCase {
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
    func testAttachmentChipViewInitialization() {
        let fileURL = tempDirectory.appendingPathComponent("document.pdf")
        let attachment = FileAttachment(
            filename: "document.pdf",
            fileURL: fileURL,
            mimeType: "application/pdf",
            fileSize: 1024 * 500, // 500 KB
            category: .pdf
        )

        var removed = false
        let chip = AttachmentChipView(attachment: attachment) {
            removed = true
        }

        XCTAssertEqual(chip.attachment.filename, "document.pdf")
        XCTAssertEqual(chip.attachment.category, .pdf)
        XCTAssertEqual(chip.attachment.fileSize, 500 * 1024)

        chip.onRemove?()
        XCTAssertTrue(removed)
    }

    @MainActor
    func testAttachmentBarViewBindingModification() {
        let fileURL1 = tempDirectory.appendingPathComponent("doc1.txt")
        let fileURL2 = tempDirectory.appendingPathComponent("doc2.pdf")

        let att1 = FileAttachment(filename: "doc1.txt", fileURL: fileURL1, mimeType: "text/plain", fileSize: 100, category: .text)
        let att2 = FileAttachment(filename: "doc2.pdf", fileURL: fileURL2, mimeType: "application/pdf", fileSize: 200, category: .pdf)

        var attachments = [att1, att2]
        let binding = Binding<[FileAttachment]>(
            get: { attachments },
            set: { attachments = $0 }
        )

        let bar = AttachmentBarView(attachments: binding)
        XCTAssertEqual(bar.attachments.count, 2)

        attachments.removeAll { $0.id == att1.id }
        XCTAssertEqual(bar.attachments.count, 1)
        XCTAssertEqual(bar.attachments.first?.filename, "doc2.pdf")
    }
}
