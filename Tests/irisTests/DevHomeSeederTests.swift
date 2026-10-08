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
}
