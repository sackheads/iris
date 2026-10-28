import CryptoKit
import Foundation

/// The model an eval run scores, always given as explicit config, never read from the home's
/// settings: `onnx:<bundle dir>`, `coreml:<.mlmodelc dir>`, `ollama:<name>`, `llamacpp:<file>`,
/// `mlx:<id>` (docs/specs/2026-10-28-model-eval-framework.md, section 6).
struct EvalModelSpec: Equatable, Sendable {
    enum Runtime: String, Codable, CaseIterable, Sendable {
        case onnx, coreml, ollama, llamacpp, mlx
    }

    var runtime: Runtime
    /// A path for the file runtimes, a model name or id for the others.
    var name: String

    /// Split on the first colon only: Ollama names have their own (`gemma4:12b-32k`).
    static func parse(_ text: String) -> EvalModelSpec? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let prefix = String(text[..<colon]).lowercased()
        let rest = String(text[text.index(after: colon)...])
        guard let runtime = Runtime(rawValue: prefix), !rest.isEmpty else { return nil }
        return EvalModelSpec(runtime: runtime, name: rest)
    }

    var description: String { "\(runtime.rawValue):\(name)" }

    /// The local path, tilde-expanded, for the runtimes that read files.
    var url: URL? {
        switch runtime {
        case .onnx, .coreml, .llamacpp: return URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
        case .ollama, .mlx: return nil
        }
    }

    /// What names the model in a result and in a file name: the bundle's folder for a path, the
    /// name itself otherwise. A folder renamed to switch a tier off (`…onnx-no`) is the same model.
    var displayName: String {
        guard let url else { return name }
        var last = url.standardizedFileURL.lastPathComponent
        if last.hasSuffix("-no") { last.removeLast(3) }
        return last
    }

    var slug: String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
        return String("\(runtime.rawValue)-\(displayName)".lowercased().map { allowed.contains($0) ? $0 : "-" })
    }
}

/// One file of a local model, as it was scored.
struct EvalModelFile: Codable, Equatable, Sendable {
    var path: String
    var bytes: Int
    var sha256: String
}

enum EvalFingerprint {
    /// Every regular file under `url` (or `url` itself), by relative path, with its sha256.
    static func files(at url: URL) throws -> [EvalModelFile] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw EvalError.modelMissing(url.path)
        }
        if !isDir.boolValue { return [try file(url, relative: url.lastPathComponent)] }
        let base = url.standardizedFileURL.path
        var out: [EvalModelFile] = []
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        while let next = walker?.nextObject() as? URL {
            guard (try? next.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let full = next.standardizedFileURL.path
            out.append(try file(next, relative: String(full.dropFirst(base.count + 1))))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// One digest for the whole model: the sha256 of its files' "path sha256" lines.
    static func digest(_ files: [EvalModelFile]) -> String {
        let lines = files.map { "\($0.path) \($0.sha256)" }.joined(separator: "\n")
        return "sha256:" + hex(SHA256.hash(data: Data(lines.utf8)))
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hex(hasher.finalize())
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func file(_ url: URL, relative: String) throws -> EvalModelFile {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return EvalModelFile(path: relative, bytes: size, sha256: try sha256(of: url))
    }
}

enum EvalError: Error, Equatable, LocalizedError {
    case usage(String)
    case modelMissing(String)
    case datasetMismatch(String)
    case unsupported(String)
    case incomparable(String)

    var errorDescription: String? {
        switch self {
        case .usage(let s): return s
        case .modelMissing(let path): return "no model at \(path)"
        case .datasetMismatch(let s): return "dataset doesn't match its manifest: \(s)"
        case .unsupported(let s): return s
        case .incomparable(let s): return "not comparable: \(s)"
        }
    }
}
