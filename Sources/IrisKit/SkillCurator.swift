import Foundation

public struct CurationReport: Sendable, Equatable {
    public let timestamp: Date
    public let totalSkillsScanned: Int
    public let validSkillsCount: Int
    public let prunedSkillsCount: Int
    public let prunedSkillNames: [String]
    public let recommendations: [String]
    /// True when the run moved the quarantined folders; false for the dry run (the default), where
    /// `prunedSkillNames` is what it would quarantine and nothing moved (#48).
    public let applied: Bool
    /// Folders with no usable SKILL.md that were touched within `SkillCurator.draftWindow`: a draft
    /// being written, skipped rather than quarantined.
    public let draftSkippedNames: [String]
}

public final class SkillCurator: Sendable {
    public static let shared = SkillCurator()

    private init() {}

    /// How recently a folder with no usable SKILL.md was touched for the curator to leave it alone as
    /// a draft (#48). The folder's or the file's modification time: no marker file to keep.
    static let draftWindow: TimeInterval = 24 * 60 * 60

    /// Scans the skills folder. By default a dry run: it reports what it would quarantine and moves
    /// nothing. `apply: true` quarantines (soft-deletes to `memory/trash/skills`; `restoreSkill` brings
    /// one back). A folder with no usable SKILL.md that changed in the last `draftWindow` is skipped.
    func curateSkills(paths: IrisPaths = .default,
                      apply: Bool = false,
                      now: Date = Date(),
                      onSkillsChanged: (@Sendable () async -> Void)? = nil) async -> CurationReport {
        let fileManager = FileManager.default
        let skillsDir = paths.skillsDir
        let trashDir = paths.memoryDir.appendingPathComponent("trash/skills")
        var totalScanned = 0
        var validCount = 0
        var prunedNames: [String] = []
        var recommendations: [String] = []
        var draftNames: [String] = []

        guard let skillFolders = try? fileManager.contentsOfDirectory(atPath: skillsDir.path) else {
            return CurationReport(timestamp: Date(), totalSkillsScanned: 0, validSkillsCount: 0, prunedSkillsCount: 0, prunedSkillNames: [], recommendations: ["No skills directory found."], applied: apply, draftSkippedNames: [])
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
                if isRecentDraft(skillFolder, skillFile: skillFile, now: now, fileManager: fileManager) {
                    draftNames.append(folder)
                    recommendations.append("Skipped '\(folder)': no SKILL.md yet, but it changed in the last 24 hours, so it looks like a draft.")
                    continue
                }
                // Quarantined (soft-delete) to trash directory instead of hard removal
                if apply { quarantineFolder(skillFolder, folderName: folder, timestamp: timestampPrefix, trashDir: trashDir, fileManager: fileManager) }
                prunedNames.append(folder)
                recommendations.append(apply
                    ? "Quarantined corrupt skill '\(folder)' to trash. `/skills restore \(folder)` brings it back; `/skills new \(folder)` scaffolds a replacement."
                    : "Would quarantine corrupt skill '\(folder)'. `/skills curate --apply` does it.")
                continue
            }

            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedContent.count < 30 {
                if isRecentDraft(skillFolder, skillFile: skillFile, now: now, fileManager: fileManager) {
                    draftNames.append(folder)
                    recommendations.append("Skipped '\(folder)': its SKILL.md is nearly empty, but it changed in the last 24 hours, so it looks like a draft.")
                    continue
                }
                // Quarantined (soft-delete) to trash directory
                if apply { quarantineFolder(skillFolder, folderName: folder, timestamp: timestampPrefix, trashDir: trashDir, fileManager: fileManager) }
                prunedNames.append(folder)
                recommendations.append(apply
                    ? "Quarantined empty skill '\(folder)' to trash. `/skills restore \(folder)` brings it back; `/skills new \(folder)` scaffolds a replacement."
                    : "Would quarantine empty skill '\(folder)'. `/skills curate --apply` does it.")
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

        if apply, prunedNames.count > 0 {
            await onSkillsChanged?()
        }

        let report = CurationReport(
            timestamp: Date(),
            totalSkillsScanned: totalScanned,
            validSkillsCount: validCount,
            prunedSkillsCount: prunedNames.count,
            prunedSkillNames: prunedNames,
            recommendations: recommendations,
            applied: apply,
            draftSkippedNames: draftNames
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
        if !report.applied { md += "- **Dry run:** nothing was moved. `/skills curate --apply` quarantines what is listed below.\n" }
        md += "- **\(report.applied ? "Pruned/Corrupt Skills" : "Would quarantine"):** \(report.prunedSkillsCount)"
        if !report.prunedSkillNames.isEmpty {
            md += " (\(report.prunedSkillNames.joined(separator: ", ")))\n"
        } else {
            md += "\n"
        }

        if !report.draftSkippedNames.isEmpty {
            md += "- **Skipped as drafts:** \(report.draftSkippedNames.joined(separator: ", "))\n"
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

    /// True when `folder` or its SKILL.md changed within `draftWindow` of `now`.
    private func isRecentDraft(_ folder: URL, skillFile: URL, now: Date, fileManager: FileManager) -> Bool {
        let newest = [folder, skillFile].compactMap {
            (try? fileManager.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }.max()
        guard let newest else { return false }
        return now.timeIntervalSince(newest) < Self.draftWindow
    }

    enum RestoreResult: Equatable, Sendable {
        case restored(name: String)
        /// A skill of that name is already in the skills folder; nothing was moved.
        case exists(name: String)
        /// No quarantined skill of that name; `available` are the names in the trash, newest first.
        case notFound(name: String, available: [String])
        case invalidName(String)
        /// The quarantined copy is there but could not be moved (permissions, a full disk, a skills
        /// path that is a file); it stays in the quarantine.
        case failed(name: String, reason: String)
    }

    /// Moves the newest quarantined copy of `name` back into the skills folder (#48). Never
    /// overwrites a skill of that name.
    func restoreSkill(name rawName: String,
                      paths: IrisPaths = .default,
                      onSkillsChanged: (@Sendable () async -> Void)? = nil) async -> RestoreResult {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileManager = FileManager.default
        let trashDir = paths.memoryDir.appendingPathComponent("trash/skills")
        // The trash holds `<unix seconds>_<folder>`; the newest copy of each name first.
        let entries = ((try? fileManager.contentsOfDirectory(atPath: trashDir.path)) ?? []).compactMap { entry -> (stamp: Int, name: String, entry: String)? in
            guard let sep = entry.firstIndex(of: "_"), let stamp = Int(entry[..<sep]) else { return nil }
            return (stamp, String(entry[entry.index(after: sep)...]), entry)
        }.sorted { $0.stamp > $1.stamp }
        var available: [String] = []
        for e in entries where !available.contains(e.name) { available.append(e.name) }
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else {
            return name.isEmpty ? .notFound(name: name, available: available) : .invalidName(name)
        }
        guard let newest = entries.first(where: { $0.name == name }) else { return .notFound(name: name, available: available) }
        let target = paths.skillsDir.appendingPathComponent(name)
        if fileManager.fileExists(atPath: target.path) { return .exists(name: name) }
        do {
            try fileManager.createDirectory(at: paths.skillsDir, withIntermediateDirectories: true)
            try fileManager.moveItem(at: trashDir.appendingPathComponent(newest.entry), to: target)
        } catch {
            return .failed(name: name, reason: error.localizedDescription)
        }
        await onSkillsChanged?()
        return .restored(name: name)
    }

    /// Whether the text after `/skills curate` asks for the quarantine: only the word `--apply` does.
    static func curateApplies(_ rest: String) -> Bool {
        rest.split(whereSeparator: \.isWhitespace).contains("--apply")
    }

    /// What `/skills restore` says for each outcome.
    static func restoreMessage(_ result: RestoreResult) -> String {
        switch result {
        case .restored(let name):
            return "Restored skill **\(name)** from the quarantine."
        case .exists(let name):
            return "A skill named **\(name)** already exists, so nothing was restored. Rename or delete it first."
        case .invalidName(let name):
            return "'\(name)' is not a skill name."
        case .failed(let name, let reason):
            return "Could not restore **\(name)**: \(reason) The quarantined copy is still in the trash."
        case .notFound(let name, let available):
            let list = available.isEmpty ? "The quarantine is empty." : "Quarantined: " + available.map { "`\($0)`" }.joined(separator: ", ") + "."
            return (name.isEmpty ? "Usage: `/skills restore <name>`. " : "No quarantined skill named **\(name)**. ") + list
        }
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
