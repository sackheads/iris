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


    @Test("relative command with slash resolves to an absolute path")
    func relativeCommand() {
        let cwd = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath("/")
        defer { FileManager.default.changeCurrentDirectoryPath(cwd) }
        let resolved = BinaryResolver.resolve(command: "bin/ls", searchDirs: [])
        #expect(resolved == "/bin/ls")
    }

    @Test("default search dirs include the common install locations")
    func defaults() {
        let dirs = BinaryResolver.defaultSearchDirs()
        #expect(dirs.contains("/opt/homebrew/bin"))
        #expect(dirs.contains("/usr/local/bin"))
        #expect(dirs.contains(("~/.local/bin" as NSString).expandingTildeInPath))
    }
}
