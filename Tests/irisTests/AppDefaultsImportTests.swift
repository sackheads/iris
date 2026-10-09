import Foundation
import Testing
@testable import IrisKit

@Suite("App defaults import")
struct AppDefaultsImportTests {
    private func suite() -> (UserDefaults, () -> Void) {
        let name = "iris-import-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (store, {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    @Test("copies dev keys once, never over an existing value, never the conversation blob")
    func importsOnce() {
        let (dest, cleanup) = suite(); defer { cleanup() }
        dest.set("app-choice", forKey: "PROVIDER")
        let source: [String: Any] = ["PROVIDER": "dev-choice", "HAS_COMPLETED_SETUP": true,
                                     "KeyboardShortcuts_toggleIris": "{}", "iris_conversations": Data()]
        #expect(AppDefaultsImport.importOnce(from: source, into: dest))
        #expect(dest.string(forKey: "PROVIDER") == "app-choice")
        #expect(dest.bool(forKey: "HAS_COMPLETED_SETUP"))
        #expect(dest.string(forKey: "KeyboardShortcuts_toggleIris") == "{}")
        #expect(dest.object(forKey: "iris_conversations") == nil)
        #expect(dest.bool(forKey: AppDefaultsImport.markerKey))

        #expect(!AppDefaultsImport.importOnce(from: ["LATE": 1], into: dest))
        #expect(dest.object(forKey: "LATE") == nil)
    }

    @Test("no source domain still sets the marker")
    func emptySource() {
        let (dest, cleanup) = suite(); defer { cleanup() }
        #expect(AppDefaultsImport.importOnce(from: nil, into: dest))
        #expect(dest.bool(forKey: AppDefaultsImport.markerKey))
    }

    @Test("gates on any bundled app domain, never the bare binary, never under tests")
    func shouldImportGate() {
        #expect(AppDefaultsImport.shouldImport(appDomain: "com.bnaylor.iris", underTests: false))
        #expect(AppDefaultsImport.shouldImport(appDomain: "com.bnaylor.iris.dev", underTests: false))
        #expect(!AppDefaultsImport.shouldImport(appDomain: "iris", underTests: false))
        #expect(!AppDefaultsImport.shouldImport(appDomain: "com.bnaylor.iris", underTests: true))
        #expect(!AppDefaultsImport.shouldImport(appDomain: "com.bnaylor.iris.dev", underTests: true))
    }

    /// A scratch directory standing in for `~/Library/Preferences`, never the real one.
    private func tempPlistDir() -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-import-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, { try? FileManager.default.removeItem(at: dir) })
    }

    private func writeDevPlist(_ dict: [String: Any], in dir: URL) {
        let data = try! PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        try! data.write(to: dir.appendingPathComponent("iris.plist"))
    }

    @Test("source loader prefers the cfprefsd domain when present, ignoring the plist on disk")
    func loaderPrefersPersistentDomain() {
        let (dir, cleanup) = tempPlistDir(); defer { cleanup() }
        writeDevPlist(["FROM_DISK": true], in: dir)
        let result = AppDefaultsImport.loadSourceDomain(persistentDomain: ["FROM_DOMAIN": true], plistDirectory: dir)
        #expect(result?["FROM_DOMAIN"] as? Bool == true)
        #expect(result?["FROM_DISK"] == nil)
    }

    @Test("source loader falls back to iris.plist on disk when cfprefsd serves no domain (over its size ceiling)")
    func loaderFallsBackToPlist() {
        let (dir, cleanup) = tempPlistDir(); defer { cleanup() }
        writeDevPlist(["HAS_COMPLETED_SETUP": true, "PROVIDER": "anthropic"], in: dir)
        let result = AppDefaultsImport.loadSourceDomain(persistentDomain: nil, plistDirectory: dir)
        #expect(result?["HAS_COMPLETED_SETUP"] as? Bool == true)
        #expect(result?["PROVIDER"] as? String == "anthropic")
    }

    @Test("source loader is nil when the domain is nil and the plist is missing or corrupt")
    func loaderNilWhenBothMissing() {
        let (dir, cleanup) = tempPlistDir(); defer { cleanup() }
        #expect(AppDefaultsImport.loadSourceDomain(persistentDomain: nil, plistDirectory: dir) == nil)

        try! Data("not a plist".utf8).write(to: dir.appendingPathComponent("iris.plist"))
        #expect(AppDefaultsImport.loadSourceDomain(persistentDomain: nil, plistDirectory: dir) == nil)
    }

    @Test("importOnce strips the conversation blob and its backup keys regardless of source")
    func importOnceStripsBlobAndBackups() {
        let (dest, cleanup) = suite(); defer { cleanup() }
        let source: [String: Any] = ["PROVIDER": "anthropic", "iris_conversations": Data(),
                                     "iris_conversations_backup_20261001": Data()]
        #expect(AppDefaultsImport.importOnce(from: source, into: dest))
        #expect(dest.string(forKey: "PROVIDER") == "anthropic")
        #expect(dest.object(forKey: "iris_conversations") == nil)
        #expect(dest.object(forKey: "iris_conversations_backup_20261001") == nil)
    }
}
