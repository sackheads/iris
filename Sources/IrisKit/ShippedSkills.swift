import Foundation
import CryptoKit

/// Seeds shipped default content (the library skill + README, and the external-libraries skill
/// + EXTERNAL_LIBRARIES.md registry) into an install, and keeps it current. Non-destructive: a file
/// is written when it is missing, and replaced only when it is still byte-identical to an EARLIER
/// shipped version (`previousVersions`), so a file the user or the bot has edited is never touched
/// (#864). A deliberately deleted file re-seeds on the next launch. Runs at startup after
/// `IrisMigrator`, so it seeds into the already-migrated `memory/` layout. Once seeded, skills are
/// picked up by the existing `SkillManager.discoverSkills()`.
///
/// Editing a bundled asset: add the hash of the text it replaces to `previousVersions`
/// (`scripts/shipped-text-hashes.sh <file>` prints it), or existing installs keep the old text.
enum ShippedSkills {

    /// SHA-256 (hex) of the bytes an EARLIER version of each bundled asset left on disk, by asset
    /// name. Both spellings of the home where the text names one: a dev build rewrites `~/.iris` to
    /// `~/.iris-dev` (`IrisPaths.agentFacing`). An installed file whose hash is here, and is not the
    /// current text, is unmodified shipped content and is replaced; anything else is the user's.
    /// An asset absent from this table has only ever shipped one text. A list that misses an old
    /// version fails safe: that version is left alone, never overwritten.
    static let previousVersions: [String: [String]] = [
        // Before #866's wording (#248) ("This session's container ...", "within the session").
        "sandbox-usage-SKILL": ["d67152235ba866283a4c8fb1db7b16a18578066f7f723abc7ed7e08b18f56075"],
    ]

    /// Production entry point: reads the bundled assets and seeds each into the install if absent.
    static func seedIfNeeded(_ paths: IrisPaths) {
        let replaced = seed([
            SeedItem(asset: "library-SKILL", content: bundledText("library-SKILL"),
                     target: paths.skillsDir.appendingPathComponent("library/SKILL.md")),
            SeedItem(asset: "library-README", content: bundledText("library-README"),
                     target: paths.libraryDir.appendingPathComponent("README.md")),
            SeedItem(asset: "external-libraries-SKILL", content: bundledText("external-libraries-SKILL"),
                     target: paths.skillsDir.appendingPathComponent("external-libraries/SKILL.md")),
            SeedItem(asset: "external-libraries-REGISTRY", content: bundledText("external-libraries-REGISTRY"),
                     target: paths.libraryDir.appendingPathComponent("EXTERNAL_LIBRARIES.md")),
            SeedItem(asset: "sandbox-usage-SKILL", content: bundledText("sandbox-usage-SKILL"),
                     target: paths.skillsDir.appendingPathComponent("sandbox-usage/SKILL.md")),
            SeedItem(asset: "google-workspace-SKILL", content: bundledText("google-workspace-SKILL"),
                     target: paths.skillsDir.appendingPathComponent("google-workspace/SKILL.md")),
            SeedItem(asset: "librarian-SKILL", content: bundledText("librarian-SKILL"),
                     target: paths.skillsDir.appendingPathComponent("librarian/SKILL.md")),
        ], ensuring: paths)
        if replaced > 0 { print("[ShippedSkills] updated \(replaced) unmodified shipped file(s) to the current text") }
    }

    struct SeedItem { let asset: String; let content: String; let target: URL }

    /// Seeds each item if its target is absent, and replaces one that is still an earlier shipped
    /// version (its hash is in `previous[asset]`); returns how many it replaced. A file that is
    /// already current, or that is anything else, is left alone (bot edits are preserved). Empty
    /// content (a bundle asset that failed to load) is skipped.
    @discardableResult
    static func seed(_ items: [SeedItem], previous: [String: [String]] = previousVersions,
                     ensuring paths: IrisPaths) -> Int {
        try? paths.ensureDirectories()
        let fm = FileManager.default
        var replaced = 0
        for item in items where !item.content.isEmpty {
            if fm.fileExists(atPath: item.target.path) {
                // A symlink is the user's arrangement (a skill kept elsewhere): replacing the file
                // would replace the link, not the text behind it.
                if (try? fm.destinationOfSymbolicLink(atPath: item.target.path)) != nil { continue }
                guard let installed = try? Data(contentsOf: item.target) else { continue }
                let hash = sha256Hex(installed)
                guard hash != sha256Hex(Data(item.content.utf8)),
                      previous[item.asset]?.contains(hash) == true else { continue }
                if (try? item.content.write(to: item.target, atomically: true, encoding: .utf8)) != nil { replaced += 1 }
                continue
            }
            try? fm.createDirectory(at: item.target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? item.content.write(to: item.target, atomically: true, encoding: .utf8)
        }
        return replaced
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
