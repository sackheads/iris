import Testing
import Foundation
@testable import iris

@Suite("IPF Manifest Tests")
struct IPFManifestTests {
    let valid = """
    ---
    ipf: "1.0"
    id: gemini-notebook
    name: Gemini Notebook
    version: 1.2.0
    description: Query notebooks.
    components:
      mcp: mcp.json
      skills: skills/
    requires:
      binaries:
        - name: notebooklm-mcp
          install_hint: "uv tool install notebooklm-mcp-cli"
    config:
      - key: NLM_PROFILE
        label: Auth profile
        default: default
    secrets:
      - key: API_KEY
        label: API key
        required: true
    auth:
      - kind: external
        setup_command: "nlm login --profile ${config:NLM_PROFILE}"
        check_command: "nlm login --check"
    ---

    # Gemini Notebook
    Body docs here.
    """

    @Test("parses a valid manifest")
    func parsesValid() throws {
        let m = try IPFManifest.parse(markdown: valid, directoryName: "gemini-notebook")
        #expect(m.id == "gemini-notebook")
        #expect(m.version == "1.2.0")
        #expect(m.components?.mcp == "mcp.json")
        #expect(m.requires?.binaries?.first?.installHint == "uv tool install notebooklm-mcp-cli")
        #expect(m.config?.first?.key == "NLM_PROFILE")
        #expect(m.secrets?.first?.required == true)
        #expect(m.auth?.first?.kind == "external")
        #expect(m.auth?.first?.checkCommand == "nlm login --check")
        #expect(m.markdownBody.contains("Body docs here."))
    }

    @Test("rejects missing frontmatter")
    func missingFrontmatter() {
        #expect(throws: IPFError.missingFrontmatter) {
            _ = try IPFManifest.parse(markdown: "# no frontmatter", directoryName: "x")
        }
    }

    @Test("rejects unsupported major version")
    func unsupportedMajor() {
        let doc = "---\nipf: \"2.0\"\nid: x\nname: X\nversion: 1.0.0\n---\n"
        #expect(throws: IPFError.unsupportedVersion("2.0")) {
            _ = try IPFManifest.parse(markdown: doc, directoryName: "x")
        }
    }

    @Test("rejects invalid ids", arguments: ["UPPER", "-lead", "trail-", "a--b", ""])
    func invalidIDs(bad: String) {
        let doc = "---\nipf: \"1.0\"\nid: \"\(bad)\"\nname: X\nversion: 1.0.0\n---\n"
        #expect(throws: IPFError.self) {
            _ = try IPFManifest.parse(markdown: doc, directoryName: bad)
        }
    }

    @Test("rejects id/directory mismatch")
    func idMismatch() {
        let doc = "---\nipf: \"1.0\"\nid: right-name\nname: X\nversion: 1.0.0\n---\n"
        #expect(throws: IPFError.idMismatch(manifest: "right-name", directory: "wrong-dir")) {
            _ = try IPFManifest.parse(markdown: doc, directoryName: "wrong-dir")
        }
    }

    @Test("parses a CRLF-encoded manifest")
    func crlf() throws {
        let doc = valid.replacingOccurrences(of: "\n", with: "\r\n")
        let m = try IPFManifest.parse(markdown: doc, directoryName: "gemini-notebook")
        #expect(m.id == "gemini-notebook")
        #expect(m.version == "1.2.0")
    }

    @Test("accepts 1.x minor versions")
    func minorOK() throws {
        let doc = "---\nipf: \"1.3\"\nid: ok\nname: X\nversion: 1.0.0\n---\n"
        let m = try IPFManifest.parse(markdown: doc, directoryName: "ok")
        #expect(m.ipf == "1.3")
    }
}
