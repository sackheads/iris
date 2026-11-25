import CryptoKit
import Foundation

/// #1370 (#1295 (b') step 2): the guard's SAFE verdicts on library/ and artifacts/ reads, kept across launches, so
/// each version of a note `GuardTrustStore` doesn't vouch for (a `run_command` write, a tainted turn's write, an
/// outside edit) pays tiers 2 and 3 once, not on every launch's first read (16-20 s on gemma for 12 KB).
///
/// Only a whole pass that tier 3 actually judged is kept: a block, a tier error, a tier-2 partial and a skipped
/// canary are judged again next time. What is kept is the verdict, never text: a hit runs tier 1 again and wraps
/// the result like any judged read. The key is `InjectionGuard.cacheKey` (the content and the guard settings) plus
/// `GuardVersion`, what that key doesn't cover: the canary prompts, the strip's rules, the build and the tier-3
/// model's identity. No version (an Ollama that doesn't answer) keeps and serves nothing.
///
/// It lives in `config/` beside `GuardTrustStore`'s list, with the same protection and no MAC (Brian, #1369: "no
/// HMAC, protected file"). A missing or garbled file serves nothing, so the read is judged: it fails closed.
final class GuardVerdictStore: @unchecked Sendable {
    static let shared = GuardVerdictStore(file: IrisPaths.default.configDir.appendingPathComponent("guard-verdicts.json"))
    static let ttl: TimeInterval = 30 * 86_400
    static let capacity = 512

    /// When a verdict was reached, and when it was last served (the LRU order). Wall time: the TTL is calendar days.
    struct Entry: Codable, Equatable {
        var judged: Date
        var used: Date
        /// Tier 2 skipped (no model), so the judged text was capped for tier 3; a hit caps it the same way.
        var tier2Skipped: Bool
    }

    private let file: URL
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    let version: @Sendable (InjectionGuard.GuardConfigFingerprint) async -> String?

    init(file: URL, now: @escaping @Sendable () -> Date = { Date() },
         version: @escaping @Sendable (InjectionGuard.GuardConfigFingerprint) async -> String? = { await GuardVersion.current($0) }) {
        self.file = file
        self.now = now
        self.version = version
    }

