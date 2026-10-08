import Foundation
import Testing
@testable import iris

@Suite("Release defaults import")
struct ReleaseDefaultsImportTests {
    private func suite() -> (UserDefaults, () -> Void) {
        let name = "iris-import-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (store, {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    @Test("copies dev keys once, never over a release value, never the conversation blob")
    func importsOnce() {
        let (dest, cleanup) = suite(); defer { cleanup() }
        dest.set("release-choice", forKey: "PROVIDER")
        let source: [String: Any] = ["PROVIDER": "dev-choice", "HAS_COMPLETED_SETUP": true,
                                     "KeyboardShortcuts_toggleIris": "{}", "iris_conversations": Data()]
        #expect(ReleaseDefaultsImport.importOnce(from: source, into: dest))
        #expect(dest.string(forKey: "PROVIDER") == "release-choice")
        #expect(dest.bool(forKey: "HAS_COMPLETED_SETUP"))
        #expect(dest.string(forKey: "KeyboardShortcuts_toggleIris") == "{}")
        #expect(dest.object(forKey: "iris_conversations") == nil)
        #expect(dest.bool(forKey: ReleaseDefaultsImport.markerKey))

        #expect(!ReleaseDefaultsImport.importOnce(from: ["LATE": 1], into: dest))
        #expect(dest.object(forKey: "LATE") == nil)
    }

    @Test("no source domain still sets the marker")
    func emptySource() {
        let (dest, cleanup) = suite(); defer { cleanup() }
        #expect(ReleaseDefaultsImport.importOnce(from: nil, into: dest))
        #expect(dest.bool(forKey: ReleaseDefaultsImport.markerKey))
    }
}
