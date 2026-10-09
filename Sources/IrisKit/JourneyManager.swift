import Foundation

public struct JourneyItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let category: String // "Skill", "Profile", "Soul", "Fact"
    public let timestamp: Date
    public let summary: String
    public let path: String?

    public init(id: UUID = UUID(), title: String, category: String, timestamp: Date, summary: String, path: String? = nil) {
        self.id = id
        self.title = title
        self.category = category
        self.timestamp = timestamp
        self.summary = summary
        self.path = path
    }
}

public final class JourneyManager: Sendable {
    public static let shared = JourneyManager()

    private init() {}

    public func buildTimeline() async -> [JourneyItem] {
        await buildTimeline(paths: .default)
    }

    func buildTimeline(paths: IrisPaths) async -> [JourneyItem] {
        var items: [JourneyItem] = []
        let fileManager = FileManager.default
        let isoFormatter = ISO8601DateFormatter()

        // 1. Scan USER.md
        if fileManager.fileExists(atPath: paths.userMd.path),
           let content = try? String(contentsOf: paths.userMd, encoding: .utf8) {
            let (desc, date) = parseFrontmatterDetails(content: content, fallbackDate: getFileModDate(paths.userMd))
            items.append(JourneyItem(title: "User Profile Updated", category: "Profile", timestamp: date, summary: desc, path: paths.userMd.path))
        }

        // 2. Scan SOUL.md
        if fileManager.fileExists(atPath: paths.soulMd.path),
           let content = try? String(contentsOf: paths.soulMd, encoding: .utf8) {
            let (desc, date) = parseFrontmatterDetails(content: content, fallbackDate: getFileModDate(paths.soulMd))
            items.append(JourneyItem(title: "Persona / SOUL Evolved", category: "Soul", timestamp: date, summary: desc, path: paths.soulMd.path))
        }

        // 3. Scan Skills
        if let skillFolders = try? fileManager.contentsOfDirectory(atPath: paths.skillsDir.path) {
            for folder in skillFolders {
                let skillFile = paths.skillsDir.appendingPathComponent("\(folder)/SKILL.md")
                if fileManager.fileExists(atPath: skillFile.path),
                   let content = try? String(contentsOf: skillFile, encoding: .utf8) {
                    let (desc, date) = parseFrontmatterDetails(content: content, fallbackDate: getFileModDate(skillFile))
                    items.append(JourneyItem(title: "Learned Skill: \(folder)", category: "Skill", timestamp: date, summary: desc, path: skillFile.path))
                }
            }
        }

        // 4. Scan FactStore
        if let facts = try? FactStoreManager.shared.search(query: "", limit: 20, countsAsRetrieval: false) {
            for fact in facts {
                items.append(JourneyItem(title: "Fact Saved [\(fact.category)]", category: "Fact", timestamp: fact.timestamp, summary: fact.content))
            }
        }

        return items.sorted { $0.timestamp > $1.timestamp }
    }

    public func formatTimelineMarkdown(items: [JourneyItem]) -> String {
        guard !items.isEmpty else {
            return "No learned memories or skills found in Iris journey timeline."
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var markdown = "### 📜 Iris Learning Journey Timeline (\(items.count) Milestones)\n\n"
        for item in items {
            let dateStr = formatter.string(from: item.timestamp)
            let badge = "[\(item.category.uppercased())]"
            markdown += "• **\(dateStr)** `\(badge)` **\(item.title)**\n  *\(item.summary)*\n\n"
        }
        return markdown
    }

    private func getFileModDate(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
    }

    private func parseFrontmatterDetails(content: String, fallbackDate: Date) -> (summary: String, date: Date) {
        let lines = content.components(separatedBy: .newlines)
        var inFrontmatter = false
        var desc = "No summary provided."
        var date = fallbackDate
        let isoFormatter = ISO8601DateFormatter()

        for line in lines {
            if line == "---" {
                if inFrontmatter { break }
                inFrontmatter = true
                continue
            }
            if inFrontmatter {
                if line.starts(with: "description:") {
                    desc = String(line.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
                } else if line.starts(with: "timestamp:") {
                    let rawDate = String(line.dropFirst("timestamp:".count)).trimmingCharacters(in: .whitespaces)
                    if let parsed = isoFormatter.date(from: rawDate) {
                        date = parsed
                    }
                }
            }
        }
        return (desc, date)
    }
}
