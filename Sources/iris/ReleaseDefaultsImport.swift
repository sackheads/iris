import Foundation

/// The first launch of the installed app would otherwise start from empty defaults and rerun
/// setup, because every setting so far was written by the bare dev binary into the `iris` domain.
/// Copies that domain into the release domain once. One way only, and never over a value release
/// already has.
enum ReleaseDefaultsImport {
    static let markerKey = "IRIS_IMPORTED_DEV_DEFAULTS"
    static let devDomain = "iris"

    /// Returns true when it imported (or found nothing to import) and set the marker.
    @discardableResult
    static func importOnce(from source: [String: Any]?, into dest: UserDefaults) -> Bool {
        guard !dest.bool(forKey: markerKey) else { return false }
        for (key, value) in IrisDefaults.perfSeed(from: source ?? [:]) where dest.object(forKey: key) == nil {
            dest.set(value, forKey: key)
        }
        dest.set(true, forKey: markerKey)
        return true
    }

    /// Release identity only, before anything reads `ConfigManager.shared`.
    static func runIfNeeded() {
        guard BuildIdentity.current == .release else { return }
        importOnce(from: UserDefaults.standard.persistentDomain(forName: devDomain), into: IrisDefaults.store)
    }
}
