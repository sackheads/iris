import Foundation
import CryptoKit
import os

/// LiteLLM's public price map, fetched by the app at most daily and cached beside Iris's config
/// (#239 3b). The cache is under `config/`, a protected write directory, so a model's `write_file`
/// can't plant prices; an approved shell command still could, so the cache's sha256 is kept in
/// the guarded secrets item, written only after a fetch, and a cache that doesn't match it is
/// ignored (#705 review, planner): the snapshot applies until the next fetch. A headless run reads
/// the cache or the bundled snapshot and never fetches.
struct ModelPriceFeed: Sendable {
    static let url = URL(string: ModelPriceSnapshot.source)!
    static let maxBytes = 10 * 1_024 * 1_024
    static let timeoutSeconds = 30.0
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    static let families: Set<String> = ["anthropic", "gemini", "openai", "deepseek"]

    struct Cached: Codable, Equatable, Sendable {
        var asOf: String
        var fetchedAt: Date
        var rows: [String: [String: TokenRates]]
    }

    enum FetchError: Error, Equatable { case notHTTPS, status(Int), tooLarge, unparseable, cannotFingerprint }

    /// Where the cache's fingerprint is kept. Nil (#678's legacy mode, a test's own config) trusts
    /// no cache at all.
    static let fingerprintKey = "MODEL_PRICES_SHA256"
    private static let loggedUntrusted = OSAllocatedUnfairLock(initialState: false)

    var paths: IrisPaths
    var keychain: KeychainManager?
    /// The download, injectable for tests: the URL's bytes, at most `maxBytes`.
    var download: @Sendable (URL) async throws -> Data = ModelPriceFeed.boundedDownload

    var cacheURL: URL { paths.configDir.appendingPathComponent("model-prices.json") }

    /// The cache, only when its bytes match the fingerprint the last fetch stored. A missing,
    /// changed or unverifiable cache is nil, said once per process.
    func cached() -> Cached? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        guard let keychain, let secrets = try? keychain.secretsOrThrow(service: KeychainManager.legacyService),
              let stored = secrets[Self.fingerprintKey], stored == Self.fingerprint(data) else {
            if Self.loggedUntrusted.withLock({ let first = !$0; $0 = true; return first }) {
                print("Model price cache ignored: it doesn't match the fingerprint Iris stored when it fetched it, so the bundled snapshot applies until the next fetch (#705).")
            }
            return nil
        }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }

    static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Whether to fetch: the cache is older than a day, missing, or not trusted. Wall time on
    /// purpose: it's a schedule.
    func isStale(now: Date = Date()) -> Bool {
        guard let c = cached() else { return true }
        return now.timeIntervalSince(c.fetchedAt) >= Self.refreshInterval
    }

    /// Fetches, parses and caches. Only the app fetches (#679's rule); anything else gets nil.
    @discardableResult
    func refresh(now: Date = Date(), role: ProcessRole? = ProcessRole.current) async throws -> Cached? {
        guard role == .app else { return nil }
        let data = try await withTimeout(seconds: Self.timeoutSeconds) { [download] in try await download(Self.url) }
        guard let rows = Self.parse(data), !rows.isEmpty else { throw FetchError.unparseable }
        // The local date: the GUI check showed the next day's (UTC) date on an evening fetch.
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]; formatter.timeZone = .current
        let cached = Cached(asOf: formatter.string(from: now), fetchedAt: now, rows: rows)
        guard let keychain, !keychain.areWritesBlocked else { throw FetchError.cannotFingerprint }
        try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
        // The bytes written are the ones fingerprinted, never a second encode (#625).
        let bytes = try JSONEncoder().encode(cached)
        try bytes.write(to: cacheURL, options: .atomic)
        // Only after the file is in place, so a fingerprint never vouches for a file that isn't.
        var secrets = try keychain.secretsOrThrow(service: KeychainManager.legacyService)
        secrets[Self.fingerprintKey] = Self.fingerprint(bytes)
        try keychain.saveSecretsOrThrow(secrets, service: KeychainManager.legacyService)
        return cached
    }

    /// The families Iris prices, each row matched on its own `litellm_provider`, as the generator does.
    static func parse(_ data: Data) -> [String: [String: TokenRates]]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var rows: [String: [String: TokenRates]] = [:]
        for (key, value) in object {
            guard let v = value as? [String: Any], let family = v["litellm_provider"] as? String, families.contains(family) else { continue }
            if let mode = v["mode"] as? String, mode != "chat", mode != "responses" { continue }
            guard let input = (v["input_cost_per_token"] as? NSNumber)?.doubleValue, input > 0,
                  let output = (v["output_cost_per_token"] as? NSNumber)?.doubleValue, output > 0 else { continue }
            let model = key.hasPrefix(family + "/") ? String(key.dropFirst(family.count + 1)) : key
            guard !model.contains("/"), !model.contains("|") else { continue }
            let read = (v["cache_read_input_token_cost"] as? NSNumber)?.doubleValue ?? input
            let write = (v["cache_creation_input_token_cost"] as? NSNumber).map(\.doubleValue).flatMap { $0 > 0 ? $0 : nil }
            rows[family, default: [:]][model] = TokenRates(input: input, output: output, cacheRead: read, cacheWrite: write)
        }
        return rows
    }

    /// https only, no redirect followed, at most `maxBytes` read.
    static func boundedDownload(_ url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw FetchError.notHTTPS }
        let (bytes, response) = try await NoRedirectSessionDelegate.session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.status((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        if http.expectedContentLength > Int64(maxBytes) { throw FetchError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw FetchError.tooLarge }
        }
        return data
    }
}
