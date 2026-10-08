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
}
