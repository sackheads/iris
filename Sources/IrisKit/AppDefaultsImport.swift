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

    /// `persistentDomain(forName:)` is cfprefsd's view, and cfprefsd refuses to serve a domain
    /// over roughly 4 MB — on one machine `iris.plist` sat at 4.8 MB (the legacy
    /// `iris_conversations` blob), so `persistentDomain(forName: "iris")` returned nil from every
    /// *other* process (`defaults read iris` agreed: "Domain iris does not exist"), even though
    /// the file itself was readable. Fall back to reading the plist straight off disk when
    /// cfprefsd has nothing. `stripConversationBlob` still runs on whichever source wins, so the
    /// oversized blob itself is never the thing that gets imported either way.
    static func loadSourceDomain(persistentDomain: [String: Any]?, plistDirectory: URL) -> [String: Any]? {
        if let persistentDomain { return persistentDomain }
        let url = plistDirectory.appendingPathComponent("\(devDomain).plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else { return nil }
        return dict
    }

    /// Before anything reads a setting: a bundled app's first launch inherits the dev binary's
    /// settings.
    static func runIfNeeded() {
        guard shouldImport(appDomain: IrisDefaults.appDomain, underTests: NSClassFromString("XCTestCase") != nil) else { return }
        let source = loadSourceDomain(persistentDomain: UserDefaults.standard.persistentDomain(forName: devDomain),
                                       plistDirectory: IrisDefaults.preferencesDirectory)
        let store = IrisDefaults.store
        guard importOnce(from: source, into: store) else { return }
        // synchronize() forces the write cfprefsd would otherwise coalesce; false means it was
        // refused, which would otherwise surface only as settings silently missing next launch.
        if !store.synchronize() {
            FileHandle.standardError.write(Data("iris: settings import could not be saved (cfprefsd refused the write)\n".utf8))
        }
    }
}
