import Foundation

struct SkillManager {
    static let shared = SkillManager()
    
    // SOUL and skill files are FIRST-PARTY content (Iris's own identity and learned behaviors),
    // not untrusted external data — so they are loaded raw and are NOT run through the injection
    // guard. Guarding them was actively harmful: Tier 1 strips the `---` OKF frontmatter
    // delimiters (so `description:` never parsed → "No description provided"), and the guard
    // wraps the content in <untrusted_context> — the exact tag SYSTEM.md tells the model to
    // treat as passive data and ignore, which self-neutralized the persona. Untrusted sources
    // (tool outputs, workspace AGENTS.md, web results) remain guarded at their own call sites.
    func loadSOUL(paths: IrisPaths = .default) async -> String {
        if let content = try? String(contentsOfFile: paths.soulMd.path, encoding: .utf8) {
            return content
        }
        return "You are Iris, a native macOS agent running on the local machine."
    }

    /// Auto-loads any custom, user-defined rules from `~/.iris/rules/` and returns them
    /// as a combined Markdown block to be appended directly to the system prompt.
    /// `extraRuleFiles: nil` pulls enabled plugins' rule files from PluginManager; tests
    /// pass explicit rule file URLs.
    func loadCustomRules(paths: IrisPaths = .default, extraRuleFiles: [URL]? = nil) async -> String {
        let rulesDir = paths.rulesDir.path
        let fileManager = FileManager.default

        var rulesContent = ""
        if let items = try? fileManager.contentsOfDirectory(atPath: rulesDir) {
            for item in items.sorted() {
                guard !item.hasPrefix(".") else { continue }
                let fileURL = paths.rulesDir.appendingPathComponent(item)
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
                    if let content = try? String(contentsOfFile: fileURL.path, encoding: .utf8),
                       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        rulesContent += "\n\n# Rule: \(item)\n\(content)\n"
                    }
                }
            }
        }

        let pluginRules: [URL]
        if let extraRuleFiles {
            pluginRules = extraRuleFiles
        } else {
            pluginRules = await PluginManager.shared.ruleFiles()
        }
        // Plugin rules are third-party content. Unlike the user's own ~/.iris/rules, they pass
        // the same InjectionGuard path as workspace AGENTS.md before reaching the system prompt.
        for fileURL in pluginRules {
            if let content = try? String(contentsOf: fileURL, encoding: .utf8),
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let structuralSafe = PromptInjectionGuard.sanitizeUntrustedInput(content)
                let safe = await InjectionGuard.sanitize(
                    structuralSafe, contextTag: "plugin_rule_\(fileURL.lastPathComponent)", maxTier: .tier3_canary)
                rulesContent += "\n\n# Rule (plugin): \(fileURL.lastPathComponent)\n\(safe)\n"
            }
        }
        return rulesContent
    }

    /// A registered skill, parsed from its SKILL.md frontmatter. The body is never read.
    struct SkillInfo: Sendable {
        let name: String
        let description: String
        let folderName: String
        let skillFilePath: String
    }

    /// Deterministic list of registered skills across the built-in skills dir and any plugin
    /// skill roots. `extraRoots: nil` pulls enabled plugins' roots from PluginManager; tests
    /// pass explicit roots. Sorted by display name.
    func listSkills(paths: IrisPaths = .default, extraRoots: [URL]? = nil) async -> [SkillInfo] {
        let pluginRoots: [URL]
        if let extraRoots {
            pluginRoots = extraRoots
        } else {
            pluginRoots = await PluginManager.shared.skillRoots()
        }
        let roots = [paths.skillsDir] + pluginRoots
        let fileManager = FileManager.default

        var skills: [SkillInfo] = []
        for root in roots {
            guard let items = try? fileManager.contentsOfDirectory(atPath: root.path) else { continue }
            for item in items where !item.hasPrefix(".") {
                let skillPath = root.appendingPathComponent(item).appendingPathComponent("SKILL.md").path
                guard fileManager.fileExists(atPath: skillPath),
                      let content = try? String(contentsOfFile: skillPath, encoding: .utf8) else {
                    continue
                }
                // Only the frontmatter (name/description) is surfaced here — never the skill body.
                skills.append(parseFrontmatter(from: content, folderName: item, skillFilePath: skillPath))
            }
        }
        return skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func discoverSkills(paths: IrisPaths = .default, activeBundle: SkillBundle? = nil, extraRoots: [URL]? = nil) async -> String {
        let allSkills = await listSkills(paths: paths, extraRoots: extraRoots)
        let skills: [SkillInfo]
        if let bundle = activeBundle {
            let bundleNames = Set(bundle.skillNames.map { $0.lowercased() })
            skills = allSkills.filter {
                bundleNames.contains($0.name.lowercased()) || bundleNames.contains($0.folderName.lowercased())
            }
        } else {
            skills = allSkills
        }

        guard !skills.isEmpty else {
            if let bundle = activeBundle {
                return "# Available Skills (Active Bundle: \(bundle.name))\n\nNo matching skills found in active bundle."
            }
            return "# Available Skills\n\nNo skills found."
        }

        var skillsSummary = "# Available Skills" + (activeBundle != nil ? " (Active Bundle: \(activeBundle!.name))\n\n" : "\n\n")
        for skill in skills {
            skillsSummary += "## Skill: \(skill.name)\n**Description:** \(skill.description)\n"
            skillsSummary += "**Path:** \(skill.skillFilePath)\n\n"
        }
        return skillsSummary
    }

    private func parseFrontmatter(from content: String, folderName: String, skillFilePath: String) -> SkillInfo {
        let lines = content.components(separatedBy: .newlines)
        var isFrontmatter = false
        // Display-name precedence: explicit `name:` > OKF `title:` > folder name.
        var explicitName: String?
        var title: String?
        var description = "No description provided."

        func value(_ line: String, _ key: String) -> String {
            String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
        }

        for line in lines {
            if line == "---" {
                if isFrontmatter { break }
                isFrontmatter = true
                continue
            }
            if isFrontmatter {
                if line.starts(with: "name:") {
                    explicitName = value(line, "name:")
                } else if line.starts(with: "title:") {
                    title = value(line, "title:")
                } else if line.starts(with: "description:") {
                    description = value(line, "description:")
                }
            }
        }

        let name = explicitName ?? title ?? folderName
        return SkillInfo(name: name, description: description, folderName: folderName, skillFilePath: skillFilePath)
    }

    /// Reads and returns the full `SKILL.md` content for a skill by name or folder name.
    func readSkillBody(name: String, paths: IrisPaths = .default, extraRoots: [URL]? = nil) async -> String? {
        let skills = await listSkills(paths: paths, extraRoots: extraRoots)
        let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let skill = skills.first(where: {
            $0.name.lowercased() == normalized || $0.folderName.lowercased() == normalized
        }) else {
            return nil
        }
        return try? String(contentsOfFile: skill.skillFilePath, encoding: .utf8)
    }
}
