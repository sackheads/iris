import Foundation
import Security

public final class KeychainManager: @unchecked Sendable {
    public static let shared = KeychainManager(serviceSuffix: BuildIdentity.current.keychainServiceSuffix)

    static let legacyService = "com.iris.secrets"
    private let account = "all-keys"

    public static let mcpFileService = "iris.mcp"
    public static func pluginService(_ id: String) -> String { "iris.plugin.\(id)" }

    /// Under `swift test` the manager uses an in-memory store instead of the real login
    /// Keychain. The SwiftPM test binary is ad-hoc/linker-signed and gets a fresh code
    /// signature (cdhash) on every rebuild, so the Keychain's "Always Allow" ACL grant never
    /// persists — macOS re-prompts for the login password on every SecItem call, which blocks
    /// headless test runs. XCTest is only linked into the test bundle, never the shipping app,
    /// so its presence is a reliable "running under tests" signal. `HeadlessMode` extends the
    /// same in-memory behavior to the `--bench` CLI and `--perf run`'s fake lane, both identically
    /// ad-hoc-signed `swift run` binaries that would otherwise block on a Keychain prompt.
    let usesInMemoryStore: Bool

    /// Set by `--perf` for a real-lane run whose provider needs no Keychain secret (Gemini over
    /// ADC gets its token from gcloud). The Keychain ACL is per binary identity, so every rebuilt
    /// ad-hoc-signed binary re-prompts on its first secret read; an unattended run sat 50 minutes
    /// on that dialog. Must be set before `KeychainManager.shared` is first touched.
    private static let bypassLock = NSLock()
    nonisolated(unsafe) private static var bypassFlag = false
    static var headlessBypassRequested: Bool { bypassLock.withLock { bypassFlag } }
    static func requestHeadlessBypass() { bypassLock.withLock { bypassFlag = true } }
    private var inMemorySecrets: [String: [String: String]] = [:]
    private let inMemoryLock = NSLock()

    /// Appended to every base service name passed to the methods below, so callers never
    /// build the suffixed name themselves (Task 3 of the dev/release separation plan).
    private let serviceSuffix: String

    /// `inMemory` forces the in-memory store: a test's own manager, never the process's (#678).
    init(serviceSuffix: String, inMemory: Bool = false) {
        self.serviceSuffix = serviceSuffix
        self.usesInMemoryStore = inMemory || NSClassFromString("XCTestCase") != nil || HeadlessMode.isEnabled
            || KeychainManager.headlessBypassRequested
    }

    /// Set when the secrets item could not be read (a denied prompt, a damaged item): from then
    /// on this manager never writes it, because a write after a failed read would replace what
    /// is there with only what this process knows (#678).
    private let blockLock = NSLock()
    private var writesBlocked = false
    /// Test-only, in-memory managers: make every throwing read fail, as a denied prompt does.
    private var simulatedReadFailure: OSStatus?
    func simulateReadFailure(_ status: OSStatus?) { blockLock.withLock { simulatedReadFailure = status } }
    func blockWrites() { blockLock.withLock { writesBlocked = true } }
    var areWritesBlocked: Bool { blockLock.withLock { writesBlocked } }

    /// The service name actually used for Keychain/in-memory storage for a given base name.
    func resolvedService(_ base: String) -> String { base + serviceSuffix }

    // MARK: - Legacy API (service = com.iris.secrets), unchanged behavior
    public func loadSecrets() -> [String: String] { secrets(service: Self.legacyService) }
    /// Replaces the whole item: for a copy of a whole item or a test's fixture, never for a change
    /// to some keys, which is `updateSecrets` (#750).
    public func replaceSecrets(_ secrets: [String: String]) { replaceSecrets(secrets, service: Self.legacyService) }

