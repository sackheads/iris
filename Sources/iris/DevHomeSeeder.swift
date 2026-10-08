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

        var description: String {
            switch self {
            case .releaseBuild: "refusing: this is the installed release build; only dev builds seed"
            case .destinationNotEmpty(let p): "refusing: \(p) already has content; remove it first to reseed"
            case .sourceMissing(let p): "nothing to seed from: \(p) does not exist"
            case .sourceInUse(let pid): "refusing: Iris (pid \(pid)) has the source store open; quit it and retry"
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
        if case .held(let pid) = GUILock.state(at: source.guiLockFile) { throw Failure.sourceInUse(pid: pid) }

        try fm.createDirectory(at: dest.root, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.root.path) {
            let from = source.root.appendingPathComponent(name)
            let to = dest.root.appendingPathComponent(name)
            if name == source.modelsDir.lastPathComponent {
                try fm.createSymbolicLink(at: to, withDestinationURL: from)
            } else if from.path != source.guiLockFile.path {
                try fm.copyItem(at: from, to: to)
            }
        }
        try rewriteHomeReferences(in: [dest.memoryDir, dest.rulesDir], to: dest)

        var report = Report()
        let services = [KeychainManager.legacyService, KeychainManager.mcpFileService]
            + sourceKeychain.storedServices(withPrefix: "iris.plugin.")
        for service in services {
            let secrets = sourceKeychain.secrets(service: service)
            guard !secrets.isEmpty else { continue }
            destKeychain.saveSecrets(secrets, service: service)
            report.keychainServicesCopied += 1
        }
        return report
    }

    /// Copied memory still says `~/.iris`; the dev agent should read its own home there.
    private static func rewriteHomeReferences(in dirs: [URL], to dest: IrisPaths) throws {
        let fm = FileManager.default
        for dir in dirs {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "md" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let rewritten = dest.agentFacing(text)
                if rewritten != text { try rewritten.write(to: url, atomically: true, encoding: .utf8) }
            }
        }
    }

    static func runCLI() -> Int32 {
        do {
            let report = try seed(from: .release, to: .standard, identity: .current,
                                  sourceKeychain: KeychainManager(serviceSuffix: BuildIdentity.release.keychainServiceSuffix),
                                  destKeychain: .shared)
            print("seeded \(IrisPaths.standard.displayRoot) from ~/.iris (\(report.keychainServicesCopied) Keychain services)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("iris --seed-dev-home: \(error)\n".utf8))
            return 1
        }
    }
}
