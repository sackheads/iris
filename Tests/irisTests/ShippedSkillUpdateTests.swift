import Testing
import Foundation
@testable import IrisKit

enum ShippedSkillFixtures {
    /// `sandbox-usage-SKILL.md` as it shipped before #866 (its hash is in `ShippedSkills.previousVersions`).
    static let sandboxUsageBefore866: String = #"""
---
type: skill
title: sandbox-usage
description: How to use the per-conversation sandbox container efficiently (persistent disk state, non-persistent shell state, idle resets).
tags: [sandbox, shell, efficiency]
timestamp: 2026-07-25
---

# Using the Sandbox Efficiently

When sandboxing is enabled, `run_command` runs inside a Linux container that lives for the whole
conversation. The active workspace is mounted at the **same absolute path** as on the host, so a
file written with `write_file` is visible to your commands at that path.

## What persists, what doesn't

- **Disk state persists** within the session: packages you install, files you create, and build
  artifacts remain available to later commands. Install or build once, then reuse — don't
  reinstall every command.
- **Shell state does NOT persist across separate `run_command` calls.** Each command is a fresh
  process, so `cd` and `export` do not carry over. Instead:
  - Chain within one command: `cd subdir && make`.
  - Use absolute paths.
  - Set environment inline: `FOO=bar ./script.sh`.

## Efficiency

- Prefer a few combined commands over many tiny ones. Chaining with `&&` is cheaper and clearer
  than issuing each step as its own `run_command`.

## Idle resets

An idle session's container may be reclaimed after a period of inactivity to free resources. When
that happens, in-container disk state is cleared (your **host workspace files are never touched**).
You will see a notice prefixed to the next command's output:

> `[sandbox] This session's container was reclaimed after being idle; ...`

Treat that notice as a signal to re-run any setup (installs/builds) before relying on it.
"""# + "\n"
}

/// #864: a shipped skill that is still an earlier shipped version is brought up to date; one the user
/// edited never is. All on a temp home (`IrisPaths(root:)`), never the real `~/.iris`.
@Suite("Shipped skills update (#864)")
struct ShippedSkillUpdateTests {
    private func home() throws -> (IrisPaths, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-864-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()
        return (paths, root)
    }
    private func hash(_ text: String) -> String { ShippedSkills.sha256Hex(Data(text.utf8)) }
    private func item(_ content: String, in paths: IrisPaths) -> ShippedSkills.SeedItem {
        .init(asset: "demo", content: content, target: paths.skillsDir.appendingPathComponent("demo/SKILL.md"))
    }

    @Test("an installed copy that is an earlier shipped version is replaced with the current text")
    func unmodifiedOldVersionIsUpdated() throws {
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let target = item("v2", in: paths).target
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "v1".write(to: target, atomically: true, encoding: .utf8)
        let replaced = ShippedSkills.seed([item("v2", in: paths)], previous: ["demo": [hash("v1")]], ensuring: paths)
        #expect(replaced == 1)
        #expect(try String(contentsOf: target, encoding: .utf8) == "v2")
    }

    @Test("a copy the user edited is never touched, even when a newer shipped version exists")
    func editedIsLeftAlone() throws {
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let target = item("v2", in: paths).target
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "v1 plus my notes".write(to: target, atomically: true, encoding: .utf8)
        let replaced = ShippedSkills.seed([item("v2", in: paths)], previous: ["demo": [hash("v1")]], ensuring: paths)
        #expect(replaced == 0)
        #expect(try String(contentsOf: target, encoding: .utf8) == "v1 plus my notes")
    }

    @Test("an absent file is seeded as before, and a current one is left alone and not counted")
    func absentSeedsCurrentStays() throws {
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let target = item("v2", in: paths).target
        #expect(ShippedSkills.seed([item("v2", in: paths)], previous: ["demo": [hash("v1")]], ensuring: paths) == 0)
        #expect(try String(contentsOf: target, encoding: .utf8) == "v2", "seeded")
        // The current text is also in the list (an asset edited back): still not a replacement.
        #expect(ShippedSkills.seed([item("v2", in: paths)], previous: ["demo": [hash("v1"), hash("v2")]], ensuring: paths) == 0)
        #expect(try String(contentsOf: target, encoding: .utf8) == "v2")
    }

    @Test("a hash list that misses the installed version fails safe: the file is left alone")
    func listMissingTheVersionLeavesIt() throws {
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let target = item("v3", in: paths).target
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "v1".write(to: target, atomically: true, encoding: .utf8)   // the oldest, not in the list
        let replaced = ShippedSkills.seed([item("v3", in: paths)], previous: ["demo": [hash("v2")]], ensuring: paths)
        #expect(replaced == 0)
        #expect(try String(contentsOf: target, encoding: .utf8) == "v1")
        // No list at all for the asset is the same.
        #expect(ShippedSkills.seed([item("v3", in: paths)], previous: [:], ensuring: paths) == 0)
        #expect(try String(contentsOf: target, encoding: .utf8) == "v1")
    }

    @Test("a dev install's spelling of an earlier version (~/.iris-dev) is found by its own hash")
    func devSpellingIsUpdated() throws {
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let release = "keep notes in ~/.iris/memory"
        let dev = "keep notes in ~/.iris-dev/memory"
        let target = item("new", in: paths).target
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try dev.write(to: target, atomically: true, encoding: .utf8)
        #expect(ShippedSkills.seed([item("new", in: paths)], previous: ["demo": [hash(release), hash(dev)]], ensuring: paths) == 1)
        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
    }

    @Test("the home rewrite scripts/shipped-text-hashes.sh prints for dev is the one IrisPaths.agentFacing makes")
    func scriptSpellingMatchesTheApp() {
        // The fixture holds the edge cases of the rewrite: a path, a longer name, a sentence-final
        // period, a `.bak` suffix, `rc`, and the end of the text. Its two hashes come from the script.
        let fixture = "see ~/.iris/x and ~/.iris-dev and ~/.iris. but not ~/.iris.bak or ~/.irisrc, also ~/.iris\n"
        #expect(hash(fixture) == "ced2cef46d93122aaf41f45a279cea4efcfab684b4276810c135bdf73a09e24b")
        // `IrisPaths.standard` is this build's home: `~/.iris-dev` under `swift test`.
        #expect(IrisPaths.standard.displayRoot == "~/.iris-dev")
        #expect(hash(IrisPaths.standard.agentFacing(fixture)) == "d4cf699366ca0ac138c2e8c20d9961c149965592f50042451a3e5d787d451cf4")
    }

    @Test("the real table: the sandbox skill as it shipped before #866 is a known earlier version, and an install of it is brought current")
    func sandboxSkillBefore866() throws {
        let old = ShippedSkillFixtures.sandboxUsageBefore866
        #expect(ShippedSkills.previousVersions["sandbox-usage-SKILL"]?.contains(hash(old)) == true,
                "the fixture is the text whose hash is listed")
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let target = paths.skillsDir.appendingPathComponent("sandbox-usage/SKILL.md")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try old.write(to: target, atomically: true, encoding: .utf8)
        ShippedSkills.seedIfNeeded(paths)
        #expect(try String(contentsOf: target, encoding: .utf8) == ShippedSkills.bundledText("sandbox-usage-SKILL"),
                "whatever the current bundled text is, the install now has it")
    }
}
