import Foundation
import Yams

/// Errors produced while parsing or validating an Iris Plugin Format manifest.
enum IPFError: Error, Equatable, CustomStringConvertible {
    case missingFrontmatter
    case yamlError(String)
    case invalidJSON(String)
    case unsupportedVersion(String)
    case invalidID(String)
    case idMismatch(manifest: String, directory: String)
    case unknownReference(String)
    case undeclaredSecret(String)

    var description: String {
        switch self {
        case .missingFrontmatter: return "plugin.md has no YAML frontmatter block"
        case .yamlError(let e): return "Invalid YAML frontmatter: \(e)"
        case .invalidJSON(let e): return "Invalid JSON: \(e)"
        case .unsupportedVersion(let v): return "Manifest declares ipf \(v); this Iris supports 1.x. Update Iris."
        case .invalidID(let id): return "Invalid plugin id '\(id)': lowercase letters, digits, single hyphens only"
        case .idMismatch(let m, let d): return "Manifest id '\(m)' does not match directory name '\(d)'"
        case .unknownReference(let r): return "Unresolvable reference \(r)"
        case .undeclaredSecret(let k): return "mcp.json references ${keychain:\(k)} but the manifest does not declare it"
        }
    }
}

/// The Iris Plugin Format (IPF) manifest — the YAML frontmatter of `plugin.md`.
/// Declarations only, never secret values. See docs/ipf/spec.md.
struct IPFManifest: Codable, Sendable, Equatable {
    struct Components: Codable, Sendable, Equatable {
        var mcp: String?
        var skills: String?
        var rules: String?
    }
    struct BinaryRequirement: Codable, Sendable, Equatable {
        let name: String
        var installHint: String?
        enum CodingKeys: String, CodingKey { case name; case installHint = "install_hint" }
    }
    struct Requires: Codable, Sendable, Equatable {
        var binaries: [BinaryRequirement]?
    }
    struct ConfigField: Codable, Sendable, Equatable {
        let key: String
        var label: String?
        var required: Bool?
        var `default`: String?
        var help: String?
    }
    struct SecretField: Codable, Sendable, Equatable {
        let key: String
        var label: String?
        var required: Bool?
        var help: String?
    }
    struct AuthDeclaration: Codable, Sendable, Equatable {
        let kind: String   // v1: "external"
        var label: String?
        var setupCommand: String?
        var checkCommand: String?
        var help: String?
        enum CodingKeys: String, CodingKey {
            case kind, label, help
            case setupCommand = "setup_command"
            case checkCommand = "check_command"
        }
    }

    let ipf: String
    let id: String
    let name: String
    let version: String
    var description: String?
    var author: String?
    var homepage: String?
    var components: Components?
    var requires: Requires?
    var config: [ConfigField]?
    var secrets: [SecretField]?
    var auth: [AuthDeclaration]?

    /// Markdown body after the frontmatter — human docs, rendered in Settings. Not part of YAML.
    var markdownBody: String = ""

    enum CodingKeys: String, CodingKey {
        case ipf, id, name, version, description, author, homepage
        case components, requires, config, secrets, auth
    }

    static let supportedMajor = 1
    nonisolated(unsafe) static let idPattern = /^[a-z0-9]+(-[a-z0-9]+)*$/

    /// Non-parsing initializer for internal placeholder construction (broken-plugin rows).
    init(placeholderID id: String) {
        self.ipf = "1.0"
        self.id = id
        self.name = id
        self.version = "0.0.0"
    }

    /// Parses `plugin.md` content. `directoryName` is the plugin folder name; it must equal `id`.
    static func parse(markdown: String, directoryName: String) throws -> IPFManifest {
        let lines = markdown.components(separatedBy: "\n")
        // `.whitespacesAndNewlines` so a stray `\r` on CRLF-encoded files does not hide the
        // `---` delimiters.
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            throw IPFError.missingFrontmatter
        }
        guard let closeIndex = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }) else {
            throw IPFError.missingFrontmatter
        }
        let yaml = lines[1..<closeIndex].joined(separator: "\n")
        let body = lines[(closeIndex + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var manifest: IPFManifest
        do {
            manifest = try YAMLDecoder().decode(IPFManifest.self, from: yaml)
        } catch {
            throw IPFError.yamlError(String(describing: error))
        }
        manifest.markdownBody = body

        guard let major = manifest.ipf.split(separator: ".").first,
              Int(major) == supportedMajor else {
            throw IPFError.unsupportedVersion(manifest.ipf)
        }
        guard manifest.id.wholeMatch(of: idPattern) != nil, manifest.id.count <= 64 else {
            throw IPFError.invalidID(manifest.id)
        }
        guard manifest.id == directoryName else {
            throw IPFError.idMismatch(manifest: manifest.id, directory: directoryName)
        }
        return manifest
    }
}
