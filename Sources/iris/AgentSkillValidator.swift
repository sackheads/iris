import Foundation
import Yams

/// Validates a skill directory against the Agent Skills specification (agentskills.io):
/// SKILL.md present; frontmatter `name` 1-64 chars of lowercase alphanumerics and single
/// hyphens, matching the directory name; `description` 1-1024 chars, non-empty. Optional
/// fields (license, compatibility, metadata, allowed-tools) must merely parse.
enum AgentSkillValidator {
    nonisolated(unsafe) private static let namePattern = /^[a-z0-9]+(-[a-z0-9]+)*$/

    /// Returns a violation message, or nil if the name is valid.
    static func validateName(_ name: String) -> String? {
        if name.isEmpty || name.count > 64 {
            return "Skill name must be 1-64 characters (got \(name.count))"
        }
        if name.wholeMatch(of: namePattern) == nil {
            return "Skill name '\(name)' must be lowercase alphanumerics and single hyphens"
        }
        return nil
    }

    /// Returns all spec violations for the skill directory. Empty array = valid.
    static func validate(directory: URL) -> [String] {
        var violations: [String] = []
        let skillMD = directory.appendingPathComponent("SKILL.md")
        guard let content = try? String(contentsOf: skillMD, encoding: .utf8) else {
            return ["\(directory.lastPathComponent): SKILL.md is missing"]
        }

        let lines = content.components(separatedBy: "\n")
        // `.whitespacesAndNewlines` so a stray `\r` on CRLF-encoded files does not hide the
        // `---` delimiters.
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else {
            return ["\(directory.lastPathComponent): SKILL.md has no YAML frontmatter"]
        }
        let yaml = lines[1..<close].joined(separator: "\n")
        guard let front = (try? Yams.load(yaml: yaml)) as? [String: Any] else {
            return ["\(directory.lastPathComponent): SKILL.md frontmatter is not valid YAML"]
        }

        let name = front["name"] as? String ?? ""
        if let nameError = validateName(name) {
            violations.append(nameError)
        }
        if !name.isEmpty && name != directory.lastPathComponent {
            violations.append("Skill name '\(name)' must match its directory name '\(directory.lastPathComponent)'")
        }
        let description = (front["description"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if description.isEmpty || description.count > 1024 {
            violations.append("\(directory.lastPathComponent): description must be 1-1024 non-empty characters")
        }
        return violations
    }
}
