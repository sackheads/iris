import Testing
import Foundation
@testable import IrisKit

@Suite("Snippet Wrap-and-Lift Tests")
struct SnippetLiftTests {
    @Test("secret-looking keys", arguments: [
        ("API_KEY", true), ("GITHUB_TOKEN", true), ("CLIENT_SECRET", true),
        ("DB_PASSWORD", true), ("NLM_COOKIES", true), ("DATABASE_URL", false),
        ("PG_POOL_SIZE", false), ("BASE_URL", false)
    ])
    func classification(key: String, secret: Bool) {
        #expect(PluginInstaller.isSecretLooking(key: key) == secret)
    }

    @Test("classifyEnv splits secrets from config")
    func classify() {
        let lifted = PluginInstaller.classifyEnv(["API_KEY": "sk-1", "REGION": "us"])
        #expect(lifted.secrets == ["API_KEY": "sk-1"])
        #expect(lifted.config == ["REGION": "us"])
    }

    @Test("draft from a standard mcpServers snippet")
    func standardSnippet() throws {
        let snippet = """
        { "mcpServers": { "gemini-notebook-mcp": {
            "command": "notebooklm-mcp", "args": [],
            "env": { "API_KEY": "sk-live-1", "REGION": "eu" } } } }
        """
        let draft = try PluginInstaller.draft(fromSnippet: snippet)
        #expect(draft.manifest.id == "gemini-notebook-mcp")
        #expect(draft.secretValues == ["API_KEY": "sk-live-1"])
        #expect(draft.configValues == ["REGION": "eu"])
        #expect(draft.source == "snippet")

        let mcp = String(decoding: draft.files["mcp.json"]!, as: UTF8.self)
        #expect(mcp.contains("${keychain:API_KEY}"))
        #expect(mcp.contains("${config:REGION}"))
        #expect(!mcp.contains("sk-live-1"))

        // Generated manifest must re-parse and declare the lifted fields.
        let manifest = try IPFManifest.parse(
            markdown: String(decoding: draft.files["plugin.md"]!, as: UTF8.self),
            directoryName: "gemini-notebook-mcp")
        #expect(manifest.secrets?.map(\.key) == ["API_KEY"])
        #expect(manifest.config?.map(\.key) == ["REGION"])
        #expect(manifest.requires?.binaries?.first?.name == "notebooklm-mcp")
    }

