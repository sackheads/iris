import Testing
import Foundation
@testable import iris

@Suite("Binary Resolver Tests")
struct BinaryResolverTests {
    @Test("absolute path that exists resolves to itself")
    func absolute() {
        #expect(BinaryResolver.resolve(command: "/bin/ls", searchDirs: []) == "/bin/ls")
    }

    @Test("bare name resolves via search dirs")
    func bareName() {
        #expect(BinaryResolver.resolve(command: "ls", searchDirs: ["/nonexistent", "/bin"]) == "/bin/ls")
    }


    @Test("missing binary returns nil")
    func missing() {
        #expect(BinaryResolver.resolve(command: "definitely-not-a-real-binary-xyz", searchDirs: ["/bin"]) == nil)
    }


    /// #242: this used to set the process working directory to "/" for the duration of the test.
    /// Suites run in parallel, so every other test that resolved a path from the working
    /// directory — the whole perf suite, via `PerfPaths.repoRoot()` — could see "/" instead and
    /// fail on a fixture that was there all along. `relativeTo` makes the base explicit.
    @Test("relative command with slash resolves against the given base")
    func relativeCommand() {
        #expect(BinaryResolver.resolve(command: "bin/ls", searchDirs: [], relativeTo: "/") == "/bin/ls")
    }

    /// The default base is the working directory, which is what a shell does — worth pinning, since
    /// the point of #242's fix was to make that explicit rather than to change it.
    @Test("an absolute command ignores the base")
    func absoluteIgnoresBase() {
        #expect(BinaryResolver.resolve(command: "/bin/ls", searchDirs: [], relativeTo: "/tmp") == "/bin/ls")
    }

    @Test("default search dirs include the common install locations")
    func defaults() {
        let dirs = BinaryResolver.defaultSearchDirs()
        #expect(dirs.contains("/opt/homebrew/bin"))
        #expect(dirs.contains("/usr/local/bin"))
        #expect(dirs.contains(("~/.local/bin" as NSString).expandingTildeInPath))
    }
}
