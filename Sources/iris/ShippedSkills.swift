import Foundation

/// Seeds shipped default content (the library skill + README, and the external-libraries skill
/// + EXTERNAL_LIBRARIES.md registry) into an install if absent. Idempotent and non-destructive:
/// a file is written only when missing, so bot edits are preserved and a deliberately deleted
/// file re-seeds on the next launch. Runs at startup after `IrisMigrator`, so it seeds into the
/// already-migrated `memory/` layout. Once seeded, skills are picked up by the existing
/// `SkillManager.discoverSkills()`.
enum ShippedSkills {

    /// Production entry point: reads the bundled assets and seeds each into the install if absent.
    static func seedIfNeeded(_ paths: IrisPaths) {
        seed([
            SeedItem(content: bundledText("library-SKILL"),
                     target: paths.skillsDir.appendingPathComponent("library/SKILL.md")),
            SeedItem(content: bundledText("library-README"),
                     target: paths.libraryDir.appendingPathComponent("README.md")),
            SeedItem(content: bundledText("external-libraries-SKILL"),
                     target: paths.skillsDir.appendingPathComponent("external-libraries/SKILL.md")),
            SeedItem(content: bundledText("external-libraries-REGISTRY"),
                     target: paths.libraryDir.appendingPathComponent("EXTERNAL_LIBRARIES.md")),
            SeedItem(content: bundledText("sandbox-usage-SKILL"),
                     target: paths.skillsDir.appendingPathComponent("sandbox-usage/SKILL.md")),
            SeedItem(content: bundledText("google-workspace-SKILL"),
                     target: paths.skillsDir.appendingPathComponent("google-workspace/SKILL.md")),
            SeedItem(content: bundledText("librarian-SKILL"),
                     target: paths.skillsDir.appendingPathComponent("librarian/SKILL.md")),
        ], ensuring: paths)
    }

    private struct SeedItem { let content: String; let target: URL }

    /// Seeds each item if its target is absent — idempotent and non-destructive (bot edits are
    /// preserved). Empty content (a bundle asset that failed to load) is skipped.
    private static func seed(_ items: [SeedItem], ensuring paths: IrisPaths) {
        try? paths.ensureDirectories()
        let fm = FileManager.default
        for item in items where !item.content.isEmpty {
            guard !fm.fileExists(atPath: item.target.path) else { continue }
            try? fm.createDirectory(at: item.target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? item.content.write(to: item.target, atomically: true, encoding: .utf8)
        }
    }

    /// Read a bundled markdown asset by resource name (no extension). Returns "" if missing so a
    /// packaging error skips seeding rather than crashing.
    static func bundledText(_ resource: String) -> String {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return IrisPaths.standard.agentFacing(text)
    }
}
