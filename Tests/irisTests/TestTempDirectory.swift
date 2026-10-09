import Testing
import Foundation
@testable import IrisKit

/// A fresh `<prefix>-<UUID>` directory under the OS temp dir, already created. Fixtures across
/// the suite used to build this inline and never remove it, which left thousands of `iris-*`
/// entries in `$TMPDIR` behind a full run (#309). Callers still own cleanup: `defer { try?
/// FileManager.default.removeItem(at: dir) }` right after the call, same as the existing pattern
/// in `SkillFolderTraversalTests` and `PermissionCarveOutTests`. This only factors out creation.
func tempDirectory(prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Same directory as `tempDirectory(prefix:)`, scoped: `body` runs with it and it is removed
/// right after, pass or throw, so a fixture that fits in one expression can't forget the
/// `defer`. Fixtures that need the directory to outlive one expression (built up across several
/// statements, or held across an `async` gap awkward to nest) keep the `tempDirectory` +
/// `defer` pattern instead.
func withTempDirectory<T>(prefix: String, _ body: (URL) async throws -> T) async throws -> T {
    let dir = try tempDirectory(prefix: prefix)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
}
