import Foundation
import Security

public final class KeychainManager: @unchecked Sendable {
    public static let shared = KeychainManager()

    private let service = "com.iris.secrets"
    private let account = "all-keys"

    /// Under `swift test` the manager uses an in-memory store instead of the real login
    /// Keychain. The SwiftPM test binary is ad-hoc/linker-signed and gets a fresh code
    /// signature (cdhash) on every rebuild, so the Keychain's "Always Allow" ACL grant never
    /// persists — macOS re-prompts for the login password on every SecItem call, which blocks
    /// headless test runs. XCTest is only linked into the test bundle, never the shipping app,
    /// so its presence is a reliable "running under tests" signal. `HeadlessMode` extends the
    /// same in-memory behavior to the `--bench` CLI, which is an identically ad-hoc-signed
    /// `swift run` binary that would otherwise block on a Keychain prompt.
    let usesInMemoryStore = NSClassFromString("XCTestCase") != nil || HeadlessMode.isEnabled
    private var inMemorySecrets: [String: String] = [:]
    private let inMemoryLock = NSLock()

    private init() {}

    public func loadSecrets() -> [String: String] {
        if usesInMemoryStore {
            return inMemoryLock.withLock { inMemorySecrets }
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

        guard status == errSecSuccess, let data = dataTypeRef as? Data else {
            return [:]
        }

        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            print("Failed to decode keychain secrets: \(error)")
            return [:]
        }
    }

    public func saveSecrets(_ secrets: [String: String]) {
        if usesInMemoryStore {
            inMemoryLock.withLock { inMemorySecrets = secrets }
            return
        }

        guard let data = try? JSONEncoder().encode(secrets) else {
            print("Failed to encode secrets")
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var newQuery = query
            newQuery[kSecValueData as String] = data
            SecItemAdd(newQuery as CFDictionary, nil)
        } else if status != errSecSuccess {
            print("Failed to save secrets to keychain: \(status)")
        }
    }
}
