import Foundation
import GRDB
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
        _ = try ConversationStore.onDisk(at: src.conversationsDB)   // a real, migrated store
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

    private func seedDefault(_ src: IrisPaths, _ dst: IrisPaths) throws {
        _ = try DevHomeSeeder.seed(from: src, to: dst, identity: .dev,
                                   sourceKeychain: .init(serviceSuffix: ""), destKeychain: .init(serviceSuffix: ".dev"))
    }

    @Test("workspace paths under the release home are re-pointed at the dev home; others are not")
    func rewritesWorkspacePaths() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        let inside = UUID(), root = UUID(), outside = UUID(), sibling = UUID()
        do {
            let store = try ConversationStore.onDisk(at: src.conversationsDB)
            _ = try store.importLegacy([
                Conversation(id: inside, title: "a", workspacePath: src.workspacesDir.path + "/ship"),
                Conversation(id: root, title: "b", workspacePath: src.root.path),
                Conversation(id: outside, title: "c", workspacePath: "/tmp/elsewhere"),
                Conversation(id: sibling, title: "d", workspacePath: src.root.path + "-other/x"),
            ])
        }
        // JSONEncoder escapes `/`, so a path inside a JSON column is spelled `\/Users\/...`.
        let escaped = src.root.path.replacingOccurrences(of: "/", with: "\\/")
        let contract = "{\"workspace\":\"\(escaped)\\/workspaces\\/ship\",\"other\":\"\(escaped)-other\"}"
        do {
            let queue = try DatabaseQueue(path: src.conversationsDB.path)
            try queue.write { db in
                try db.execute(sql: "UPDATE conversations SET goalContract = ? WHERE id = ?",
                               arguments: [contract, inside.uuidString])
            }
        }

        try seedDefault(src, dst)

        let queue = try DatabaseQueue(path: dst.conversationsDB.path)
        func workspace(_ id: UUID) throws -> String? {
            try queue.read { try String.fetchOne($0, sql: "SELECT workspacePath FROM conversations WHERE id = ?",
                                                arguments: [id.uuidString]) }
        }
        #expect(try workspace(inside) == dst.workspacesDir.path + "/ship")
        #expect(try workspace(root) == dst.root.path)
        #expect(try workspace(outside) == "/tmp/elsewhere")
        #expect(try workspace(sibling) == src.root.path + "-other/x")
        let destEscaped = dst.root.path.replacingOccurrences(of: "/", with: "\\/")
        let rewritten = try queue.read { try String.fetchOne($0, sql: "SELECT goalContract FROM conversations WHERE id = ?",
                                                             arguments: [inside.uuidString]) }
        #expect(rewritten == "{\"workspace\":\"\(destEscaped)\\/workspaces\\/ship\",\"other\":\"\(escaped)-other\"}")
    }

    @Test("every copied job is paused in the dev home, so it never fires in both apps")
    func pausesCopiedJobs() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        let running = Job(name: "nightly", prompt: "p", trigger: .schedule(.interval(seconds: 60)), nextFireAt: Date())
        var paused = Job(name: "old", prompt: "p", trigger: .schedule(.interval(seconds: 60)), nextFireAt: nil)
        paused.pausedReason = "failed 3 times"
        do {
            let store = try ConversationStore.onDisk(at: src.conversationsDB)
            try store.ledger.upsert(running)
            try store.ledger.upsert(paused)
        }

        try seedDefault(src, dst)

        let copied = try ConversationStore.onDisk(at: dst.conversationsDB).ledger.jobs()
        #expect(copied.count == 2)
        #expect(copied.allSatisfy { $0.pausedReason == DevHomeSeeder.copiedJobPausedReason })
        #expect(DevHomeSeeder.copiedJobPausedReason == "copied into the dev home; unpause to run it here")
        // The release store keeps firing them.
        let original = try ConversationStore.onDisk(at: src.conversationsDB).ledger.jobs()
        #expect(original.first { $0.name == "nightly" }?.pausedReason == nil)
    }

    @Test("a copied pending approval is pre-expired, so a stale \"Approve and run\" click cannot fire it in the dev copy")
    func expiresCopiedPendingApprovals() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        let job = Job(name: "watcher", prompt: "p", trigger: .schedule(.interval(seconds: 60)), nextFireAt: Date())
        let pendingId = UUID(), alreadyApprovedId = UUID()
        do {
            let store = try ConversationStore.onDisk(at: src.conversationsDB)
            try store.ledger.upsert(job)
            let pending = JobRun(id: pendingId, jobId: job.id, jobName: job.name, triggerKind: "schedule",
                                 startedAt: Date(), status: .blockedOnApproval)
            try store.ledger.begin(run: pending)
            try store.ledger.setBlockedCall(runId: pendingId,
                BlockedCall(toolName: "run_command", args: ["command": .string("echo hi")]))
            // A run already approved and dispatched before the copy — its approvedAt must survive
            // unchanged, not be bumped to the seed time.
            let approved = JobRun(id: alreadyApprovedId, jobId: job.id, jobName: job.name, triggerKind: "schedule",
                                  startedAt: Date(), status: .completed)
            try store.ledger.begin(run: approved)
            try store.ledger.setBlockedCall(runId: alreadyApprovedId,
                BlockedCall(toolName: "run_command", args: ["command": .string("echo done")]))
            _ = try store.ledger.markApproved(runId: alreadyApprovedId, at: Date(timeIntervalSince1970: 1_000))
        }

        try seedDefault(src, dst)

        let destLedger = try ConversationStore.onDisk(at: dst.conversationsDB).ledger
        let copiedPending = try #require(try destLedger.run(id: pendingId))
        #expect(copiedPending.blockedCall != nil, "the call's details stay on the row for the card to show")
        #expect(copiedPending.approvedAt != nil, "but it is pre-expired so a stale click cannot re-dispatch it")
        #expect(try destLedger.markApproved(runId: pendingId, at: Date()) == false,
                "the one-shot claim must already read as spent")

        let copiedApproved = try #require(try destLedger.run(id: alreadyApprovedId))
        #expect(copiedApproved.approvedAt == Date(timeIntervalSince1970: 1_000),
                "a run approved before the copy keeps its real approval time")

        // The release store's own row is untouched.
        let srcRun = try #require(try ConversationStore.onDisk(at: src.conversationsDB).ledger.run(id: pendingId))
        #expect(srcRun.approvedAt == nil)
    }

    @Test("a staged store that cannot be opened names itself as the release store, with its path, and still fails closed")
    func unreadableStagedStoreNamesItself() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        try Data("not a sqlite file".utf8).write(to: src.conversationsDB)
        do {
            _ = try DevHomeSeeder.seed(from: src, to: dst, identity: .dev,
                                       sourceKeychain: .init(serviceSuffix: ""), destKeychain: .init(serviceSuffix: ".dev"))
            Issue.record("expected seeding to fail on an unreadable store")
        } catch DevHomeSeeder.Failure.storeUnreadable(let path) {
            #expect(path.contains("conversations.sqlite"))
            #expect("\(DevHomeSeeder.Failure.storeUnreadable(path))".contains("release store"))
        } catch {
            Issue.record("expected .storeUnreadable, got \(error)")
        }
        // Same atomicity as every other failure: nothing half-seeded is left behind.
        #expect(!FileManager.default.fileExists(atPath: dst.root.path))
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: dst.root.deletingLastPathComponent().path)) ?? []
        #expect(!siblings.contains { $0.hasPrefix(dst.root.lastPathComponent) })
    }

    @Test("a seeded home carries the marker; nothing else does")
    func writesMarker() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        #expect(!FileManager.default.fileExists(atPath: dst.seedMarker.path))
        try seedDefault(src, dst)
        #expect(dst.seedMarker.lastPathComponent == ".seeded-from-release")
        #expect(FileManager.default.fileExists(atPath: dst.seedMarker.path))
        #expect(!FileManager.default.fileExists(atPath: src.seedMarker.path))
    }

    @Test("perf warns when the dev home it copies was never seeded from the release home")
    func unseededPerfWarning() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        try dst.ensureDirectories()   // what a dev launch before run-dev.sh leaves
        let warning = try #require(DevHomeSeeder.unseededCopyWarning(standard: dst, release: src))
        #expect(warning.contains("not seeded"))
        #expect(warning.contains("baselines"))
        // The installed app copies its own home: nothing to warn about.
        #expect(DevHomeSeeder.unseededCopyWarning(standard: src, release: src) == nil)
        // No release home: the dev home is all there is.
        let gone = IrisPaths(root: src.root.appendingPathExtension("missing"))
        #expect(DevHomeSeeder.unseededCopyWarning(standard: dst, release: gone) == nil)
        try Data().write(to: dst.seedMarker)
        #expect(DevHomeSeeder.unseededCopyWarning(standard: dst, release: src) == nil)
    }
}
