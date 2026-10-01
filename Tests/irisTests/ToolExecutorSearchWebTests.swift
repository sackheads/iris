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

    @Test("sslCertEnvironment sets SSL_CERT_FILE when the trust store exists and it's unset")
    func sslCertFileAdded() throws {
        let cert = FileManager.default.temporaryDirectory
            .appendingPathComponent("cert-\(UUID().uuidString).pem")
        try Data("test".utf8).write(to: cert)
        defer { try? FileManager.default.removeItem(at: cert) }
        let env = ToolExecutor.sslCertEnvironment(base: ["PATH": "/tmp"], certFile: cert.path)
        #expect(env["SSL_CERT_FILE"] == cert.path)
        #expect(env["PATH"] == "/tmp")
    }

    @Test("sslCertEnvironment leaves an existing SSL_CERT_FILE alone")
    func sslCertFileRespected() throws {
        let cert = FileManager.default.temporaryDirectory
            .appendingPathComponent("cert-\(UUID().uuidString).pem")
        try Data("test".utf8).write(to: cert)
        defer { try? FileManager.default.removeItem(at: cert) }
        let env = ToolExecutor.sslCertEnvironment(base: ["SSL_CERT_FILE": "/custom/cert.pem"], certFile: cert.path)
        #expect(env["SSL_CERT_FILE"] == "/custom/cert.pem")
    }

    @Test("sslCertEnvironment adds nothing when the trust store is absent")
    func sslCertFileAbsent() {
        let env = ToolExecutor.sslCertEnvironment(base: ["PATH": "/tmp"], certFile: "/nonexistent/cert.pem")
        #expect(env["SSL_CERT_FILE"] == nil)
        #expect(env["PATH"] == "/tmp")
    }

    @Test("isTLSTrustMissing matches the OpenSSL verify-failed code, nothing else")
    func tlsTrustMissingDetected() {
        #expect(ToolExecutor.isTLSTrustMissing(#"{"error": "<urlopen error [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed>"}"#))
        #expect(!ToolExecutor.isTLSTrustMissing(#"{"error": "timed out"}"#))
        #expect(!ToolExecutor.isTLSTrustMissing(#"[]"#))
    }
}
