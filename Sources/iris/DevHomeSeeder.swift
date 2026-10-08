import Foundation

/// `iris --seed-dev-home`: gives a dev build a copy of the installed app's home and secrets, once,
/// so moving dev to `~/.iris-dev` does not mean re-entering every key. Secrets are copied
/// in-process: the dev binary is the identity that created them, while `/usr/bin/security` would
/// prompt per item and an "Always Allow" there would open them to every script.
enum DevHomeSeeder {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case releaseBuild
        case destinationNotEmpty(String)
        case sourceMissing(String)
        case sourceInUse(pid: Int32)
        case sourceLockUnreadable(String)

        var description: String {
            switch self {
            case .releaseBuild: "refusing: this is the installed release build; only dev builds seed"
            case .destinationNotEmpty(let p): "refusing: \(p) already has content; remove it first to reseed"
            case .sourceMissing(let p): "nothing to seed from: \(p) does not exist"
            case .sourceInUse(let pid): "refusing: Iris (pid \(pid)) has the source store open; quit it and retry"
            case .sourceLockUnreadable(let p): "refusing: \(p) does not hold a readable pid; delete it and retry"
            }
        }
    }

    struct Report: Equatable { var keychainServicesCopied = 0 }

    static func seed(from source: IrisPaths, to dest: IrisPaths, identity: BuildIdentity,
                     sourceKeychain: KeychainManager, destKeychain: KeychainManager) throws -> Report {
        guard identity == .dev else { throw Failure.releaseBuild }
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.root.path) else { throw Failure.sourceMissing(source.root.path) }
        if let contents = try? fm.contentsOfDirectory(atPath: dest.root.path), !contents.isEmpty {
            throw Failure.destinationNotEmpty(dest.root.path)
        }
        // `.unreadable` is held, not free (GUILock's own doc): a lock file that names no pid is
        // still something refusing can recover from, while seeding past it cannot tell whether
        // an app has the store open.
        switch GUILock.state(at: source.guiLockFile) {
        case .held(let pid): throw Failure.sourceInUse(pid: pid)
        case .unreadable(let path): throw Failure.sourceLockUnreadable(path)
        case .free: break
        }

        // Built in a sibling staging directory, same volume as `dest.root`, and renamed into
        // place only once every step below — copy, rewrite, Keychain — has succeeded. A failure
        // partway (an unreadable source file, a Keychain error) must never leave a half-seeded
        // `dest.root` for the dev app to open; `moveItem` on the same volume is the atomic step.
        let stagingRoot = dest.root.deletingLastPathComponent()
            .appendingPathComponent(dest.root.lastPathComponent + ".seeding-\(UUID().uuidString)")
        let staging = IrisPaths(root: stagingRoot)
        do {
            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            try copyTree(from: source, into: staging, finalDest: dest)
            try rewriteHomeReferences(in: [staging.memoryDir, staging.rulesDir, staging.configDir], to: dest)

            var report = Report()
            let services = [KeychainManager.legacyService, KeychainManager.mcpFileService]
                + sourceKeychain.storedServices(withPrefix: "iris.plugin.")
            for service in services {
                let secrets = try sourceKeychain.secretsOrThrow(service: service)
                guard !secrets.isEmpty else { continue }
                try destKeychain.saveSecretsOrThrow(secrets, service: service)
                report.keychainServicesCopied += 1
            }

            // `dest.root` may already exist as the empty directory `destinationNotEmpty` just
            // accepted; `moveItem` refuses onto an existing path, so clear it first.
            if fm.fileExists(atPath: dest.root.path) { try fm.removeItem(at: dest.root) }
            try fm.moveItem(at: stagingRoot, to: dest.root)
            return report
        } catch {
            try? fm.removeItem(at: stagingRoot)
            throw error
        }
    }

    /// Copies `source.root`'s entries into `staging.root`, except `models/` (symlinked to the
    /// original, gigabytes, read-only) and the source's own GUI lock file (meaningless, and
    /// possibly live, at the new home).
    private static func copyTree(from source: IrisPaths, into staging: IrisPaths, finalDest: IrisPaths) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: source.root.path) {
            let from = source.root.appendingPathComponent(name)
            let to = staging.root.appendingPathComponent(name)
            if name == source.modelsDir.lastPathComponent {
                try fm.createSymbolicLink(at: to, withDestinationURL: from)
            } else if from.path != source.guiLockFile.path {
                try copyEntry(from: from, to: to, sourceRoot: source.root, destRoot: finalDest.root)
            }
        }
    }

    /// Recursive copy that re-points a symlink whose target resolves inside `sourceRoot` at the
    /// analogous location under `destRoot` — otherwise it would keep pointing back at the
    /// release tree once this entry lands in the dev home. `destRoot` is the FINAL destination,
    /// not the staging directory this is physically written into: the text is correct only once
    /// `moveItem` lands the tree at `destRoot`, which is exactly where it ends up. A symlink
    /// whose target resolves outside `sourceRoot` is copied with its original target unchanged.
    private static func copyEntry(from: URL, to: URL, sourceRoot: URL, destRoot: URL) throws {
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: from.path)
        if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            let target = try fm.destinationOfSymbolicLink(atPath: from.path)
            let resolved = URL(fileURLWithPath: target, relativeTo: from.deletingLastPathComponent()).standardizedFileURL
            let sourceRootPath = sourceRoot.standardizedFileURL.path
            if resolved.path == sourceRootPath || resolved.path.hasPrefix(sourceRootPath + "/") {
                let suffix = resolved.path.dropFirst(sourceRootPath.count)   // "" or "/memory/..."
                try fm.createSymbolicLink(atPath: to.path, withDestinationPath: destRoot.path + suffix)
            } else {
                try fm.createSymbolicLink(atPath: to.path, withDestinationPath: target)
            }
            return
        }
        if attrs[.type] as? FileAttributeType == .typeDirectory {
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: from.path) {
                try copyEntry(from: from.appendingPathComponent(name), to: to.appendingPathComponent(name),
                             sourceRoot: sourceRoot, destRoot: destRoot)
            }
            return
        }
        try fm.copyItem(at: from, to: to)
    }

    /// Copied memory, rules and config text still says `~/.iris`; the dev agent should read its
    /// own home there. `config/*.json` carries the same bundled-text problem as the `.md` files —
    /// `permissions.json`'s allowlist entries are paths spelled against the old home.
    private static func rewriteHomeReferences(in dirs: [URL], to dest: IrisPaths) throws {
        let fm = FileManager.default
        let extensions: Set<String> = ["md", "json"]
        for dir in dirs {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where extensions.contains(url.pathExtension) {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let rewritten = dest.agentFacing(text)
                if rewritten != text { try rewritten.write(to: url, atomically: true, encoding: .utf8) }
            }
        }
    }

    /// Maps a finished seed attempt to the exit code `run-dev.sh` branches on: 0 seeded, 3
    /// nothing to seed (no release home yet — expected on a fresh machine, not a failure), 1
    /// anything else. Pure function of the `Result`, so the mapping is unit-testable without a
    /// real seed attempt.
    static func exitCode(for result: Result<Report, Error>) -> Int32 {
        switch result {
        case .success: return 0
        case .failure(let error):
            if case Failure.sourceMissing = error { return 3 }
            return 1
        }
    }

    static func runCLI() -> Int32 {
        let result: Result<Report, Error>
        do {
            let report = try seed(from: .release, to: .standard, identity: .current,
                                  sourceKeychain: KeychainManager(serviceSuffix: BuildIdentity.release.keychainServiceSuffix),
                                  destKeychain: .shared)
            result = .success(report)
        } catch {
            result = .failure(error)
        }
        switch result {
        case .success(let report):
            print("seeded \(IrisPaths.standard.displayRoot) from ~/.iris (\(report.keychainServicesCopied) Keychain services)")
        case .failure(let error):
            if case Failure.sourceMissing = error {
                print("iris --seed-dev-home: \(error)")
            } else {
                FileHandle.standardError.write(Data("iris --seed-dev-home: \(error)\n".utf8))
            }
        }
        return exitCode(for: result)
    }
}
