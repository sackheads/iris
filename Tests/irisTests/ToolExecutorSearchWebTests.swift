import Testing
import Foundation
@testable import iris

@Suite("ToolExecutor.searchWebProcess")
struct ToolExecutorSearchWebTests {
    @Test("search_web's env python3 process gets the login-shell PATH applied")
    func searchWebLoginPath() {
        // #228: search_web spawns `/usr/bin/env python3` with the bare GUI environment, so a
        // pyenv-managed python3 would exit 127. The spawned environment's PATH must begin with
        // the login dirs. Built via the static process factory to avoid hitting the network.
        let process = ToolExecutor.searchWebProcess(
            scriptPath: "/tmp/x.py", query: "test",
            environment: ["PATH": "/tmp/unique-a"])
        let login = BinaryResolver.defaultSearchDirs()
        let path = process.environment!["PATH"]!.components(separatedBy: ":")
        #expect(Array(path.prefix(login.count)) == login)
        #expect(path.last == "/tmp/unique-a")
    }

    @Test("search_web's env python3 process keeps base PATH entries after the login dirs")
    func searchWebKeepsBasePath() {
        let process = ToolExecutor.searchWebProcess(
            scriptPath: "/tmp/x.py", query: "test",
            environment: ["PATH": "/tmp/only"])
        #expect(process.environment!["PATH"]!.hasSuffix(":/tmp/only"))
    }
}
