import Foundation

public struct SkillBundle: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let skillNames: [String]

    public init(name: String, description: String, skillNames: [String]) {
        self.name = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = description
        self.skillNames = skillNames.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

public final class SkillBundleManager: Sendable {
    public static let shared = SkillBundleManager()

    private let lock = NSLock()
    // Guarded by `lock`; the manual synchronization is what makes the class Sendable-safe,
    // so the mutable storage is opted out of Swift 6's Sendable checking explicitly.
    nonisolated(unsafe) private var _activeBundle: SkillBundle? = nil

    public var activeBundle: SkillBundle? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _activeBundle
        }
        set {
            lock.lock()
            _activeBundle = newValue
            lock.unlock()
        }
    }

    private init() {}

    private func bundleFile(paths: IrisPaths) -> URL {
        paths.memoryDir.appendingPathComponent("bundles.json")
    }

    public func listBundles() -> [SkillBundle] {
        listBundles(paths: .default)
    }

    func listBundles(paths: IrisPaths) -> [SkillBundle] {
        let url = bundleFile(paths: paths)
        guard let data = try? Data(contentsOf: url),
              let bundles = try? JSONDecoder().decode([SkillBundle].self, from: data) else {
            return []
        }
        return bundles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func saveBundle(_ bundle: SkillBundle) throws {
        try saveBundle(bundle, paths: .default)
    }

    func saveBundle(_ bundle: SkillBundle, paths: IrisPaths) throws {
        var current = listBundles(paths: paths)
        current.removeAll { $0.name == bundle.name }
        current.append(bundle)

        let url = bundleFile(paths: paths)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.memoryDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(current)
        try data.write(to: url, options: .atomic)
    }

    public func deleteBundle(name: String) throws {
        try deleteBundle(name: name, paths: .default)
    }

    func deleteBundle(name: String, paths: IrisPaths) throws {
        let cleanName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var current = listBundles(paths: paths)
        current.removeAll { $0.name == cleanName }

        let url = bundleFile(paths: paths)
        let data = try JSONEncoder().encode(current)
        try data.write(to: url, options: .atomic)
    }

    public func getBundle(name: String) -> SkillBundle? {
        getBundle(name: name, paths: .default)
    }

    func getBundle(name: String, paths: IrisPaths) -> SkillBundle? {
        let cleanName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return listBundles(paths: paths).first { $0.name == cleanName }
    }
}
