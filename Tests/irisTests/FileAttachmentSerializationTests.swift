import XCTest
@testable import iris

final class FileAttachmentSerializationTests: XCTestCase {
    func testFileAttachmentJSONEncodingAndDecoding() throws {
        let url = URL(fileURLWithPath: "/tmp/sample.png")
        let attachment = FileAttachment(
            id: UUID(),
            filename: "sample.png",
            fileURL: url,
            mimeType: "image/png",
            fileSize: 1024,
            category: .image
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(attachment)
        let decoded = try decoder.decode(FileAttachment.self, from: data)
        
        XCTAssertEqual(decoded.filename, "sample.png")
        XCTAssertEqual(decoded.mimeType, "image/png")
        XCTAssertEqual(decoded.fileSize, 1024)
        XCTAssertEqual(decoded.category, .image)
    }

    func testChatMessageBackwardsCompatibility() throws {
        let jsonWithoutAttachments = """
        {
            "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "role": "user",
            "content": "Hello"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let msg = try decoder.decode(ChatMessage.self, from: jsonWithoutAttachments)
        XCTAssertEqual(msg.content, "Hello")
        XCTAssertTrue(msg.attachments.isEmpty)
    }

    // #204 round 2: a keyNotFound inside one element of `attachments` used to throw out of
    // ChatMessage.init(from:)'s decodeIfPresent, which only swallows a MISSING attachments key.
    func testFileAttachmentMissingDefaultableFieldsDecodesToDefaults() throws {
        let json = """
        {"id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", "fileURL": "file:///tmp/sample.png"}
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(FileAttachment.self, from: json)
        XCTAssertEqual(a.id, UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        XCTAssertEqual(a.filename, "")
        XCTAssertEqual(a.mimeType, "application/octet-stream")
        XCTAssertEqual(a.fileSize, 0)
        XCTAssertEqual(a.category, .unknown)
    }

    func testChatMessageWithAttachmentMissingFieldStillLoads() throws {
        let json = """
        {"id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", "role": "user", "content": "hi",
         "attachments": [{"fileURL": "file:///tmp/a.txt"}]}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(ChatMessage.self, from: json)
        XCTAssertEqual(msg.attachments.count, 1)
        XCTAssertEqual(msg.attachments.first?.category, .unknown)
    }
}
