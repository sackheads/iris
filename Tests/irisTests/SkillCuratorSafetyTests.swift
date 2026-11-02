import Testing
import Foundation
@testable import IrisKit

/// Sets a folder's modification time days back, so the curator reads it as no draft (#48).
func ageFolder(_ url: URL, days: Double = 3) throws {
    let old = [FileAttributeKey.modificationDate: Date(timeIntervalSinceNow: -days * 86_400)]
    let file = url.appendingPathComponent("SKILL.md")
    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.setAttributes(old, ofItemAtPath: file.path) }
    try FileManager.default.setAttributes(old, ofItemAtPath: url.path)
}

/// #48: the curator moves nothing unless asked, leaves a draft alone, and a quarantined skill comes back.
@Suite("Skill curator safety (#48)")
struct SkillCuratorSafetyTests {
    private func skill(_ name: String, in paths: IrisPaths, body: String?, aged: Bool = true) throws -> URL {
        let folder = paths.skillsDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let body { try body.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8) }
        if aged { try ageFolder(folder) }
        return folder
    }

    private func trash(_ paths: IrisPaths) -> URL { paths.memoryDir.appendingPathComponent("trash/skills") }

    @Test("a dry run, the default, reports what it would quarantine and moves nothing")
    func dryRunMovesNothing() async throws {
        try await withTempDirectory(prefix: "iris-curator-dry") { root in
            let paths = IrisPaths(root: root); try paths.ensureDirectories()
            let empty = try skill("empty-one", in: paths, body: "")
            let report = await SkillCurator.shared.curateSkills(paths: paths)
            #expect(!report.applied && report.prunedSkillNames == ["empty-one"])
            #expect(FileManager.default.fileExists(atPath: empty.path), "still in the skills folder")
            #expect(!FileManager.default.fileExists(atPath: trash(paths).path), "no trash was made")
            let md = try String(contentsOf: paths.memoryDir.appendingPathComponent("curator/REPORT.md"), encoding: .utf8)
            #expect(md.contains("Dry run") && md.contains("Would quarantine") && md.contains("empty-one"))
        }
    }

    @Test("--apply quarantines to the trash with the timestamped name")
    func applyQuarantines() async throws {
        try await withTempDirectory(prefix: "iris-curator-apply") { root in
            let paths = IrisPaths(root: root); try paths.ensureDirectories()
            let empty = try skill("empty-one", in: paths, body: nil)
            let report = await SkillCurator.shared.curateSkills(paths: paths, apply: true)
            #expect(report.applied && report.prunedSkillNames == ["empty-one"])
            #expect(!FileManager.default.fileExists(atPath: empty.path))
            let moved = try FileManager.default.contentsOfDirectory(atPath: trash(paths).path)
            #expect(moved.count == 1 && moved[0].hasSuffix("_empty-one"))
        }
    }

    @Test("a recent folder with no usable SKILL.md is a draft: skipped, even with --apply")
    func draftsAreSkipped() async throws {
        try await withTempDirectory(prefix: "iris-curator-draft") { root in
            let paths = IrisPaths(root: root); try paths.ensureDirectories()
            let noFile = try skill("no-file", in: paths, body: nil, aged: false)
            let short = try skill("short", in: paths, body: "# todo", aged: false)
            // An old folder whose SKILL.md is being rewritten now is a draft too.
            let editing = try skill("editing", in: paths, body: "", aged: true)
            try "".write(to: editing.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            let stale = try skill("stale", in: paths, body: nil)
            let report = await SkillCurator.shared.curateSkills(paths: paths, apply: true)
            #expect(Set(report.draftSkippedNames) == ["no-file", "short", "editing"])
            #expect(report.prunedSkillNames == ["stale"], "only the old one is quarantined")
            for kept in [noFile, short, editing] { #expect(FileManager.default.fileExists(atPath: kept.path)) }
            #expect(!FileManager.default.fileExists(atPath: stale.path))
            // A day and a minute on, the same folder is no draft.
            let later = Date(timeIntervalSinceNow: 86_400 + 60)
            let again = await SkillCurator.shared.curateSkills(paths: paths, apply: false, now: later)
            #expect(Set(again.prunedSkillNames) == ["no-file", "short", "editing"] && again.draftSkippedNames.isEmpty)
        }
    }

    @Test("a valid skill is never touched by either mode")
    func validSkillUntouched() async throws {
        try await withTempDirectory(prefix: "iris-curator-valid") { root in
            let paths = IrisPaths(root: root); try paths.ensureDirectories()
            let ok = try skill("valid", in: paths, body: "---\nname: valid\ndescription: A skill that does a thing\n---\n\nSteps go here.")
            let report = await SkillCurator.shared.curateSkills(paths: paths, apply: true)
            #expect(report.validSkillsCount == 1 && report.prunedSkillNames.isEmpty && FileManager.default.fileExists(atPath: ok.path))
        }
    }

    @Test("restore brings the newest quarantined copy back, and tells the hook")
    func restoreNewest() async throws {
        try await withTempDirectory(prefix: "iris-curator-restore") { root in
            let paths = IrisPaths(root: root); try paths.ensureDirectories()
            for (stamp, marker) in [(100, "old"), (200, "new")] {
                let dir = trash(paths).appendingPathComponent("\(stamp)_my_skill")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try marker.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            }
            let count = RestoreCount()
            let result = await SkillCurator.shared.restoreSkill(name: " my_skill ", paths: paths, onSkillsChanged: { count.bump() })
            #expect(result == .restored(name: "my_skill") && count.value == 1)
            let text = try String(contentsOf: paths.skillsDir.appendingPathComponent("my_skill/SKILL.md"), encoding: .utf8)
            #expect(text == "new", "the newest copy, from a name that holds an underscore")
            #expect(FileManager.default.fileExists(atPath: trash(paths).appendingPathComponent("100_my_skill").path), "the older copy stays")
        }
    }

    @Test("restore never overwrites a skill of that name")
    func restoreRefusesToOverwrite() async throws {
        try await withTempDirectory(prefix: "iris-curator-exists") { root in
            let paths = IrisPaths(root: root); try paths.ensureDirectories()
            let live = try skill("alpha", in: paths, body: "live copy of the skill with enough text")
            let dir = trash(paths).appendingPathComponent("500_alpha")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let result = await SkillCurator.shared.restoreSkill(name: "alpha", paths: paths)
            #expect(result == .exists(name: "alpha"))
            #expect(try String(contentsOf: live.appendingPathComponent("SKILL.md"), encoding: .utf8).hasPrefix("live copy"))
            #expect(FileManager.default.fileExists(atPath: dir.path), "the quarantined copy stays")
        }
    }

    @Test("a name that is not quarantined lists what is; a path-like name is refused")
    func restoreNotFoundAndInvalid() async throws {
        try await withTempDirectory(prefix: "iris-curator-missing") { root in
            let paths = IrisPaths(root: root); try paths.ensureDirectories()
            for entry in ["100_beta", "300_gamma", "200_beta", "junk"] {
                try FileManager.default.createDirectory(at: trash(paths).appendingPathComponent(entry), withIntermediateDirectories: true)
            }
            let missing = await SkillCurator.shared.restoreSkill(name: "nope", paths: paths)
            #expect(missing == .notFound(name: "nope", available: ["gamma", "beta"]), "newest first, once each, junk ignored")
            #expect(await SkillCurator.shared.restoreSkill(name: "", paths: paths) == .notFound(name: "", available: ["gamma", "beta"]))
            #expect(await SkillCurator.shared.restoreSkill(name: "../beta", paths: paths) == .invalidName("../beta"))
            #expect(!FileManager.default.fileExists(atPath: paths.skillsDir.appendingPathComponent("beta").path))
            let empty = IrisPaths(root: root.appendingPathComponent("elsewhere"))
            #expect(SkillCurator.restoreMessage(await SkillCurator.shared.restoreSkill(name: "x", paths: empty)).contains("quarantine is empty"))
            #expect(SkillCurator.restoreMessage(missing).contains("`gamma`"))
        }
    }

    @Test("a copy that cannot be moved says so and stays in the quarantine; a name with two dots is a name")
    func restoreFailureIsReported() async throws {
        try await withTempDirectory(prefix: "iris-curator-failed") { root in
            let paths = IrisPaths(root: root); try paths.ensureDirectories()
            for name in ["gamma", "a..b"] {
                let dir = trash(paths).appendingPathComponent("700_\(name)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            // The skills path is a file, so nothing can be moved into it.
            try FileManager.default.removeItem(at: paths.skillsDir)
            try "not a folder".write(to: paths.skillsDir, atomically: true, encoding: .utf8)
            let result = await SkillCurator.shared.restoreSkill(name: "gamma", paths: paths)
            guard case .failed(let name, let reason) = result else { Issue.record("expected .failed, got \(result)"); return }
            #expect(name == "gamma" && !reason.isEmpty)
            #expect(FileManager.default.fileExists(atPath: trash(paths).appendingPathComponent("700_gamma").path), "still quarantined")
            let message = SkillCurator.restoreMessage(result)
            #expect(message.contains("Could not restore") && !message.contains("No quarantined skill"))
            // `a..b` is not refused as a path: it reaches the same failure (the skills path), not .invalidName.
            #expect(await SkillCurator.shared.restoreSkill(name: "a..b", paths: paths) != .invalidName("a..b"))
        }
    }

    @Test("only the word --apply asks for the quarantine")
    func applyFlag() {
        #expect(!SkillCurator.curateApplies(""))
        #expect(SkillCurator.curateApplies(" --apply"))
        #expect(SkillCurator.curateApplies("  --dry --apply "))
        #expect(!SkillCurator.curateApplies(" --applyx") && !SkillCurator.curateApplies(" apply"))
    }
}

private final class RestoreCount: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
