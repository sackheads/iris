import Foundation

public enum AttachmentCategory: String, Codable, Sendable {
    case image
    case pdf
    case document
    case text
    case unknown
}

public struct FileAttachment: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let filename: String
    public let fileURL: URL
    public let mimeType: String
    public let fileSize: Int64
    public let category: AttachmentCategory

    public init(
        id: UUID = UUID(),
        filename: String,
        fileURL: URL,
        mimeType: String,
        fileSize: Int64,
        category: AttachmentCategory
    ) {
        self.id = id
        self.filename = filename
        self.fileURL = fileURL
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.category = category
    }

    /// Lenient decoder (invariant 1, #204 round 2): a `keyNotFound` here throws out of
    /// `ChatMessage.init(from:)`'s `decodeIfPresent([FileAttachment].self, ...)`, which swallows a
    /// MISSING `attachments` key but not a decode error inside an element already present. Nothing
    /// else correlates against `FileAttachment.id` (it is read back only within a single in-memory
    /// list, e.g. `AttachmentBarView`'s remove-by-id), so it is safe to mint a fresh one. `fileURL`
    /// stays required: with no path the record cannot locate its file, so there is no default that
    /// makes it behave like a real attachment rather than a broken one.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
        fileURL = try c.decode(URL.self, forKey: .fileURL)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "application/octet-stream"
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        category = try c.decodeIfPresent(AttachmentCategory.self, forKey: .category) ?? .unknown
    }
}

public struct InlineData: Codable, Equatable, Sendable {
    public let mimeType: String
    public let data: String // Base64 encoded

    public init(mimeType: String, data: String) {
        self.mimeType = mimeType
        self.data = data
    }

    /// Lenient decoder (invariant 1, #204 round 2): reachable via a persisted `history` row's
    /// `Content.parts[].inlineData`. `Part` already treats a MISSING `inlineData` key as nil
    /// automatically (it is `Optional`), but a decode error inside an inlineData object that IS
    /// present still throws, which `decodeIfPresent` does not swallow.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "application/octet-stream"
        data = try c.decodeIfPresent(String.self, forKey: .data) ?? ""
    }
}
