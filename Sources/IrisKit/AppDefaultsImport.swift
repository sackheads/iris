import Foundation

/// The first launch of any bundled app (the installed release app, or Xcode's Debug build) would
/// otherwise start from empty defaults and rerun setup, because every setting so far was written
/// by the bare dev binary into the `iris` domain. Copies that domain into the bundled app's own
/// domain once. One way only, and never over a value the app already has.
enum AppDefaultsImport {
    static let markerKey = "IRIS_IMPORTED_DEV_DEFAULTS"
    static let devDomain = "iris"

    /// Returns true when it imported (or found nothing to import) and set the marker.
    @discardableResult
    static func importOnce(from source: [String: Any]?, into dest: UserDefaults) -> Bool {
        guard !dest.bool(forKey: markerKey) else { return false }
        // Not `perfSeed`: that also applies `IRIS_PERF_SEED_JSON`, a perf-only override that
        // must never reach a bundled app's launch path.
        for (key, value) in IrisDefaults.stripConversationBlob(from: source ?? [:]) where dest.object(forKey: key) == nil {
            dest.set(value, forKey: key)
        }
        dest.set(true, forKey: markerKey)
        return true
    }

    /// True for any bundled app reading its own domain — the installed release app
    /// (`com.bnaylor.iris`) and the Xcode Debug app (`com.bnaylor.iris.dev`) — never the bare dev
    /// binary itself (whose domain this imports *from*), and never under tests, which read and
    /// write a volatile per-process suite regardless of `appDomain` (`IrisDefaults.processStore`'s
    /// own `XCTestCase` check).
    static func shouldImport(appDomain: String, underTests: Bool) -> Bool {
        !underTests && appDomain != devDomain
    }

    /// Before anything reads a setting: a bundled app's first launch inherits the dev binary's
    /// settings.
    static func runIfNeeded() {
        guard shouldImport(appDomain: IrisDefaults.appDomain, underTests: NSClassFromString("XCTestCase") != nil) else { return }
        importOnce(from: UserDefaults.standard.persistentDomain(forName: devDomain), into: IrisDefaults.store)
    }
}