    static func key(_ cacheKey: String, version: String) -> String {
        SHA256.hash(data: Data("\(cacheKey)\u{0}\(version)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The kept SAFE verdict for `key`, if one is younger than the TTL; marks it used.
    func safeVerdict(_ key: String) -> Entry? {
        lock.withLock {
            var entries = load()
            guard var entry = entries[key] else { return nil }
            let at = now()
            guard at.timeIntervalSince(entry.judged) < Self.ttl else {
                entries.removeValue(forKey: key)
                save(entries)
                return nil
            }
            entry.used = at
            entries[key] = entry
            save(entries)
            return entry
        }
    }

    func recordSafe(_ key: String, tier2Skipped: Bool) {
        lock.withLock {
            let at = now()
            var entries = load().filter { at.timeIntervalSince($0.value.judged) < Self.ttl }
            entries[key] = Entry(judged: at, used: at, tier2Skipped: tier2Skipped)
            if entries.count > Self.capacity {
                for stale in entries.sorted(by: { $0.value.used < $1.value.used }).prefix(entries.count - Self.capacity) {
                    entries.removeValue(forKey: stale.key)
                }
            }
            save(entries)
        }
    }

    /// Anything that doesn't decode is an empty store.
    private func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? Self.decoder.decode([String: Entry].self, from: data)) ?? [:]
    }

    private func save(_ entries: [String: Entry]) {
        guard let data = try? Self.encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()
}

/// #1370: what decides a SAFE verdict besides the content and `GuardConfigFingerprint`. A change to any part misses
/// every kept verdict.
enum GuardVersion {
    /// The parts, hashed in order. Nil `model` (its identity unknown) is no version at all.
    static func make(prompts: String, rules: String, build: String, model: String?) -> String? {
        guard let model else { return nil }
        let joined = [prompts, rules, build, model].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func current(_ fingerprint: InjectionGuard.GuardConfigFingerprint) async -> String? {
        make(prompts: promptSource, rules: PromptInjectionGuard.ruleSource, build: build,
             model: await modelIdentity(fingerprint))
    }

    /// Both canary prompts, with fixed stand-ins for the tag and the text.
    static var promptSource: String {
        [InjectionGuard.CanaryPromptKind.external, .instructionChannel]
            .map { InjectionGuard.canaryPrompt(tag: "TAG", text: "TEXT", kind: $0) }.joined(separator: "\u{0}")
    }

    /// The app's version and build, and the executable's size and date, so an unbumped dev rebuild misses too.
    static var build: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let exe = Bundle.main.executablePath.flatMap { try? FileManager.default.attributesOfItem(atPath: $0) }
        return [info["CFBundleShortVersionString"] as? String ?? "", info["CFBundleVersion"] as? String ?? "",
                "\((exe?[.size] as? NSNumber)?.int64Value ?? -1)",
                "\((exe?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1)"].joined(separator: "|")
    }

    /// Who judges: tier 3's model, then tier 2's, since either can be replaced under the same name (dev-3's #1390
    /// review). Nil when tier 3's identity is unknown.
    static func modelIdentity(_ fingerprint: InjectionGuard.GuardConfigFingerprint,
                              ollamaTags: () async -> Data? = { await OllamaEngine.tagsBody() }) async -> String? {
        guard let tier3 = await tier3Identity(fingerprint, ollamaTags: ollamaTags) else { return nil }
        return tier3 + "\u{0}" + tier2Identity(fingerprint)
    }

    /// Ollama's digest for the model (an `ollama pull` changes the weights under the same name), a cloud tier's
    /// resolved model, or a llama.cpp file's size and date, at the path `tier3Provisioning` checks. Nil when Ollama
    /// doesn't say, and for MLX, which loads a Hugging Face id from the Hub's cache, where nothing here can see a
    /// re-download (dev-3's #1390 review): no version, so no kept verdict.
    static func tier3Identity(_ fingerprint: InjectionGuard.GuardConfigFingerprint,
                              ollamaTags: () async -> Data?) async -> String? {
        switch fingerprint.promptGuardEngine {
        case "ollama":
            guard let body = await ollamaTags() else { return nil }
            return OllamaEngine.digest(of: fingerprint.promptGuardModel, inTags: body).map { "ollama|\($0)" }
        case "cloud":
            return "cloud|\(fingerprint.tier3CloudModel)|\(fingerprint.tier3ThinkingLevel)"
        case "mlx":
            return nil
        default:
            let file = URL(fileURLWithPath: fingerprint.tier3ModelsDir)
                .appendingPathComponent(ModelDownloader.resolvedFilename(for: fingerprint.promptGuardModel))
            return "\(fingerprint.promptGuardEngine)|\(fingerprint.promptGuardModel)|\(contentStamp(file))"
        }
    }

    /// The tier-2 model directory's contents, at the path `tier2Provisioning` checks; none when no model is set.
    static func tier2Identity(_ fingerprint: InjectionGuard.GuardConfigFingerprint) -> String {
        guard !fingerprint.promptGuardCoreMLModel.isEmpty else { return "tier2|none" }
        let dir = URL(fileURLWithPath: fingerprint.tier2ModelsDir)
            .appendingPathComponent(ModelDownloader.resolvedCoreMLDirectoryName(for: fingerprint.promptGuardCoreMLModel))
        return "tier2|\(fingerprint.promptGuardCoreMLModel)|\(contentStamp(dir))"
    }

    /// A file's size and date, or a directory's file count, total size and newest date: a replaced or re-downloaded
    /// model changes it. "missing" for nothing there.
    static func contentStamp(_ url: URL) -> String {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        func stamp(_ u: URL) -> (size: Int, date: Double)? {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return (v.fileSize ?? 0, v.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        if let one = stamp(url) { return "file|\(one.size)|\(one.date)" }
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return "missing" }
        var count = 0, total = 0, newest = 0.0
        for case let file as URL in walk {
            guard let s = stamp(file) else { continue }
            count += 1; total += s.size; newest = max(newest, s.date)
        }
        return count == 0 ? "missing" : "dir|\(count)|\(total)|\(newest)"
    }
}
