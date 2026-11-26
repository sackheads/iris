import CryptoKit
import Foundation

/// #1370 (#1295 (b') step 2): the guard's SAFE verdicts on library/ and artifacts/ reads, and since #1398 on reads under
/// an external library root in Settings (`LibraryGuardStore`), kept across launches, so each version of a note
/// `GuardTrustStore` doesn't vouch for (a `run_command` write, a tainted turn's write, an
/// outside edit) pays tiers 2 and 3 once, not on every launch's first read (16-20 s on gemma for 12 KB).
///
/// Only a whole pass that tier 3 actually judged is kept: a block, a tier error, a tier-2 partial and a skipped
/// canary are judged again next time. A sampling canary (Ollama, cloud) has to say SAFE on two reads of the same
/// version before it is kept, so one lucky roll isn't served for 30 days (Brian, #1390); a block or error between
/// them drops the first. llama.cpp's canary is greedy, so its one pass is kept. What is kept is the verdict, never text: a hit runs tier 1 again and wraps
/// the result like any judged read. The key is `InjectionGuard.cacheKey` (the content and the guard settings) plus
/// `GuardVersion`, what that key doesn't cover: the canary prompts, the strip's rules, the build and the tier-3
/// model's identity. No version (an Ollama that doesn't answer) keeps and serves nothing.
///
/// It lives in `config/` beside `GuardTrustStore`'s list, with the same protection and no MAC (Brian, #1369: "no
/// HMAC, protected file"). A missing or garbled file serves nothing, so the read is judged: it fails closed.
final class GuardVerdictStore: @unchecked Sendable {
    static let shared = GuardVerdictStore(file: IrisPaths.default.configDir.appendingPathComponent("guard-verdicts.json"))
    static let ttl: TimeInterval = 30 * 86_400
    /// Sized for an external vault (#1398), not only the 48 notes of library/ and artifacts/.
    static let defaultCapacity = 10_000
    let capacity: Int

    /// When a verdict was reached, and when it was last served (the LRU order). Wall time: the TTL is calendar days.
    struct Entry: Codable, Equatable {
        var judged: Date
        var used: Date
        /// Tier 2 skipped (no model), so the judged text was capped for tier 3; a hit caps it the same way.
        var tier2Skipped: Bool
        /// False for a sampling canary's first SAFE, which is never served: it waits for a second one.
        var confirmed: Bool

        init(judged: Date, used: Date, tier2Skipped: Bool, confirmed: Bool) {
            self.judged = judged; self.used = used; self.tier2Skipped = tier2Skipped; self.confirmed = confirmed
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            judged = try c.decode(Date.self, forKey: .judged)
            used = try c.decode(Date.self, forKey: .used)
            tier2Skipped = try c.decode(Bool.self, forKey: .tier2Skipped)
            confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        }
    }

    private let file: URL
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    /// The version for a read judged under that canary prompt kind (#1356: the clause joins only the instruction-channel one's).
    let version: @Sendable (InjectionGuard.GuardConfigFingerprint, InjectionGuard.CanaryPromptKind) async -> String?
    let runsToKeep: @Sendable (InjectionGuard.GuardConfigFingerprint) -> Int

    init(file: URL, now: @escaping @Sendable () -> Date = { Date() },
         version: @escaping @Sendable (InjectionGuard.GuardConfigFingerprint, InjectionGuard.CanaryPromptKind) async -> String? = {
             await GuardVersion.current($0, kind: $1)
         },
         runsToKeep: @escaping @Sendable (InjectionGuard.GuardConfigFingerprint) -> Int = GuardVerdictStore.runsToKeep,
         capacity: Int = GuardVerdictStore.defaultCapacity) {
        self.file = file
        self.capacity = capacity
        self.now = now
        self.version = version
        self.runsToKeep = runsToKeep
    }

    /// How many agreeing SAFE judgements keep a verdict: one for llama.cpp's greedy decode, two for anything that
    /// samples (Ollama and cloud send no temperature). MLX has no version, so it keeps nothing either way.
    static func runsToKeep(_ fingerprint: InjectionGuard.GuardConfigFingerprint) -> Int {
        fingerprint.promptGuardEngine == AuxiliaryEngineType.llamaCPP.rawValue ? 1 : 2
    }

    static func key(_ cacheKey: String, version: String) -> String {
        SHA256.hash(data: Data("\(cacheKey)\u{0}\(version)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The kept SAFE verdict for `key`, if one is confirmed and younger than the TTL; marks it used.
    func safeVerdict(_ key: String) -> Entry? {
        lock.withLock {
            var entries = load()
            guard var entry = entries[key], entry.confirmed else { return nil }
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

    /// One SAFE judgement of `key`. With `runs` 2, the first is held unconfirmed and the second confirms it; the
    /// TTL still counts from the first.
    func recordSafe(_ key: String, tier2Skipped: Bool, runs: Int = 1) {
        lock.withLock {
            let at = now()
            var entries = load().filter { at.timeIntervalSince($0.value.judged) < Self.ttl }
            if runs <= 1 {
                entries[key] = Entry(judged: at, used: at, tier2Skipped: tier2Skipped, confirmed: true)
            } else if let first = entries[key] {
                entries[key] = Entry(judged: first.judged, used: at, tier2Skipped: tier2Skipped, confirmed: true)
            } else {
                entries[key] = Entry(judged: at, used: at, tier2Skipped: tier2Skipped, confirmed: false)
            }
            if entries.count > capacity {
                for stale in entries.sorted(by: { $0.value.used < $1.value.used }).prefix(entries.count - capacity) {
                    entries.removeValue(forKey: stale.key)
                }
            }
            save(entries)
        }
    }

    /// A block or error on `key`: an unconfirmed first SAFE doesn't survive it.
    func forget(_ key: String) {
        lock.withLock {
            var entries = load()
            guard entries.removeValue(forKey: key) != nil else { return }
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

    static func current(_ fingerprint: InjectionGuard.GuardConfigFingerprint,
                        kind: InjectionGuard.CanaryPromptKind = .external) async -> String? {
        make(prompts: promptSource(kind), rules: PromptInjectionGuard.ruleSource, build: build,
             model: await modelIdentity(fingerprint))
    }

    /// The canary prompts a kept read's verdict depends on, with fixed stand-ins for the tag and the text. A library
    /// or artifacts read is tool output, judged under `.external`: its source is both prompts as they were before
    /// #1356, byte for byte, so the clause kept every such verdict. A read judged under the instruction-channel
    /// prompt hashes that prompt as rendered, clause and its place included (dev-2's #1414 review), and the
    /// escalation that reaches its verdict (#1356 e).
    static func promptSource(_ kind: InjectionGuard.CanaryPromptKind) -> String {
        let external = InjectionGuard.canaryPrompt(tag: "TAG", text: "TEXT", kind: .external)
        let channel = InjectionGuard.canaryPrompt(tag: "TAG", text: "TEXT", kind: .instructionChannel,
                                                  impersonationClause: kind == .instructionChannel)
        let parts = kind == .instructionChannel ? [external, channel, InjectionGuard.messageVerdictStages] : [external, channel]
        return parts.joined(separator: "\u{0}")
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
