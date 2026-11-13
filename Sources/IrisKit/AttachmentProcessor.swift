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


    public static func makeAttachment(for url: URL) -> FileAttachment? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        let (category, mime) = categorize(url: url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return FileAttachment(filename: url.lastPathComponent, fileURL: url, mimeType: mime, fileSize: size, category: category)
    }

    /// Extracts non-text clipboard items (copied files, screenshots, images, PDFs) as incoming
    /// `FileAttachment`s (#1065). Returns `[]` for ordinary text pastes so `NSTextView.paste`
    /// inserts text as usual.
    public static func attachmentsFromPasteboard(
        _ pasteboard: NSPasteboard,
        stagingDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("iris-pasted-attachments", isDirectory: true)
    ) -> [FileAttachment] {
        // 1. Copied files (e.g. Finder Cmd-C puts both public.file-url and the bare filename string).
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let files = urls.compactMap { makeAttachment(for: $0) }
            if !files.isEmpty { return files }
        }

        // 2. If plain text is on the pasteboard (and no file URLs), let NSTextView paste the text.
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return []
        }

        let shortId = String(UUID().uuidString.prefix(8)).lowercased()
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        // 3. Raw PNG or TIFF image data (macOS screenshots, Copy Image from browsers/Preview).
        let pngData: Data? = pasteboard.data(forType: .png) ?? {
            guard let tiff = pasteboard.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
        }()
        if let pngData, !pngData.isEmpty {
            let filename = "pasted-image-\(shortId).png"
            let target = stagingDirectory.appendingPathComponent(filename)
            if (try? pngData.write(to: target, options: .atomic)) != nil {
                return [FileAttachment(
                    filename: filename, fileURL: target, mimeType: "image/png",
                    fileSize: Int64(pngData.count), category: .image
                )]
            }
        }

        // 4. Raw PDF data on the clipboard.
        if let pdfData = pasteboard.data(forType: .pdf), !pdfData.isEmpty {
            let filename = "pasted-document-\(shortId).pdf"
            let target = stagingDirectory.appendingPathComponent(filename)
            if (try? pdfData.write(to: target, options: .atomic)) != nil {
                return [FileAttachment(
                    filename: filename, fileURL: target, mimeType: "application/pdf",
                    fileSize: Int64(pdfData.count), category: .pdf
                )]
            }
        }

        return []
    }
}
