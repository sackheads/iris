import Testing
import Foundation
@testable import iris

@Suite("BinaryResolver.commandEnvironment")
struct BinaryResolverEnvironmentTests {
    @Test("login dirs are prepended ahead of the base PATH")
    func prependsLoginDirs() {
        let base = ["PATH": "/tmp/unique-a:/tmp/unique-b"]
        let env = BinaryResolver.commandEnvironment(base: base)
        let login = BinaryResolver.defaultSearchDirs()
        let resultPath = env["PATH"]!.components(separatedBy: ":")
        #expect(Array(resultPath.prefix(login.count)) == login)
        #expect(Array(resultPath.dropFirst(login.count)) == ["/tmp/unique-a", "/tmp/unique-b"])
    }

    @Test("duplicate entries are removed, keeping the first occurrence")
    func dedupesKeepingFirst() {
        let firstLogin = BinaryResolver.defaultSearchDirs().first!
        // A login dir planted in the base must be deduped away from the tail.
        let base = ["PATH": "/tmp/unique-a:\(firstLogin)"]
        let env = BinaryResolver.commandEnvironment(base: base)
        let resultPath = env["PATH"]!.components(separatedBy: ":")
        #expect(resultPath.filter { $0 == firstLogin }.count == 1)
        #expect(resultPath.last == "/tmp/unique-a")
    }

    @Test("a base without PATH gains one from the login dirs")
    func baseWithoutPathGainsOne() {
        let base = ["HOME": "/Users/test"]
        let env = BinaryResolver.commandEnvironment(base: base)
        let login = BinaryResolver.defaultSearchDirs()
        #expect(env["PATH"] == login.joined(separator: ":"))
        #expect(env["HOME"] == "/Users/test")
    }

    @Test("other environment keys are preserved")
    func preservesOtherKeys() {
        let base = ["PATH": "/tmp/unique-a", "HOME": "/Users/test", "LANG": "en_US.UTF-8"]
        let env = BinaryResolver.commandEnvironment(base: base)
        #expect(env["HOME"] == "/Users/test")
        #expect(env["LANG"] == "en_US.UTF-8")
    }
}
