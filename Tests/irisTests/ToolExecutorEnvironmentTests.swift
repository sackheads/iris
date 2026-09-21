import Testing
import Foundation
@testable import iris

@Suite("ToolExecutor.commandEnvironment")
struct ToolExecutorEnvironmentTests {
    @Test("login PATH entries are prepended ahead of the base PATH")
    func prependsLoginPath() {
        let base = ["PATH": "/usr/bin:/bin"]
        let env = ToolExecutor.commandEnvironment(base: base, loginPath: ["/opt/homebrew/bin", "/usr/local/bin"])
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    }

    @Test("duplicate entries are removed, keeping the first occurrence")
    func dedupesKeepingFirst() {
        let base = ["PATH": "/usr/local/bin:/usr/bin:/bin"]
        let env = ToolExecutor.commandEnvironment(base: base, loginPath: ["/opt/homebrew/bin", "/usr/local/bin"])
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    }

    @Test("empty login PATH leaves base unchanged")
    func emptyLoginPathIsNoOp() {
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/test"]
        let env = ToolExecutor.commandEnvironment(base: base, loginPath: [])
        #expect(env == base)
    }

    @Test("a base without PATH gains one from the login path")
    func baseWithoutPathGainsOne() {
        let base = ["HOME": "/Users/test"]
        let env = ToolExecutor.commandEnvironment(base: base, loginPath: ["/opt/homebrew/bin", "/usr/bin"])
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(env["HOME"] == "/Users/test")
    }

    @Test("other environment keys are preserved")
    func preservesOtherKeys() {
        let base = ["PATH": "/usr/bin", "HOME": "/Users/test", "LANG": "en_US.UTF-8"]
        let env = ToolExecutor.commandEnvironment(base: base, loginPath: ["/opt/homebrew/bin"])
        #expect(env["HOME"] == "/Users/test")
        #expect(env["LANG"] == "en_US.UTF-8")
    }
}
