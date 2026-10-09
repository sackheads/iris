import Foundation
import PDFKit
import AppKit

public struct AttachmentProcessingResult {
    public let inlineParts: [Part]
    public let extractedPromptText: String
    public let warnings: [String]

    public init(inlineParts: [Part] = [], extractedPromptText: String = "", warnings: [String] = []) {
        self.inlineParts = inlineParts
        self.extractedPromptText = extractedPromptText
        self.warnings = warnings
    }
}

public enum AttachmentProcessor {
    public static func process(attachments: [FileAttachment], primarySupportsVision: Bool) async throws -> AttachmentProcessingResult {
        var inlineParts: [Part] = []
        var textBlocks: [String] = []
        var warnings: [String] = []

        for attachment in attachments {
            guard FileManager.default.fileExists(atPath: attachment.fileURL.path) else {
                warnings.append("File not found: \(attachment.filename)")
                continue
            }

            let maxAllowedSize: Int64 = (attachment.category == .image) ? 20_000_000 : 50_000_000
            let fileSizeOnDisk = (try? (FileManager.default.attributesOfItem(atPath: attachment.fileURL.path)[.size] as? NSNumber)?.int64Value) ?? 0
            let effectiveSize = max(attachment.fileSize, fileSizeOnDisk)

            if effectiveSize > maxAllowedSize {
                warnings.append("File '\(attachment.filename)' exceeds the maximum allowed size limit.")
                continue
            }

            switch attachment.category {
            case .text:
                if let text = (try? String(contentsOf: attachment.fileURL, encoding: .utf8))
                    ?? (try? String(contentsOf: attachment.fileURL, encoding: .ascii))
                    ?? (try? String(contentsOf: attachment.fileURL, encoding: .isoLatin1))
                    ?? (try? String(contentsOf: attachment.fileURL)) {
                    let truncated = text.count > 100_000 ? String(text.prefix(100_000)) + "\n[Content truncated at 100,000 characters]" : text
                    let sanitized = PromptInjectionGuard.sanitizeUntrustedInput(truncated)
                    textBlocks.append("<attached_file name=\"\(attachment.filename)\" mime=\"\(attachment.mimeType)\">\n\(sanitized)\n</attached_file>")
                } else {
                    warnings.append("Could not read text from file: \(attachment.filename)")
                }

            case .pdf:
                if let pdf = PDFDocument(url: attachment.fileURL) {
                    var fullPDFText = ""
                    for i in 0..<pdf.pageCount {
                        if let pageText = pdf.page(at: i)?.string {
                            fullPDFText += pageText + "\n"
                        }
                    }
                    let truncated = fullPDFText.count > 100_000 ? String(fullPDFText.prefix(100_000)) + "\n[Content truncated at 100,000 characters]" : fullPDFText
                    let sanitized = PromptInjectionGuard.sanitizeUntrustedInput(truncated)
                    textBlocks.append("<attached_file name=\"\(attachment.filename)\" mime=\"application/pdf\">\n\(sanitized)\n</attached_file>")
                } else {
                    warnings.append("Could not parse PDF file: \(attachment.filename)")
                }

            case .document:
                let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [NSAttributedString.DocumentReadingOptionKey(rawValue: "NSReadAccessURL"): attachment.fileURL]
                if let attrString = try? NSAttributedString(url: attachment.fileURL, options: options, documentAttributes: nil) {
                    let docText = attrString.string
                    let truncated = docText.count > 100_000 ? String(docText.prefix(100_000)) + "\n[Content truncated at 100,000 characters]" : docText
                    let sanitized = PromptInjectionGuard.sanitizeUntrustedInput(truncated)
                    textBlocks.append("<attached_file name=\"\(attachment.filename)\" mime=\"\(attachment.mimeType)\">\n\(sanitized)\n</attached_file>")
                } else {
                    warnings.append("Could not read document file: \(attachment.filename)")
                }

            case .image:
                if primarySupportsVision {
                    if let fileData = try? Data(contentsOf: attachment.fileURL) {
                        let base64 = fileData.base64EncodedString()
                        inlineParts.append(Part(inlineData: InlineData(mimeType: attachment.mimeType, data: base64)))
                    } else {
                        warnings.append("Could not read image file: \(attachment.filename)")
                    }
                }

            case .unknown:
                warnings.append("Unsupported file type for attachment: \(attachment.filename)")
            }
        }

        let combinedPromptText = textBlocks.joined(separator: "\n\n")
        return AttachmentProcessingResult(inlineParts: inlineParts, extractedPromptText: combinedPromptText, warnings: warnings)
    }

    public static func categorize(url: URL) -> (AttachmentCategory, String) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return (.image, "image/png")
        case "jpg", "jpeg": return (.image, "image/jpeg")
        case "gif": return (.image, "image/gif")
        case "webp": return (.image, "image/webp")
        case "pdf": return (.pdf, "application/pdf")
        case "docx": return (.document, "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        case "rtf": return (.document, "application/rtf")
        case "txt", "md", "json", "csv", "swift", "py", "js", "ts", "html", "css", "sh", "yaml", "yml", "xml":
            return (.text, "text/plain")
        default:
            return (.unknown, "application/octet-stream")
        }
    }
}
