import XCTest
import PDFKit
import AppKit
@testable import IrisKit

final class AttachmentProcessorTests: XCTestCase {
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

    // MARK: - Categorization Tests

    func testCategorization() {
        let testCases: [(String, AttachmentCategory, String)] = [
            ("image.png", .image, "image/png"),
            ("photo.jpg", .image, "image/jpeg"),
            ("photo.jpeg", .image, "image/jpeg"),
            ("animation.gif", .image, "image/gif"),
            ("graphic.webp", .image, "image/webp"),
            ("document.pdf", .pdf, "application/pdf"),
            ("word.docx", .document, "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
            ("notes.rtf", .document, "application/rtf"),
            ("plain.txt", .text, "text/plain"),
            ("readme.md", .text, "text/plain"),
            ("config.json", .text, "text/plain"),
            ("script.swift", .text, "text/plain"),
            ("binary.exe", .unknown, "application/octet-stream")
        ]

        for (filename, expectedCategory, expectedMime) in testCases {
            let url = URL(fileURLWithPath: filename)
            let (category, mimeType) = AttachmentProcessor.categorize(url: url)
            XCTAssertEqual(category, expectedCategory, "Failed category for \(filename)")
            XCTAssertEqual(mimeType, expectedMime, "Failed mimeType for \(filename)")
        }
    }

    // MARK: - Text Extraction Tests

    func testTextFileExtraction() async throws {
        let fileURL = tempDirectory.appendingPathComponent("sample.txt")
        let content = "Hello World File Attachment\nSecond Line of Content"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let attachment = FileAttachment(
            filename: fileURL.lastPathComponent,
            fileURL: fileURL,
            mimeType: "text/plain",
            fileSize: Int64(content.utf8.count),
            category: .text
        )

        let result = try await AttachmentProcessor.process(attachments: [attachment], primarySupportsVision: true)
        XCTAssertTrue(result.extractedPromptText.contains("<attached_file name=\"sample.txt\" mime=\"text/plain\">"))
        XCTAssertTrue(result.extractedPromptText.contains("Hello World File Attachment"))
        XCTAssertTrue(result.extractedPromptText.contains("Second Line of Content"))
        XCTAssertTrue(result.extractedPromptText.contains("</attached_file>"))
        XCTAssertTrue(result.warnings.isEmpty)
    }

    // MARK: - File Truncation Tests

    func testFileTruncation() async throws {
        let fileURL = tempDirectory.appendingPathComponent("long.txt")
        // Create text exceeding 100,000 characters
        let largeContent = String(repeating: "ABCDE12345", count: 11_000) // 110,000 chars
        try largeContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let attachment = FileAttachment(
            filename: "long.txt",
            fileURL: fileURL,
            mimeType: "text/plain",
            fileSize: Int64(largeContent.utf8.count),
            category: .text
        )

        let result = try await AttachmentProcessor.process(attachments: [attachment], primarySupportsVision: true)
        XCTAssertTrue(result.extractedPromptText.contains("[Content truncated at 100,000 characters]"))
        // Check that actual content snippet length inside tag is truncated properly
        let prefixSnippet = String(largeContent.prefix(100_000))
        XCTAssertTrue(result.extractedPromptText.contains(prefixSnippet))
        let overflowSnippet = String(largeContent.prefix(100_005))
        XCTAssertFalse(result.extractedPromptText.contains(overflowSnippet))
    }

    // MARK: - PDF Extraction Tests

    func testPDFTextExtraction() async throws {
        let fileURL = tempDirectory.appendingPathComponent("sample.pdf")
        let pdfData = NSMutableData()
        
        let pdfMetaData = [
            kCGPDFContextCreator: "AttachmentProcessorTests",
            kCGPDFContextAuthor: "Iris"
        ]
        
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, pdfMetaData as CFDictionary) else {
            XCTFail("Failed to create PDF graphics context")
            return
        }
        
        context.beginPDFPage(nil)
        let sampleText = "PDF Text Extraction Sample Page Content"
        let font = NSFont.systemFont(ofSize: 12)
        let attrString = NSAttributedString(string: sampleText, attributes: [.font: font])
        let framesetter = CTFramesetterCreateWithAttributedString(attrString as CFAttributedString)
        let frameRect = CGRect(x: 50, y: 50, width: 500, height: 700)
        let path = CGPath(rect: frameRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, attrString.length), path, nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
        context.closePDF()
        
        try pdfData.write(to: fileURL, options: .atomic)

        let attachment = FileAttachment(
            filename: "sample.pdf",
            fileURL: fileURL,
            mimeType: "application/pdf",
            fileSize: Int64(pdfData.length),
            category: .pdf
        )

        let result = try await AttachmentProcessor.process(attachments: [attachment], primarySupportsVision: true)
        XCTAssertTrue(result.extractedPromptText.contains("<attached_file name=\"sample.pdf\" mime=\"application/pdf\">"))
        XCTAssertTrue(result.extractedPromptText.contains("PDF Text Extraction Sample Page Content"))
        XCTAssertTrue(result.warnings.isEmpty)
    }

