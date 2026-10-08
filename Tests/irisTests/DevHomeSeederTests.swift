import Foundation
import Testing
@testable import iris

@Suite("Dev home seeding")
struct DevHomeSeederTests {
    private func tempHomes() throws -> (IrisPaths, IrisPaths, () -> Void) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("seed-\(UUID().uuidString)")
        let src = IrisPaths(root: base.appendingPathComponent("release"))
        let dst = IrisPaths(root: base.appendingPathComponent("dev"))
        try src.ensureDirectories()
        try "I live at ~/.iris/memory".write(to: src.userMd, atomically: true, encoding: .utf8)
        try Data("db".utf8).write(to: src.conversationsDB)
        try FileManager.default.createDirectory(at: src.modelsDir, withIntermediateDirectories: true)
        return (src, dst, { try? FileManager.default.removeItem(at: base) })
    }

    @Test("copies files, symlinks models, rewrites memory text, copies secrets")
    func seeds() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        let srcKC = KeychainManager(serviceSuffix: "")
        let dstKC = KeychainManager(serviceSuffix: ".dev")
        srcKC.saveSecrets(["ANTHROPIC_API_KEY": "sk"], service: KeychainManager.legacyService)
        srcKC.saveSecrets(["t": "1"], service: KeychainManager.pluginService("p"))

        let report = try DevHomeSeeder.seed(from: src, to: dst, identity: .dev, sourceKeychain: srcKC, destKeychain: dstKC)

        #expect(FileManager.default.fileExists(atPath: dst.conversationsDB.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dst.modelsDir.path) == src.modelsDir.path)
        #expect(try String(contentsOf: dst.userMd, encoding: .utf8) == "I live at \(dst.displayRoot)/memory")
        #expect(dstKC.loadSecrets() == ["ANTHROPIC_API_KEY": "sk"])
        #expect(dstKC.secrets(service: KeychainManager.pluginService("p")) == ["t": "1"])
        #expect(report.keychainServicesCopied == 2)
    }

    @Test("refuses under the release identity")
    func refusesRelease() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        #expect(throws: DevHomeSeeder.Failure.releaseBuild) {
            try DevHomeSeeder.seed(from: src, to: dst, identity: .release,
                                   sourceKeychain: .init(serviceSuffix: ""), destKeychain: .init(serviceSuffix: ".dev"))
        }
        #expect(!FileManager.default.fileExists(atPath: dst.root.path))
    }

    @Test("refuses a non-empty destination; accepts an empty one")
    func destination() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        try FileManager.default.createDirectory(at: dst.root, withIntermediateDirectories: true)
        _ = try DevHomeSeeder.seed(from: src, to: dst, identity: .dev,
                                   sourceKeychain: .init(serviceSuffix: ""), destKeychain: .init(serviceSuffix: ".dev"))
        #expect(throws: DevHomeSeeder.Failure.destinationNotEmpty(dst.root.path)) {
            try DevHomeSeeder.seed(from: src, to: dst, identity: .dev,
                                   sourceKeychain: .init(serviceSuffix: ""), destKeychain: .init(serviceSuffix: ".dev"))
        }
    }

    @Test("refuses while an app holds the source store")
    func refusesWhileHeld() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        let me = ProcessInfo.processInfo.processIdentifier
        try Data("\(me)\n".utf8).write(to: src.guiLockFile)
        #expect(throws: DevHomeSeeder.Failure.sourceInUse(pid: me)) {
            try DevHomeSeeder.seed(from: src, to: dst, identity: .dev,
                                   sourceKeychain: .init(serviceSuffix: ""), destKeychain: .init(serviceSuffix: ".dev"))
        }
        #expect(!FileManager.default.fileExists(atPath: dst.root.path))
    }

    @Test("refuses while the lock file names no readable pid")
    func refusesWhenLockUnreadable() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        try Data("not-a-pid".utf8).write(to: src.guiLockFile)
        #expect(throws: DevHomeSeeder.Failure.sourceLockUnreadable(src.guiLockFile.path)) {
            try DevHomeSeeder.seed(from: src, to: dst, identity: .dev,
                                   sourceKeychain: .init(serviceSuffix: ""), destKeychain: .init(serviceSuffix: ".dev"))
        }
        #expect(!FileManager.default.fileExists(atPath: dst.root.path))
    }

    @Test("a dead-pid lock file is not copied into the new home")
    func lockFileNotCopied() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        // A pid far past any real process, so GUILock reads this as free, not held.
        try Data("999999\n".utf8).write(to: src.guiLockFile)
        _ = try DevHomeSeeder.seed(from: src, to: dst, identity: .dev,
                                   sourceKeychain: .init(serviceSuffix: ""), destKeychain: .init(serviceSuffix: ".dev"))
        #expect(!FileManager.default.fileExists(atPath: dst.guiLockFile.path))
    }

    @Test("rewrites ~/.iris references inside rules/ too, not just memory/")
    func rewritesRules() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        let ruleFile = src.rulesDir.appendingPathComponent("notes.md")
        try "see ~/.iris/rules for more".write(to: ruleFile, atomically: true, encoding: .utf8)
        _ = try DevHomeSeeder.seed(from: src, to: dst, identity: .dev,
                                   sourceKeychain: .init(serviceSuffix: ""), destKeychain: .init(serviceSuffix: ".dev"))
        let rewritten = try String(contentsOf: dst.rulesDir.appendingPathComponent("notes.md"), encoding: .utf8)
        #expect(rewritten == "see \(dst.displayRoot)/rules for more")
    }

    @Test("rewrites ~/.iris references inside config/*.json")
    func rewritesConfigJSON() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        try "{\"allow\": \"~/.iris/workspaces/x\"}".write(to: src.permissionsJSON, atomically: true, encoding: .utf8)
        _ = try DevHomeSeeder.seed(from: src, to: dst, identity: .dev,
                                   sourceKeychain: .init(serviceSuffix: ""), destKeychain: .init(serviceSuffix: ".dev"))
        let rewritten = try String(contentsOf: dst.permissionsJSON, encoding: .utf8)
        #expect(rewritten == "{\"allow\": \"\(dst.displayRoot)/workspaces/x\"}")
    }

    @Test("a symlink pointing inside the source tree is re-pointed at the new home")
    func repointsInTreeSymlink() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        let link = src.rulesDir.appendingPathComponent("link-to-memory")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: src.memoryDir)
        _ = try DevHomeSeeder.seed(from: src, to: dst, identity: .dev,
                                   sourceKeychain: .init(serviceSuffix: ""), destKeychain: .init(serviceSuffix: ".dev"))
        let destLink = dst.rulesDir.appendingPathComponent("link-to-memory")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destLink.path) == dst.memoryDir.path)
    }

    @Test("sourceMissing when the release home does not exist; maps to exit code 3")
    func sourceMissing() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("seed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = IrisPaths(root: base.appendingPathComponent("no-release-here"))
        let dst = IrisPaths(root: base.appendingPathComponent("dev"))
        #expect(throws: DevHomeSeeder.Failure.sourceMissing(src.root.path)) {
            try DevHomeSeeder.seed(from: src, to: dst, identity: .dev,
                                   sourceKeychain: .init(serviceSuffix: ""), destKeychain: .init(serviceSuffix: ".dev"))
        }
        #expect(DevHomeSeeder.exitCode(for: .failure(DevHomeSeeder.Failure.sourceMissing(src.root.path))) == 3)
    }

    @Test("exitCode maps success to 0 and every other failure to 1")
    func exitCodeMapping() {
        #expect(DevHomeSeeder.exitCode(for: .success(.init())) == 0)
        #expect(DevHomeSeeder.exitCode(for: .failure(DevHomeSeeder.Failure.releaseBuild)) == 1)
        #expect(DevHomeSeeder.exitCode(for: .failure(DevHomeSeeder.Failure.destinationNotEmpty("/x"))) == 1)
        #expect(DevHomeSeeder.exitCode(for: .failure(DevHomeSeeder.Failure.sourceInUse(pid: 1))) == 1)
    }

    @Test("a failure partway through leaves dest.root absent and no staging directory behind")
    func atomicFailureCleansUp() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        // Owner read permission denied: `copyItem` fails partway through the tree copy, after
        // the staging directory has already been created and partly populated.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: src.conversationsDB.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: src.conversationsDB.path) }

        #expect(throws: (any Error).self) {
            _ = try DevHomeSeeder.seed(from: src, to: dst, identity: .dev,
                                       sourceKeychain: .init(serviceSuffix: ""), destKeychain: .init(serviceSuffix: ".dev"))
        }
        #expect(!FileManager.default.fileExists(atPath: dst.root.path))
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: dst.root.deletingLastPathComponent().path)) ?? []
        #expect(!siblings.contains { $0.hasPrefix(dst.root.lastPathComponent) })
    }
}
