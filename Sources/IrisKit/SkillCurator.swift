import Foundation

public struct CurationReport: Sendable, Equatable {
    public let timestamp: Date
    public let totalSkillsScanned: Int
    public let validSkillsCount: Int
    public let prunedSkillsCount: Int
    public let prunedSkillNames: [String]
    public let recommendations: [String]
}

public final class SkillCurator: Sendable {
    public static let shared = SkillCurator()

    private init() {}

    public func curateSkills() async -> CurationReport {
        await curateSkills(paths: .default)
    }

    func curateSkills(paths: IrisPaths) async -> CurationReport {
        let fileManager = FileManager.default
        let skillsDir = paths.skillsDir
        let trashDir = paths.memoryDir.appendingPathComponent("trash/skills")
        var totalScanned = 0
        var validCount = 0
        var prunedNames: [String] = []
        var recommendations: [String] = []

        guard let skillFolders = try? fileManager.contentsOfDirectory(atPath: skillsDir.path) else {
            return CurationReport(timestamp: Date(), totalSkillsScanned: 0, validSkillsCount: 0, prunedSkillsCount: 0, prunedSkillNames: [], recommendations: ["No skills directory found."])
        }

        var skillDescriptions: [String: String] = [:]
        let timestampPrefix = Int(Date().timeIntervalSince1970)

        for folder in skillFolders {
            guard !folder.hasPrefix(".") else { continue }
            totalScanned += 1
            let skillFolder = skillsDir.appendingPathComponent(folder)
            let skillFile = skillFolder.appendingPathComponent("SKILL.md")

            guard fileManager.fileExists(atPath: skillFile.path),
                  let content = try? String(contentsOf: skillFile, encoding: .utf8) else {
                // Quarantined (soft-delete) to trash directory instead of hard removal
                quarantineFolder(skillFolder, folderName: folder, timestamp: timestampPrefix, trashDir: trashDir, fileManager: fileManager)
                prunedNames.append(folder)
                recommendations.append("Quarantined corrupt skill '\(folder)' to trash. Run `/skills new \(folder)` to scaffold a replacement.")
                continue
            }

            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedContent.count < 30 {
                // Quarantined (soft-delete) to trash directory
                quarantineFolder(skillFolder, folderName: folder, timestamp: timestampPrefix, trashDir: trashDir, fileManager: fileManager)
                prunedNames.append(folder)
                recommendations.append("Quarantined empty skill '\(folder)' to trash. Run `/skills new \(folder)` to scaffold a replacement.")
                continue
            }

            let info = parseSkillInfo(content: trimmedContent, folderName: folder)
            validCount += 1

            // Check for duplicates/overlap
            if let existingFolder = skillDescriptions[info.description] {
                recommendations.append("Overlap detected between '\(folder)' and '\(existingFolder)': consider consolidating into an umbrella skill via `create_skill`.")
            } else {
                skillDescriptions[info.description] = folder
            }
        }

        if prunedNames.count > 0 {
            await AppState.shared.invalidateEnginePrompt()
        }

        let report = CurationReport(
            timestamp: Date(),
            totalSkillsScanned: totalScanned,
            validSkillsCount: validCount,
            prunedSkillsCount: prunedNames.count,
            prunedSkillNames: prunedNames,
            recommendations: recommendations
        )

        try? saveReport(report, paths: paths)
        return report
    }

    public func formatReportMarkdown(_ report: CurationReport) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var md = "### 🧹 Iris Skill Curator Report (\(formatter.string(from: report.timestamp)))\n\n"
        md += "- **Total Skills Scanned:** \(report.totalSkillsScanned)\n"
        md += "- **Valid Active Skills:** \(report.validSkillsCount)\n"
        md += "- **Pruned/Corrupt Skills:** \(report.prunedSkillsCount)"
        if !report.prunedSkillNames.isEmpty {
            md += " (\(report.prunedSkillNames.joined(separator: ", ")))\n"
        } else {
            md += "\n"
        }

        if !report.recommendations.isEmpty {
            md += "\n**Recommendations & Overlap Alerts:**\n"
            for rec in report.recommendations {
                md += "• \(rec)\n"
            }
        } else {
            md += "\n✨ *Skill library is fully clean and healthy. No overlaps detected.*"
        }
        return md
    }

    private func saveReport(_ report: CurationReport, paths: IrisPaths) throws {
        let curatorDir = paths.memoryDir.appendingPathComponent("curator")
        let reportFile = curatorDir.appendingPathComponent("REPORT.md")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: curatorDir, withIntermediateDirectories: true)
        let md = formatReportMarkdown(report)
        try md.write(to: reportFile, atomically: true, encoding: .utf8)
    }

    private func quarantineFolder(_ source: URL, folderName: String, timestamp: Int, trashDir: URL, fileManager: FileManager) {
        try? fileManager.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let target = trashDir.appendingPathComponent("\(timestamp)_\(folderName)")
        try? fileManager.moveItem(at: source, to: target)
    }

    private func parseSkillInfo(content: String, folderName: String) -> (name: String, description: String) {
        let lines = content.components(separatedBy: .newlines)
        var inFrontmatter = false
        var desc = "No description provided."
        var name = folderName

        for line in lines {
            if line == "---" {
                if inFrontmatter { break }
                inFrontmatter = true
                continue
            }
            if inFrontmatter {
                if line.starts(with: "description:") {
                    desc = String(line.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
                } else if line.starts(with: "name:") {
                    name = String(line.dropFirst("name:".count)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return (name, desc)
    }
}