    // MARK: - Service-scoped API
    public func secrets(service: String) -> [String: String] {
        let service = resolvedService(service)
        if usesInMemoryStore {
            return inMemoryLock.withLock { inMemorySecrets[service] ?? [:] }
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        guard status == errSecSuccess, let data = dataTypeRef as? Data else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    public func replaceSecrets(_ secrets: [String: String], service: String) {
        Self.updateLock.withLock { storeSecrets(secrets, service: service) }
    }

    /// One lock for every load, change and save of a secrets item in this process (#750). Each
    /// writer saves the whole dictionary, so two unlocked writes close together lose one's keys: an
    /// API key, a guarded setting, a fingerprint. Another process can't write the same item (#463).
    private static let updateLock = NSLock()

    /// Loads `service`'s secrets, lets `mutate` change them and saves them, all under one lock, and
    /// saves only if something changed. A read that fails (a locked Mac, a denied prompt) saves
    /// nothing, rather than an item holding only `mutate`'s keys (#761 review); it's printed, as a
    /// failed save is. `mutate` must not touch a Keychain itself: the lock isn't reentrant.
    func updateSecrets(service: String = KeychainManager.legacyService, _ mutate: (inout [String: String]) -> Void) {
        do {
            try updateSecretsOrThrow(service: service, mutate)
        } catch {
            print("Not saving secrets for \(service): the item couldn't be read (\(error)), so it is left as it is (#750).")
        }
    }

    /// `updateSecrets`, but a read or save that fails throws, and nothing is saved over a read that
    /// failed; `mutate` throwing saves nothing. A Keychain prompt during the read is answered with
    /// the lock held, so other writers wait for it; a reader that needs no lock never does.
    func updateSecretsOrThrow(service: String = KeychainManager.legacyService,
                              _ mutate: (inout [String: String]) throws -> Void) throws {
        try Self.updateLock.withLock {
            let before = try secretsOrThrow(service: service)
            var after = before
            try mutate(&after)
            if after != before { try storeSecretsOrThrow(after, service: service) }
        }
    }

    private func storeSecrets(_ secrets: [String: String], service: String) {
        if service == Self.legacyService, areWritesBlocked {
            print("Not saving secrets: the secrets item could not be read at launch, so it is left as it is (#678).")
            return
        }
        let service = resolvedService(service)
        if usesInMemoryStore {
            inMemoryLock.withLock { inMemorySecrets[service] = secrets }
            return
        }
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newQuery = query
            newQuery[kSecValueData as String] = data
            SecItemAdd(newQuery as CFDictionary, nil)
        } else if status != errSecSuccess {
            print("Failed to save secrets to keychain service \(service): \(status)")
        }
    }

    // MARK: - Throwing API (callers that must not lose a secret silently)

    /// A Keychain call that failed for a reason other than "nothing stored there". The seeder
    /// uses this to distinguish a locked Keychain, a denied ACL or a bad status from an item
    /// that was simply never created, which `secrets(service:)`'s empty dictionary cannot.
    enum SecretsError: Error, Equatable { case status(OSStatus) }

    /// What a raw Keychain `OSStatus` means to a caller that cares. A pure function of the
    /// status code, kept separate from any live `SecItem*` call so it is unit-testable without
    /// touching the real Keychain — `usesInMemoryStore` never produces a non-success status to
    /// test against, and the ad-hoc/linker-signed test binary re-prompts for the login password
    /// on every real Keychain call (see `usesInMemoryStore`'s doc above).
    enum StatusOutcome: Equatable { case success, notFound, failure(OSStatus) }

    static func outcome(for status: OSStatus) -> StatusOutcome {
        switch status {
        case errSecSuccess: return .success
        case errSecItemNotFound: return .notFound
        default: return .failure(status)
        }
    }

    /// `secrets(service:)`, but any Keychain failure other than "not found" throws instead of
    /// coming back as the same empty dictionary an absent item would.
    func secretsOrThrow(service: String) throws -> [String: String] {
        let service = resolvedService(service)
        if usesInMemoryStore, let status = blockLock.withLock({ simulatedReadFailure }) {
            throw SecretsError.status(status)
        }
        if usesInMemoryStore {
            return inMemoryLock.withLock { inMemorySecrets[service] ?? [:] }
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        switch Self.outcome(for: status) {
        case .notFound: return [:]
        case .failure(let bad): throw SecretsError.status(bad)
        case .success:
            // An item that won't decode is unreadable, not empty: read as empty, the next update
            // would replace it with only its own keys (#761 review), and #678 treats it as missing.
            guard let data = dataTypeRef as? Data,
                  let secrets = try? JSONDecoder().decode([String: String].self, from: data) else {
                throw SecretsError.status(errSecDecode)
            }
            return secrets
        }
    }

    /// `replaceSecrets(_:service:)`, but a non-success status throws instead of only printing.
    func replaceSecretsOrThrow(_ secrets: [String: String], service: String) throws {
        try Self.updateLock.withLock { try storeSecretsOrThrow(secrets, service: service) }
    }

    private func storeSecretsOrThrow(_ secrets: [String: String], service: String) throws {
        if service == Self.legacyService, areWritesBlocked { throw SecretsError.status(errSecWrPerm) }
        let service = resolvedService(service)
        if usesInMemoryStore {
            inMemoryLock.withLock { inMemorySecrets[service] = secrets }
            return
        }
        guard let data = try? JSONEncoder().encode(secrets) else { throw SecretsError.status(errSecParam) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newQuery = query
            newQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(newQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecretsError.status(addStatus) }
        } else if status != errSecSuccess {
            throw SecretsError.status(status)
        }
    }

    public func deleteSecrets(service: String) {
        let service = resolvedService(service)
        if usesInMemoryStore {
            inMemoryLock.withLock { inMemorySecrets[service] = nil }
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Base names of the stored services starting with `prefix`, for this manager's suffix only.
    /// Reads attributes, never data, so it does not trip the Keychain's access prompt. Any listing
    /// failure reads as no services; `storedServicesOrThrow` is for callers that must tell them apart.
    func storedServices(withPrefix prefix: String) -> [String] {
        (try? storedServicesOrThrow(withPrefix: prefix)) ?? []
    }

    /// `storedServices(withPrefix:)`, but a listing that failed (a locked Keychain, a denied
    /// query) throws instead of reading as "nothing stored" — the seeder would otherwise skip
    /// every plugin's secrets and report success.
    func storedServicesOrThrow(withPrefix prefix: String) throws -> [String] {
        let names: [String]
        if usesInMemoryStore {
            names = inMemoryLock.withLock { Array(inMemorySecrets.keys) }
        } else {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            names = try Self.listedServiceNames(status: status, result: result)
        }
        return names.compactMap { name in
            guard name.hasPrefix(prefix) else { return nil }
            if serviceSuffix.isEmpty { return name.hasSuffix(".dev") ? nil : name }
            guard name.hasSuffix(serviceSuffix) else { return nil }
            return String(name.dropLast(serviceSuffix.count))
        }
    }

    /// The service names a `kSecMatchLimitAll` attribute listing returned. Pure, so the status
    /// handling is testable without a live Keychain (see `outcome(for:)`).
    static func listedServiceNames(status: OSStatus, result: AnyObject?) throws -> [String] {
        switch outcome(for: status) {
        case .notFound: return []
        case .failure(let bad): throw SecretsError.status(bad)
        case .success:
            guard let items = result as? [[String: Any]] else { return [] }
            return items.compactMap { $0[kSecAttrService as String] as? String }
        }
    }
}