    // MARK: - RTF / Document Extraction Tests

    func testRTFDocumentExtraction() async throws {
        let fileURL = tempDirectory.appendingPathComponent("sample.rtf")
        let attributedString = NSAttributedString(string: "Rich Text Document Sample Content")
        let rtfData = try attributedString.data(from: NSRange(location: 0, length: attributedString.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try rtfData.write(to: fileURL)

        let attachment = FileAttachment(
            filename: "sample.rtf",
            fileURL: fileURL,
            mimeType: "application/rtf",
            fileSize: Int64(rtfData.count),
            category: .document
        )

        let result = try await AttachmentProcessor.process(attachments: [attachment], primarySupportsVision: true)
        XCTAssertTrue(result.extractedPromptText.contains("<attached_file name=\"sample.rtf\" mime=\"application/rtf\">"))
        XCTAssertTrue(result.extractedPromptText.contains("Rich Text Document Sample Content"))
        XCTAssertTrue(result.warnings.isEmpty)
    }

    // MARK: - Image Inline Part Creation Tests

    func testImageInlinePartCreationWithVisionSupport() async throws {
        let fileURL = tempDirectory.appendingPathComponent("test_image.png")
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // Dummy PNG magic header bytes
        try imageData.write(to: fileURL)

        let attachment = FileAttachment(
            filename: "test_image.png",
            fileURL: fileURL,
            mimeType: "image/png",
            fileSize: Int64(imageData.count),
            category: .image
        )

        let result = try await AttachmentProcessor.process(attachments: [attachment], primarySupportsVision: true)
        XCTAssertEqual(result.inlineParts.count, 1)
        XCTAssertEqual(result.inlineParts[0].inlineData?.mimeType, "image/png")
        XCTAssertEqual(result.inlineParts[0].inlineData?.data, imageData.base64EncodedString())
        XCTAssertTrue(result.extractedPromptText.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testImageIgnoredWhenVisionNotSupported() async throws {
        let fileURL = tempDirectory.appendingPathComponent("test_image.png")
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        try imageData.write(to: fileURL)

        let attachment = FileAttachment(
            filename: "test_image.png",
            fileURL: fileURL,
            mimeType: "image/png",
            fileSize: Int64(imageData.count),
            category: .image
        )

        let result = try await AttachmentProcessor.process(attachments: [attachment], primarySupportsVision: false)
        XCTAssertTrue(result.inlineParts.isEmpty)
        XCTAssertTrue(result.extractedPromptText.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    // MARK: - Error Handling & Warnings Tests

    func testFileNotFoundWarning() async throws {
        let fileURL = tempDirectory.appendingPathComponent("nonexistent.txt")
        let attachment = FileAttachment(
            filename: "nonexistent.txt",
            fileURL: fileURL,
            mimeType: "text/plain",
            fileSize: 100,
            category: .text
        )

        let result = try await AttachmentProcessor.process(attachments: [attachment], primarySupportsVision: true)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("File not found: nonexistent.txt"))
        XCTAssertTrue(result.extractedPromptText.isEmpty)
    }

    func testImageFileSizeLimitExceeded() async throws {
        let fileURL = tempDirectory.appendingPathComponent("oversized.png")
        try "dummy".write(to: fileURL, atomically: true, encoding: .utf8)
        let attachment = FileAttachment(
            filename: "oversized.png",
            fileURL: fileURL,
            mimeType: "image/png",
            fileSize: 20_000_001,
            category: .image
        )

        let result = try await AttachmentProcessor.process(attachments: [attachment], primarySupportsVision: true)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings[0], "File 'oversized.png' exceeds the maximum allowed size limit.")
        XCTAssertTrue(result.inlineParts.isEmpty)
    }

    func testDocumentFileSizeLimitExceeded() async throws {
        let fileURL = tempDirectory.appendingPathComponent("oversized.txt")
        try "dummy".write(to: fileURL, atomically: true, encoding: .utf8)
        let attachment = FileAttachment(
            filename: "oversized.txt",
            fileURL: fileURL,
            mimeType: "text/plain",
            fileSize: 50_000_001,
            category: .text
        )

        let result = try await AttachmentProcessor.process(attachments: [attachment], primarySupportsVision: true)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings[0], "File 'oversized.txt' exceeds the maximum allowed size limit.")
        XCTAssertTrue(result.extractedPromptText.isEmpty)
    }
}
