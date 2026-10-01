import Foundation

class MemoryManager: @unchecked Sendable {
    static let shared = MemoryManager()

    /// Fixed at init: `.default` for `shared`, the caller's own root via `init(paths:)`.
    let paths: IrisPaths

    private var memoryPath: String { paths.memoryMd.path }
    private var userProfilePath: String { paths.userMd.path }

    private init() {
        paths = .default
        ensureDefaults()
    }

    /// Test/injection seam (5a Task 7 fix round 1): a manager over its OWN `IrisPaths`, so a test
    /// never mutates the process-global `MemoryManager.shared.paths` (invariant 7) to get
    /// isolation. `IrisEngine(memory:)` takes one of these the same way it takes `factStore:`.
    init(paths: IrisPaths) {
        self.paths = paths
        ensureDefaults()
    }

    private func ensureDefaults() {
        try? paths.ensureDirectories()
        if !FileManager.default.fileExists(atPath: memoryPath) {
            try? "Memory is currently empty.".write(toFile: memoryPath, atomically: true, encoding: .utf8)
        }
        if !FileManager.default.fileExists(atPath: userProfilePath) {
            try? "User profile is currently empty.".write(toFile: userProfilePath, atomically: true, encoding: .utf8)
        }
    }

    func getMemory() -> String {
        if let content = try? String(contentsOfFile: memoryPath, encoding: .utf8) {
            return content
        }
        return "Memory is currently empty."
    }
    
    func updateMemory(content: String) {
        try? content.write(toFile: memoryPath, atomically: true, encoding: .utf8)
    }

    func getSoul() -> String {
        (try? String(contentsOf: paths.soulMd, encoding: .utf8)) ?? ""
    }

    func updateSoul(content: String) {
        try? paths.ensureDirectories()
        try? content.write(to: paths.soulMd, atomically: true, encoding: .utf8)
    }

    func getUserProfile() -> String {
        if let content = try? String(contentsOfFile: userProfilePath, encoding: .utf8) {
            return content
        }
        return "User profile is currently empty."
    }
    
    func updateUserProfile(content: String) {
        try? content.write(toFile: userProfilePath, atomically: true, encoding: .utf8)
    }
}