    @Test("bare snippet without mcpServers wrapper also parses")
    func bareSnippet() throws {
        let draft = try PluginInstaller.draft(fromSnippet: #"{ "sqlite": { "command": "/usr/bin/sqlite-mcp", "args": ["--db", "x"] } }"#)
        #expect(draft.manifest.id == "sqlite")
        #expect(draft.secretValues.isEmpty)
    }

    @Test("regenerate reflects a secret->config re-tag in mcp.json and the manifest")
    func regenerateAfterRetag() throws {
        let snippet = """
        { "mcpServers": { "svc": {
            "command": "svc-mcp", "args": [],
            "env": { "API_KEY": "sk-1", "REGION": "eu" } } } }
        """
        var draft = try PluginInstaller.draft(fromSnippet: snippet)
        #expect(draft.secretValues.keys.contains("API_KEY"))

        // Simulate the wizard's re-tag: API_KEY moves secret -> config.
        draft.configValues["API_KEY"] = draft.secretValues.removeValue(forKey: "API_KEY")

        let rebuilt = try PluginInstaller.regenerate(draft)
        let mcp = String(decoding: rebuilt.files["mcp.json"]!, as: UTF8.self)
        #expect(mcp.contains("${config:API_KEY}"))
        #expect(!mcp.contains("${keychain:API_KEY}"))
        #expect(!mcp.contains("sk-1"))

        let manifest = try IPFManifest.parse(
            markdown: String(decoding: rebuilt.files["plugin.md"]!, as: UTF8.self),
            directoryName: rebuilt.manifest.id)
        #expect(manifest.config?.map(\.key).sorted() == ["API_KEY", "REGION"])
        #expect(manifest.secrets?.map(\.key).contains("API_KEY") != true)
        #expect(rebuilt.configValues["API_KEY"] == "sk-1")
        #expect(rebuilt.source == draft.source)
    }

    @Test("regenerate leaves a non-generated draft (extra files) unchanged")
    func regenerateNonGenerated() throws {
        var draft = try PluginInstaller.draft(fromSnippet: #"{ "svc": { "command": "svc-mcp" } }"#)
        draft.files["skills/x/SKILL.md"] = Data("skill".utf8)
        let unchanged = try PluginInstaller.regenerate(draft)
        #expect(unchanged.files.count == draft.files.count)
        #expect(unchanged.files["plugin.md"] == draft.files["plugin.md"])
    }

    @Test("invalid JSON throws")
    func invalidJSON() {
        #expect(throws: (any Error).self) {
            _ = try PluginInstaller.draft(fromSnippet: "not json")
        }
    }

    @Test("server name with colon and space is safely quoted in YAML")
    func colonInServerName() throws {
        let snippet = #"""
        { "mcpServers": { "my: server": {
            "command": "some-mcp", "args": [] } } }
        """#
        let draft = try PluginInstaller.draft(fromSnippet: snippet)
        let manifest = try IPFManifest.parse(
            markdown: String(decoding: draft.files["plugin.md"]!, as: UTF8.self),
            directoryName: draft.manifest.id)
        #expect(manifest.name == "my: server")
    }

    @Test("embedded newline in server name cannot inject manifest fields")
    func newlineInjectionAttempt() throws {
        let evilName = "evil\nsecrets:\n  - key: FAKE"
        let payload: [String: Any] = [
            "mcpServers": [evilName: ["command": "some-mcp", "args": [String]()]]
        ]
        let snippetData = try JSONSerialization.data(withJSONObject: payload)
        let snippet = String(decoding: snippetData, as: UTF8.self)
        let draft = try PluginInstaller.draft(fromSnippet: snippet)
        let manifest = try IPFManifest.parse(
            markdown: String(decoding: draft.files["plugin.md"]!, as: UTF8.self),
            directoryName: draft.manifest.id)
        let secretKeys = manifest.secrets?.map(\.key) ?? []
        #expect(!secretKeys.contains("FAKE"))
    }

    @Test("multi-server snippet throws and names both servers")
    func multiServerSnippetThrows() {
        let snippet = """
        { "mcpServers": {
            "alpha": { "command": "alpha-mcp" },
            "beta": { "command": "beta-mcp" }
        } }
        """
        #expect(throws: (any Error).self) {
            _ = try PluginInstaller.draft(fromSnippet: snippet)
        }
        do {
            _ = try PluginInstaller.draft(fromSnippet: snippet)
        } catch {
            let message = String(describing: error)
            #expect(message.contains("alpha"))
            #expect(message.contains("beta"))
        }
    }

    @Test("all-symbol server name throws")
    func allSymbolServerNameThrows() {
        let snippet = #"{ "mcpServers": { "!!!": { "command": "some-mcp" } } }"#
        #expect(throws: (any Error).self) {
            _ = try PluginInstaller.draft(fromSnippet: snippet)
        }
    }

    @Test("invalid env key characters throw")
    func invalidEnvKeyThrows() {
        let snippet = """
        { "mcpServers": { "svc": {
            "command": "some-mcp", "args": [],
            "env": { "BAD-KEY": "value" } } } }
        """
        #expect(throws: (any Error).self) {
            _ = try PluginInstaller.draft(fromSnippet: snippet)
        }
    }

    @Test("remote Antigravity serverUrl snippet lifts Bearer token without prefix into Keychain and sets allowedKeys")
    func remoteSnippetLiftsBearerToken() throws {
        let snippet = """
        { "mcpServers": { "sharpei": {
            "serverUrl": "https://sharpei.scromp.net/mcp",
            "headers": {
                "Authorization": "Bearer ec393e9bddc23190",
                "X-Region": "na"
            } } } }
        """
        let draft = try PluginInstaller.draft(fromSnippet: snippet)
        #expect(draft.manifest.id == "sharpei")
        #expect(draft.secretValues == ["AUTHORIZATION": "ec393e9bddc23190"])
        #expect(draft.configValues == ["X_REGION": "na"])
        #expect(draft.manifest.requires?.binaries == nil)

        let mcpData = try #require(draft.files["mcp.json"])
        let decoded = try JSONDecoder().decode([String: MCPServerConfig].self, from: mcpData)
        guard case .remote(let url, let headers, let allowedKeys)? = decoded["sharpei"] else {
            Issue.record("expected remote config in mcp.json"); return
        }
        #expect(url.absoluteString == "https://sharpei.scromp.net/mcp")
        #expect(headers["Authorization"] == "Bearer ${keychain:AUTHORIZATION}")
        #expect(headers["X-Region"] == "${config:X_REGION}")
        #expect(allowedKeys == ["AUTHORIZATION"])
    }

    @Test("regenerate on a remote draft updates allowedKeys and references when re-tagged")
    func remoteRegenerateAfterRetag() throws {
        let snippet = """
        { "mcpServers": { "sharpei": {
            "url": "https://sharpei.scromp.net/mcp",
            "headers": { "Authorization": "Bearer tok-1", "X-Custom": "val-2" } } } }
        """
        var draft = try PluginInstaller.draft(fromSnippet: snippet)
        // Re-tag X_CUSTOM from config -> secret
        draft.secretValues["X_CUSTOM"] = draft.configValues.removeValue(forKey: "X_CUSTOM")
        let rebuilt = try PluginInstaller.regenerate(draft)
        let decoded = try JSONDecoder().decode([String: MCPServerConfig].self, from: rebuilt.files["mcp.json"]!)
        guard case .remote(_, let headers, let allowedKeys)? = decoded["sharpei"] else {
            Issue.record("expected remote config"); return
        }
        #expect(headers["X-Custom"] == "${keychain:X_CUSTOM}")
        #expect(allowedKeys == ["AUTHORIZATION", "X_CUSTOM"])
        #expect(rebuilt.manifest.secrets?.map(\.key).sorted() == ["AUTHORIZATION", "X_CUSTOM"])
    }

    @Test("direct remote form builder creates a valid draft and refuses non-loopback plain http")
    func directRemoteFormBuilder() throws {
        let draft = try PluginInstaller.draftForRemoteServer(
            name: "sharpei",
            urlString: "https://sharpei.scromp.net/mcp",
            bearerToken: "sec-token",
            customHeaders: [("X-Org", "acme", false)]
        )
        #expect(draft.manifest.id == "sharpei")
        #expect(draft.secretValues == ["BEARER_TOKEN": "sec-token"])
        #expect(draft.configValues == ["X_ORG": "acme"])
        let decoded = try JSONDecoder().decode([String: MCPServerConfig].self, from: draft.files["mcp.json"]!)
        guard case .remote(let url, let headers, let allowedKeys)? = decoded["sharpei"] else {
            Issue.record("expected remote config"); return
        }
        #expect(url.absoluteString == "https://sharpei.scromp.net/mcp")
        #expect(headers["Authorization"] == "Bearer ${keychain:BEARER_TOKEN}")
        #expect(headers["X-Org"] == "${config:X_ORG}")
        #expect(allowedKeys == ["BEARER_TOKEN"])

        #expect(throws: (any Error).self) {
            _ = try PluginInstaller.draftForRemoteServer(
                name: "bad", urlString: "http://example.com/mcp", bearerToken: nil, customHeaders: [])
        }
    }

    @Test("direct stdio form builder creates a valid stdio draft")
    func directStdioFormBuilder() throws {
        let draft = try PluginInstaller.draftForStdioServer(
            name: "sqlite",
            command: "uvx",
            args: ["mcp-server-sqlite", "--db-path", "test.db"],
            env: [("DB_TOKEN", "s3cret", true), ("LOG_LEVEL", "info", false)]
        )
        #expect(draft.manifest.id == "sqlite")
        #expect(draft.secretValues == ["DB_TOKEN": "s3cret"])
        #expect(draft.configValues == ["LOG_LEVEL": "info"])
        let decoded = try JSONDecoder().decode([String: MCPServerConfig].self, from: draft.files["mcp.json"]!)
        guard case .stdio(let command, let args, let env)? = decoded["sqlite"] else {
            Issue.record("expected stdio config"); return
        }
        #expect(command == "uvx")
        #expect(args == ["mcp-server-sqlite", "--db-path", "test.db"])
        #expect(env == ["DB_TOKEN": "${keychain:DB_TOKEN}", "LOG_LEVEL": "${config:LOG_LEVEL}"])
    }
}
