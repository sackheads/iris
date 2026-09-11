import Foundation
import Security

public final class KeychainManager: @unchecked Sendable {
    public static let shared = KeychainManager()

    private let legacyService = "com.iris.secrets"
    private let account = "all-keys"

    public static let mcpFileService = "iris.mcp"
    public static func pluginService(_ id: String) -> String { "iris.plugin.\(id)" }

    /// Under `swift test` the manager uses an in-memory store instead of the real login
    /// Keychain. The SwiftPM test binary is ad-hoc/linker-signed and gets a fresh code
    /// signature (cdhash) on every rebuild, so the Keychain's "Always Allow" ACL grant never
    /// persists — macOS re-prompts for the login password on every SecItem call, which blocks
    /// headless test runs. XCTest is only linked into the test bundle, never the shipping app,
    /// so its presence is a reliable "running under tests" signal. `HeadlessMode` extends the
    /// same in-memory behavior to the `--bench` CLI, which is an identically ad-hoc-signed
    /// `swift run` binary that would otherwise block on a Keychain prompt.
    let usesInMemoryStore = NSClassFromString("XCTestCase") != nil || HeadlessMode.isEnabled
    private var inMemorySecrets: [String: [String: String]] = [:]
    private let inMemoryLock = NSLock()

    private init() {}

    // MARK: - Legacy API (service = com.iris.secrets), unchanged behavior
    public func loadSecrets() -> [String: String] { secrets(service: legacyService) }
    public func saveSecrets(_ secrets: [String: String]) { saveSecrets(secrets, service: legacyService) }

    // MARK: - Service-scoped API
    public func secrets(service: String) -> [String: String] {
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

    public func saveSecrets(_ secrets: [String: String], service: String) {
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

    public func deleteSecrets(service: String) {
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
}
