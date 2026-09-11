# Iris Plugin System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the Iris plugin system per `docs/specs/2026-08-27-iris-plugin-system-design.md` — IPF manifests, Keychain secrets, PluginManager registry, MCP/skills/rules integration, install flows, and the Plugins Settings UI.

**Architecture:** A new `PluginManager` actor discovers plugin directories under `~/.iris/plugins/`, parses OKF manifests (`plugin.md`), resolves `${keychain:…}`/`${config:…}` references in memory, and registers components with the existing subsystems (`MCPManager`, `SkillManager`, prompt rules). Install flows (local dir, snippet wrap, harness import) all materialize a plugin directory then run a shared staged installer.

**Tech Stack:** Swift 6 / SwiftPM, Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), SwiftUI, Yams (new dependency) for YAML frontmatter, macOS Keychain via `Security`.

## Global Constraints

- Platform floor: macOS 14 (`Package.swift` `.macOS(.v14)`), Swift 6 language mode.
- Secrets NEVER written to disk or logs. Keychain service names: `iris.plugin.<id>` per plugin, `iris.mcp` for the legacy file.
- Plugin MCP server keys are namespaced `<plugin-id>.<server-name>`.
- Legacy `~/.iris/config/mcp_servers.json` stays live and hand-editable; existing plain-string env values keep working unchanged.
- A broken plugin never breaks Iris or other plugins — isolate failures to per-plugin status.
- Plugin tool descriptions pass through `InjectionGuard.sanitize` exactly as today (already true via `MCPManager.startServer` — do not bypass).
- Reference syntax: `${keychain:KEY}` and `${config:KEY}`, key charset `[A-Za-z0-9_]+`.
- Agent Skills spec (agentskills.io): skill `name` 1–64 chars, `^[a-z0-9]+(-[a-z0-9]+)*$`, must match directory name; `description` 1–1024 chars, non-empty.
- IPF schema version: `ipf: "1.0"`; readers accept any `1.x`, refuse other majors.
- Run tests with: `swift test --filter <SuiteName>` (full suite: `swift test`).
- Commit after every task. Conventional commits (`feat:`, `fix:`, `docs:`, `test:`).
- All work on branch `design/plugin-system` (already checked out).

## File Structure

| File | Responsibility |
|---|---|
| `Sources/iris/IPFManifest.swift` (new) | IPF manifest model, frontmatter parse, validation |
| `Sources/iris/PluginState.swift` (new) | `PluginState` + `PluginStateStore` (`plugins.json`) |
| `Sources/iris/PluginReferences.swift` (new) | `${keychain:}`/`${config:}` expansion |
| `Sources/iris/BinaryResolver.swift` (new) | PATH capture + binary resolution |
| `Sources/iris/AgentSkillValidator.swift` (new) | Agent Skills spec validation |
| `Sources/iris/PluginManager.swift` (new) | Registry actor: discover, validate, resolve, expose components |
| `Sources/iris/PluginInstaller.swift` (new) | Staged install/uninstall + snippet wrap-and-lift |
| `Sources/iris/HarnessConfigImporter.swift` (new) | Detect + parse other harnesses' MCP configs |
| `Sources/iris/PluginAuthRunner.swift` (new) | external-auth check/setup command execution |
| `Sources/iris/PluginsSettingsView.swift` (new) | Plugins tab UI |
| `Sources/iris/PluginInstallWizardView.swift` (new) | Install wizard sheet UI |
| `Sources/iris/IrisPaths.swift` (modify) | `pluginsDir`, `pluginsJSON` |
| `Sources/iris/KeychainManager.swift` (modify) | service-scoped secret APIs |
| `Sources/iris/MCPManager.swift` (modify) | plugin config source, statuses, prefix stop, legacy ref expansion |
| `Sources/iris/SkillManager.swift` (modify) | plugin skill roots + plugin rules |
| `Sources/iris/iris.swift` (modify) | startup wiring at line 78 |
| `Sources/iris/SettingsView.swift` (modify) | add Plugins `.tabItem` |
| `Package.swift` (modify) | add Yams |
| `docs/ipf/spec.md`, `docs/ipf/authoring.md`, `docs/ipf/CHANGELOG.md` (new) | IPF spec-as-product |

---

## Phase 1 — Engine

### Task 1: IPF manifest model, parsing, validation

**Files:**
- Modify: `Package.swift`
- Create: `Sources/iris/IPFManifest.swift`
- Test: `Tests/irisTests/IPFManifestTests.swift`

**Interfaces:**
- Consumes: nothing (foundation task).
- Produces: `struct IPFManifest` (fields below), `enum IPFError: Error, Equatable`, `IPFManifest.parse(markdown:directoryName:) throws -> IPFManifest`, `IPFManifest.supportedMajor == 1`.

- [ ] **Step 1: Add Yams to Package.swift**

In `Package.swift` add to `dependencies:`:

```swift
.package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
```

and to the `iris` target's `dependencies:`:

```swift
.product(name: "Yams", package: "Yams"),
```

Run: `swift build 2>&1 | tail -3` — Expected: `Build complete!`

- [ ] **Step 2: Write the failing tests**

Create `Tests/irisTests/IPFManifestTests.swift`:

```swift
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

    @Test("accepts 1.x minor versions")
    func minorOK() throws {
        let doc = "---\nipf: \"1.3\"\nid: ok\nname: X\nversion: 1.0.0\n---\n"
        let m = try IPFManifest.parse(markdown: doc, directoryName: "ok")
        #expect(m.ipf == "1.3")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter IPFManifestTests 2>&1 | tail -5`
Expected: compile FAILURE — `cannot find 'IPFManifest' in scope`.

- [ ] **Step 4: Implement**

Create `Sources/iris/IPFManifest.swift`:

```swift
import Foundation
import Yams

/// Errors produced while parsing or validating an Iris Plugin Format manifest.
enum IPFError: Error, Equatable, CustomStringConvertible {
    case missingFrontmatter
    case yamlError(String)
    case unsupportedVersion(String)
    case invalidID(String)
    case idMismatch(manifest: String, directory: String)
    case unknownReference(String)
    case undeclaredSecret(String)

    var description: String {
        switch self {
        case .missingFrontmatter: return "plugin.md has no YAML frontmatter block"
        case .yamlError(let e): return "Invalid YAML frontmatter: \(e)"
        case .unsupportedVersion(let v): return "Manifest declares ipf \(v); this Iris supports 1.x. Update Iris."
        case .invalidID(let id): return "Invalid plugin id '\(id)': lowercase letters, digits, single hyphens only"
        case .idMismatch(let m, let d): return "Manifest id '\(m)' does not match directory name '\(d)'"
        case .unknownReference(let r): return "Unresolvable reference \(r)"
        case .undeclaredSecret(let k): return "mcp.json references ${keychain:\(k)} but the manifest does not declare it"
        }
    }
}

/// The Iris Plugin Format (IPF) manifest — the YAML frontmatter of `plugin.md`.
/// Declarations only, never secret values. See docs/ipf/spec.md.
struct IPFManifest: Codable, Sendable, Equatable {
    struct Components: Codable, Sendable, Equatable {
        var mcp: String?
        var skills: String?
        var rules: String?
    }
    struct BinaryRequirement: Codable, Sendable, Equatable {
        let name: String
        var installHint: String?
        enum CodingKeys: String, CodingKey { case name; case installHint = "install_hint" }
    }
    struct Requires: Codable, Sendable, Equatable {
        var binaries: [BinaryRequirement]?
    }
    struct ConfigField: Codable, Sendable, Equatable {
        let key: String
        var label: String?
        var required: Bool?
        var `default`: String?
        var help: String?
    }
    struct SecretField: Codable, Sendable, Equatable {
        let key: String
        var label: String?
        var required: Bool?
        var help: String?
    }
    struct AuthDeclaration: Codable, Sendable, Equatable {
        let kind: String   // v1: "external"
        var label: String?
        var setupCommand: String?
        var checkCommand: String?
        var help: String?
        enum CodingKeys: String, CodingKey {
            case kind, label, help
            case setupCommand = "setup_command"
            case checkCommand = "check_command"
        }
    }

    let ipf: String
    let id: String
    let name: String
    let version: String
    var description: String?
    var author: String?
    var homepage: String?
    var components: Components?
    var requires: Requires?
    var config: [ConfigField]?
    var secrets: [SecretField]?
    var auth: [AuthDeclaration]?

    /// Markdown body after the frontmatter — human docs, rendered in Settings. Not part of YAML.
    var markdownBody: String = ""

    enum CodingKeys: String, CodingKey {
        case ipf, id, name, version, description, author, homepage
        case components, requires, config, secrets, auth
    }

    static let supportedMajor = 1
    static let idPattern = /^[a-z0-9]+(-[a-z0-9]+)*$/

    /// Parses `plugin.md` content. `directoryName` is the plugin folder name; it must equal `id`.
    static func parse(markdown: String, directoryName: String) throws -> IPFManifest {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            throw IPFError.missingFrontmatter
        }
        guard let closeIndex = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            throw IPFError.missingFrontmatter
        }
        let yaml = lines[1..<closeIndex].joined(separator: "\n")
        let body = lines[(closeIndex + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var manifest: IPFManifest
        do {
            manifest = try YAMLDecoder().decode(IPFManifest.self, from: yaml)
        } catch {
            throw IPFError.yamlError(String(describing: error))
        }
        manifest.markdownBody = body

        guard let major = manifest.ipf.split(separator: ".").first,
              Int(major) == supportedMajor else {
            throw IPFError.unsupportedVersion(manifest.ipf)
        }
        guard manifest.id.wholeMatch(of: idPattern) != nil, manifest.id.count <= 64 else {
            throw IPFError.invalidID(manifest.id)
        }
        guard manifest.id == directoryName else {
            throw IPFError.idMismatch(manifest: manifest.id, directory: directoryName)
        }
        return manifest
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter IPFManifestTests 2>&1 | tail -5`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved Sources/iris/IPFManifest.swift Tests/irisTests/IPFManifestTests.swift
git commit -m "feat: add IPF manifest model with Yams-backed parsing and validation"
```

---

### Task 2: Plugin paths and state store

**Files:**
- Modify: `Sources/iris/IrisPaths.swift`
- Create: `Sources/iris/PluginState.swift`
- Test: `Tests/irisTests/PluginStateTests.swift`

**Interfaces:**
- Consumes: `IrisPaths` (existing, `init(root:)` injectable).
- Produces: `IrisPaths.pluginsDir: URL` (`~/.iris/plugins`), `IrisPaths.pluginsJSON: URL` (`~/.iris/config/plugins.json`), `struct PluginState: Codable, Sendable, Equatable { var enabled: Bool; var source: String; var installedVersion: String?; var configValues: [String: String]; var pinnedBinaries: [String: String] }`, `struct PluginStateStore { let paths: IrisPaths; func load() -> [String: PluginState]; func save(_:) }`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/PluginStateTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

@Suite("Plugin State Store Tests")
struct PluginStateTests {
    func tempPaths() throws -> IrisPaths {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-test-\(UUID().uuidString)")
        let paths = IrisPaths(root: dir)
        try paths.ensureDirectories()
        return paths
    }

    @Test("pluginsDir and pluginsJSON resolve under root")
    func pathLayout() throws {
        let paths = try tempPaths()
        #expect(paths.pluginsDir.path.hasSuffix("/plugins"))
        #expect(paths.pluginsJSON.path.hasSuffix("/config/plugins.json"))
        #expect(FileManager.default.fileExists(atPath: paths.pluginsDir.path))
    }

    @Test("round-trips state")
    func roundTrip() throws {
        let paths = try tempPaths()
        let store = PluginStateStore(paths: paths)
        var state = PluginState(source: "snippet")
        state.enabled = false
        state.installedVersion = "1.2.0"
        state.configValues["NLM_PROFILE"] = "work"
        state.pinnedBinaries["gemini-notebook"] = "/opt/homebrew/bin/notebooklm-mcp"
        store.save(["gemini-notebook": state])

        let loaded = store.load()
        #expect(loaded["gemini-notebook"] == state)
    }

    @Test("load returns empty when file absent")
    func emptyLoad() throws {
        let paths = try tempPaths()
        #expect(PluginStateStore(paths: paths).load().isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginStateTests 2>&1 | tail -5`
Expected: compile FAILURE — `pluginsDir` / `PluginStateStore` not found.

- [ ] **Step 3: Implement**

In `Sources/iris/IrisPaths.swift`, after line 37 (`var rulesDir…`), add:

```swift
    // plugins/
    var pluginsDir: URL { root.appendingPathComponent("plugins") }
    var pluginsJSON: URL { configDir.appendingPathComponent("plugins.json") }
```

In `ensureDirectories()` change the array to include `pluginsDir`:

```swift
        for dir in [memoryDir, skillsDir, artifactsDir, libraryDir, configDir, modelsDir, rulesDir, pluginsDir] {
```

Create `Sources/iris/PluginState.swift`:

```swift
import Foundation

/// Machine-local, per-plugin state. Lives in `~/.iris/config/plugins.json` so a plugin
/// directory stays a pure, shareable artifact with nothing machine-local inside.
struct PluginState: Codable, Sendable, Equatable {
    var enabled: Bool = true
    var source: String = "local"           // "local" | "snippet" | "import:<harness>" | "dev"
    var installedVersion: String?
    var configValues: [String: String] = [:]
    var pinnedBinaries: [String: String] = [:]   // server name -> absolute path

    init(enabled: Bool = true, source: String = "local") {
        self.enabled = enabled
        self.source = source
    }
}

struct PluginStateStore: Sendable {
    let paths: IrisPaths

    func load() -> [String: PluginState] {
        guard let data = try? Data(contentsOf: paths.pluginsJSON),
              let states = try? JSONDecoder().decode([String: PluginState].self, from: data) else {
            return [:]
        }
        return states
    }

    func save(_ states: [String: PluginState]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(states) else { return }
        try? data.write(to: paths.pluginsJSON, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PluginStateTests 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/IrisPaths.swift Sources/iris/PluginState.swift Tests/irisTests/PluginStateTests.swift
git commit -m "feat: add plugins directory paths and PluginStateStore"
```

---

### Task 3: Service-scoped Keychain secrets

**Files:**
- Modify: `Sources/iris/KeychainManager.swift`
- Test: `Tests/irisTests/KeychainPluginSecretsTests.swift`

**Interfaces:**
- Consumes: existing `KeychainManager.shared`, existing `loadSecrets()` / `saveSecrets(_:)` (must keep working unchanged — they store under service `com.iris.secrets`).
- Produces: `func secrets(service: String) -> [String: String]`, `func saveSecrets(_ secrets: [String: String], service: String)`, `func deleteSecrets(service: String)`, `static func pluginService(_ id: String) -> String` returning `"iris.plugin.<id>"`, `static let mcpFileService = "iris.mcp"`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/KeychainPluginSecretsTests.swift`:

```swift
import Testing
@testable import iris

@Suite("Keychain Plugin Secrets Tests", .serialized)
struct KeychainPluginSecretsTests {
    @Test("service-scoped secrets are isolated per service")
    func isolation() {
        let kc = KeychainManager.shared
        #expect(kc.usesInMemoryStore)   // guard: never touch the real Keychain in tests
        kc.saveSecrets(["API_KEY": "abc"], service: KeychainManager.pluginService("plug-a"))
        kc.saveSecrets(["API_KEY": "xyz"], service: KeychainManager.pluginService("plug-b"))

        #expect(kc.secrets(service: "iris.plugin.plug-a") == ["API_KEY": "abc"])
        #expect(kc.secrets(service: "iris.plugin.plug-b") == ["API_KEY": "xyz"])

        kc.deleteSecrets(service: "iris.plugin.plug-a")
        #expect(kc.secrets(service: "iris.plugin.plug-a").isEmpty)
        #expect(kc.secrets(service: "iris.plugin.plug-b") == ["API_KEY": "xyz"])
    }

    @Test("legacy loadSecrets/saveSecrets keep working")
    func legacyAPI() {
        let kc = KeychainManager.shared
        kc.saveSecrets(["gemini": "key1"])
        #expect(kc.loadSecrets() == ["gemini": "key1"])
        kc.saveSecrets([:])
    }

    @Test("service name helpers")
    func names() {
        #expect(KeychainManager.pluginService("gemini-notebook") == "iris.plugin.gemini-notebook")
        #expect(KeychainManager.mcpFileService == "iris.mcp")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter KeychainPluginSecretsTests 2>&1 | tail -5`
Expected: compile FAILURE — no `secrets(service:)`.

- [ ] **Step 3: Implement**

In `Sources/iris/KeychainManager.swift`, replace the whole class body content (keep the class declaration and the doc comment on `usesInMemoryStore`) so storage is keyed by service. The legacy default service is unchanged:

```swift
public final class KeychainManager: @unchecked Sendable {
    public static let shared = KeychainManager()

    private let legacyService = "com.iris.secrets"
    private let account = "all-keys"

    public static let mcpFileService = "iris.mcp"
    public static func pluginService(_ id: String) -> String { "iris.plugin.\(id)" }

    // (keep the existing doc comment here)
    let usesInMemoryStore = NSClassFromString("XCTestCase") != nil
    private var inMemorySecrets: [String: [String: String]] = [:]
    private let inMemoryLock = NSLock()

    private init() {}

    // MARK: - Legacy API (service = com.iris.secrets), unchanged behavior
    public func loadSecrets() -> [String: String] { secrets(service: legacyService) }
    public func saveSecrets(_ secrets: [String: String]) { saveSecrets(secrets, service: legacyService) }

    // MARK: - Service-scoped API
    public func secrets(service: String) -> [String: String] {
        if usesInMemoryStore {
            return inMemoryLock.withLock { inMemorySecrets[service] ?? [:] }
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        guard status == errSecSuccess, let data = dataTypeRef as? Data else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    public func saveSecrets(_ secrets: [String: String], service: String) {
        if usesInMemoryStore {
            inMemoryLock.withLock { inMemorySecrets[service] = secrets }
            return
        }
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newQuery = query
            newQuery[kSecValueData as String] = data
            SecItemAdd(newQuery as CFDictionary, nil)
        } else if status != errSecSuccess {
            print("Failed to save secrets to keychain service \(service): \(status)")
        }
    }

    public func deleteSecrets(service: String) {
        if usesInMemoryStore {
            inMemoryLock.withLock { inMemorySecrets[service] = nil }
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 4: Run the new tests AND the full suite (legacy callers must not break)**

Run: `swift test --filter KeychainPluginSecretsTests 2>&1 | tail -5` — Expected: PASS.
Run: `swift test 2>&1 | tail -5` — Expected: no new failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/KeychainManager.swift Tests/irisTests/KeychainPluginSecretsTests.swift
git commit -m "feat: service-scoped Keychain secrets for plugins and legacy MCP file"
```

---

### Task 4: Reference expansion

**Files:**
- Create: `Sources/iris/PluginReferences.swift`
- Test: `Tests/irisTests/PluginReferencesTests.swift`

**Interfaces:**
- Consumes: `IPFError.unknownReference` (Task 1).
- Produces: `enum PluginReferences { static func expand(_ s: String, config: [String: String], secrets: [String: String]) throws -> String; static func keychainKeys(in s: String) -> Set<String>; static func configKeys(in s: String) -> Set<String> }`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/PluginReferencesTests.swift`:

```swift
import Testing
@testable import iris

@Suite("Plugin Reference Expansion Tests")
struct PluginReferencesTests {
    @Test("expands keychain and config refs")
    func expands() throws {
        let out = try PluginReferences.expand(
            "pg://u:${keychain:DB_PASS}@host/${config:DB_NAME}",
            config: ["DB_NAME": "iris"],
            secrets: ["DB_PASS": "s3cret"]
        )
        #expect(out == "pg://u:s3cret@host/iris")
    }

    @Test("passes through strings with no refs")
    func passthrough() throws {
        #expect(try PluginReferences.expand("plain $HOME ${notaref}", config: [:], secrets: [:])
                == "plain $HOME ${notaref}")
    }

    @Test("throws on unresolvable reference")
    func unresolvable() {
        #expect(throws: IPFError.unknownReference("${keychain:MISSING}")) {
            _ = try PluginReferences.expand("${keychain:MISSING}", config: [:], secrets: [:])
        }
    }

    @Test("extracts referenced keys")
    func extraction() {
        let s = "${keychain:A} ${config:B} ${keychain:C}"
        #expect(PluginReferences.keychainKeys(in: s) == ["A", "C"])
        #expect(PluginReferences.configKeys(in: s) == ["B"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginReferencesTests 2>&1 | tail -5`
Expected: compile FAILURE.

- [ ] **Step 3: Implement**

Create `Sources/iris/PluginReferences.swift`:

```swift
import Foundation

/// Expansion of `${keychain:KEY}` / `${config:KEY}` references. Expansion happens in memory
/// at server launch only — expanded strings must never be written to disk or logs.
enum PluginReferences {
    private static let refPattern = /\$\{(keychain|config):([A-Za-z0-9_]+)\}/

    static func expand(_ s: String, config: [String: String], secrets: [String: String]) throws -> String {
        var result = ""
        var index = s.startIndex
        while let match = s[index...].firstMatch(of: refPattern) {
            result += s[index..<match.range.lowerBound]
            let kind = String(match.1)
            let key = String(match.2)
            let value = (kind == "keychain") ? secrets[key] : config[key]
            guard let value else {
                throw IPFError.unknownReference("${\(kind):\(key)}")
            }
            result += value
            index = match.range.upperBound
        }
        result += s[index...]
        return result
    }

    static func keychainKeys(in s: String) -> Set<String> { keys(in: s, kind: "keychain") }
    static func configKeys(in s: String) -> Set<String> { keys(in: s, kind: "config") }

    private static func keys(in s: String, kind: String) -> Set<String> {
        var found: Set<String> = []
        for match in s.matches(of: refPattern) where String(match.1) == kind {
            found.insert(String(match.2))
        }
        return found
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PluginReferencesTests 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/PluginReferences.swift Tests/irisTests/PluginReferencesTests.swift
git commit -m "feat: add keychain/config reference expansion"
```

---

### Task 5: Binary resolver

**Files:**
- Create: `Sources/iris/BinaryResolver.swift`
- Test: `Tests/irisTests/BinaryResolverTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum BinaryResolver { static func resolve(command: String, pinned: String?, searchDirs: [String]?) -> String?; static func defaultSearchDirs() -> [String] }`. `resolve` returns an absolute path to an existing executable, or nil.

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/BinaryResolverTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

@Suite("Binary Resolver Tests")
struct BinaryResolverTests {
    @Test("absolute path that exists resolves to itself")
    func absolute() {
        #expect(BinaryResolver.resolve(command: "/bin/ls", pinned: nil, searchDirs: []) == "/bin/ls")
    }

    @Test("bare name resolves via search dirs")
    func bareName() {
        #expect(BinaryResolver.resolve(command: "ls", pinned: nil, searchDirs: ["/nonexistent", "/bin"]) == "/bin/ls")
    }

    @Test("pinned path wins over search")
    func pinnedWins() {
        #expect(BinaryResolver.resolve(command: "ls", pinned: "/bin/ls", searchDirs: ["/usr/bin"]) == "/bin/ls")
    }

    @Test("missing binary returns nil")
    func missing() {
        #expect(BinaryResolver.resolve(command: "definitely-not-a-real-binary-xyz", pinned: nil, searchDirs: ["/bin"]) == nil)
    }

    @Test("pinned path that does not exist falls back to search")
    func badPin() {
        #expect(BinaryResolver.resolve(command: "ls", pinned: "/nope/ls", searchDirs: ["/bin"]) == "/bin/ls")
    }

    @Test("default search dirs include the common install locations")
    func defaults() {
        let dirs = BinaryResolver.defaultSearchDirs()
        #expect(dirs.contains("/opt/homebrew/bin"))
        #expect(dirs.contains("/usr/local/bin"))
        #expect(dirs.contains(("~/.local/bin" as NSString).expandingTildeInPath))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BinaryResolverTests 2>&1 | tail -5`
Expected: compile FAILURE.

- [ ] **Step 3: Implement**

Create `Sources/iris/BinaryResolver.swift`:

```swift
import Foundation

/// Resolves MCP server commands to absolute executable paths. GUI apps do not inherit the
/// user's shell PATH, so a bare command like `notebooklm-mcp` is resolved against the login
/// shell's PATH (captured once per launch) plus the common install locations. Iris never
/// installs runtimes itself.
enum BinaryResolver {
    /// Login-shell PATH entries, captured once. Falls back to empty on any failure.
    private static let loginShellPath: [String] = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: ":").filter { !$0.isEmpty }
        } catch {
            return []
        }
    }()

    static func defaultSearchDirs() -> [String] {
        let common = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { ($0 as NSString).expandingTildeInPath }
        var seen: Set<String> = []
        return (loginShellPath + common).filter { seen.insert($0).inserted }
    }

    /// Resolution order: valid pin > absolute/relative path as given > search dirs.
    static func resolve(command: String, pinned: String? = nil, searchDirs: [String]? = nil) -> String? {
        let fm = FileManager.default
        if let pinned {
            let pin = (pinned as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: pin) { return pin }
        }
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return fm.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        for dir in searchDirs ?? defaultSearchDirs() {
            let candidate = "\(dir)/\(expanded)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BinaryResolverTests 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/BinaryResolver.swift Tests/irisTests/BinaryResolverTests.swift
git commit -m "feat: add binary resolver with login-shell PATH capture"
```

---

### Task 6: Agent Skills validator

**Files:**
- Create: `Sources/iris/AgentSkillValidator.swift`
- Test: `Tests/irisTests/AgentSkillValidatorTests.swift`

**Interfaces:**
- Consumes: nothing (uses Yams for frontmatter).
- Produces: `enum AgentSkillValidator { static func validateName(_ name: String) -> String?; static func validate(directory: URL) -> [String] }` — `validate` returns human-readable violations (empty array = spec-conformant).

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/AgentSkillValidatorTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

@Suite("Agent Skill Validator Tests")
struct AgentSkillValidatorTests {
    func makeSkill(dirName: String, skillMD: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-skill-test-\(UUID().uuidString)")
            .appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let skillMD {
            try skillMD.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test("valid skill passes")
    func valid() throws {
        let dir = try makeSkill(dirName: "pdf-processing", skillMD: """
        ---
        name: pdf-processing
        description: Extract PDF text and tables. Use when handling PDFs.
        ---
        Instructions here.
        """)
        #expect(AgentSkillValidator.validate(directory: dir).isEmpty)
    }

    @Test("name rules", arguments: [
        ("PDF-Processing", false), ("-pdf", false), ("pdf-", false),
        ("pdf--processing", false), ("pdf-processing", true),
        (String(repeating: "a", count: 65), false), ("a", true)
    ])
    func nameRules(name: String, ok: Bool) {
        #expect((AgentSkillValidator.validateName(name) == nil) == ok)
    }

    @Test("missing SKILL.md is a violation")
    func missingFile() throws {
        let dir = try makeSkill(dirName: "no-skill", skillMD: nil)
        #expect(!AgentSkillValidator.validate(directory: dir).isEmpty)
    }

    @Test("name/directory mismatch is a violation")
    func mismatch() throws {
        let dir = try makeSkill(dirName: "folder-name", skillMD: """
        ---
        name: other-name
        description: Something.
        ---
        """)
        #expect(AgentSkillValidator.validate(directory: dir).contains { $0.contains("match") })
    }

    @Test("empty description is a violation")
    func emptyDescription() throws {
        let dir = try makeSkill(dirName: "desc-less", skillMD: """
        ---
        name: desc-less
        ---
        """)
        #expect(AgentSkillValidator.validate(directory: dir).contains { $0.contains("description") })
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AgentSkillValidatorTests 2>&1 | tail -5`
Expected: compile FAILURE.

- [ ] **Step 3: Implement**

Create `Sources/iris/AgentSkillValidator.swift`:

```swift
import Foundation
import Yams

/// Validates a skill directory against the Agent Skills specification (agentskills.io):
/// SKILL.md present; frontmatter `name` 1-64 chars of lowercase alphanumerics and single
/// hyphens, matching the directory name; `description` 1-1024 chars, non-empty. Optional
/// fields (license, compatibility, metadata, allowed-tools) must merely parse.
enum AgentSkillValidator {
    private static let namePattern = /^[a-z0-9]+(-[a-z0-9]+)*$/

    /// Returns a violation message, or nil if the name is valid.
    static func validateName(_ name: String) -> String? {
        if name.isEmpty || name.count > 64 {
            return "Skill name must be 1-64 characters (got \(name.count))"
        }
        if name.wholeMatch(of: namePattern) == nil {
            return "Skill name '\(name)' must be lowercase alphanumerics and single hyphens"
        }
        return nil
    }

    /// Returns all spec violations for the skill directory. Empty array = valid.
    static func validate(directory: URL) -> [String] {
        var violations: [String] = []
        let skillMD = directory.appendingPathComponent("SKILL.md")
        guard let content = try? String(contentsOf: skillMD, encoding: .utf8) else {
            return ["\(directory.lastPathComponent): SKILL.md is missing"]
        }

        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ["\(directory.lastPathComponent): SKILL.md has no YAML frontmatter"]
        }
        let yaml = lines[1..<close].joined(separator: "\n")
        guard let front = (try? Yams.load(yaml: yaml)) as? [String: Any] else {
            return ["\(directory.lastPathComponent): SKILL.md frontmatter is not valid YAML"]
        }

        let name = front["name"] as? String ?? ""
        if let nameError = validateName(name) {
            violations.append(nameError)
        }
        if !name.isEmpty && name != directory.lastPathComponent {
            violations.append("Skill name '\(name)' must match its directory name '\(directory.lastPathComponent)'")
        }
        let description = (front["description"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if description.isEmpty || description.count > 1024 {
            violations.append("\(directory.lastPathComponent): description must be 1-1024 non-empty characters")
        }
        return violations
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AgentSkillValidatorTests 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/AgentSkillValidator.swift Tests/irisTests/AgentSkillValidatorTests.swift
git commit -m "feat: add Agent Skills spec validator"
```

---

### Task 7: PluginManager actor

**Files:**
- Create: `Sources/iris/PluginManager.swift`
- Test: `Tests/irisTests/PluginManagerTests.swift`

**Interfaces:**
- Consumes: `IPFManifest.parse` (Task 1), `PluginStateStore` (Task 2), `KeychainManager.secrets(service:)` + `pluginService` (Task 3), `PluginReferences` (Task 4), `BinaryResolver` (Task 5), `AgentSkillValidator` (Task 6), `MCPServerConfig` (existing).
- Produces:

```swift
enum PluginStatus: Sendable, Equatable { case ok; case needsConfig(String); case failed(String); case disabled }
struct LoadedPlugin: Sendable { let manifest: IPFManifest; let directory: URL; var state: PluginState; var status: PluginStatus }
actor PluginManager {
    static let shared = PluginManager()
    init(paths: IrisPaths = .default)
    func loadAll() async
    func plugins() -> [LoadedPlugin]                       // sorted by manifest.name
    func setEnabled(_ id: String, enabled: Bool) async     // persists state + reloads
    func setConfigValue(_ id: String, key: String, value: String) async
    func mcpConfigs() -> [String: MCPServerConfig]         // namespaced "<id>.<server>", refs expanded, commands resolved — enabled+ok plugins only
    func skillRoots() -> [URL]                             // enabled plugins' skills dirs
    func ruleFiles() -> [URL]                              // enabled plugins' rules/*.md
}
```

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/PluginManagerTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

@Suite("Plugin Manager Tests", .serialized)
struct PluginManagerTests {
    /// Builds a temp ~/.iris with one installed plugin and returns (paths, pluginDir).
    func fixture(manifest: String, id: String, mcpJSON: String? = nil) throws -> (IrisPaths, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-pm-test-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()
        let dir = paths.pluginsDir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(to: dir.appendingPathComponent("plugin.md"), atomically: true, encoding: .utf8)
        if let mcpJSON {
            try mcpJSON.write(to: dir.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
        }
        return (paths, dir)
    }

    let simpleManifest = """
    ---
    ipf: "1.0"
    id: echo-plug
    name: Echo Plug
    version: 1.0.0
    components:
      mcp: mcp.json
    secrets:
      - key: TOKEN
        required: true
    ---
    """
    // /bin/echo exists everywhere; env value carries a keychain ref
    let mcpJSON = """
    { "echo": { "command": "/bin/echo", "args": ["hi"], "env": { "TOKEN": "${keychain:TOKEN}" } } }
    """

    @Test("loads a valid plugin and resolves references")
    func loadsAndResolves() async throws {
        let (paths, _) = try fixture(manifest: simpleManifest, id: "echo-plug", mcpJSON: mcpJSON)
        KeychainManager.shared.saveSecrets(["TOKEN": "tok123"], service: KeychainManager.pluginService("echo-plug"))
        defer { KeychainManager.shared.deleteSecrets(service: KeychainManager.pluginService("echo-plug")) }

        let pm = PluginManager(paths: paths)
        await pm.loadAll()

        let plugins = await pm.plugins()
        #expect(plugins.count == 1)
        #expect(plugins[0].status == .ok)

        let configs = await pm.mcpConfigs()
        #expect(configs["echo-plug.echo"]?.command == "/bin/echo")
        #expect(configs["echo-plug.echo"]?.env?["TOKEN"] == "tok123")
    }

    @Test("missing required secret means needsConfig, not failure")
    func missingSecret() async throws {
        let (paths, _) = try fixture(manifest: simpleManifest, id: "echo-plug", mcpJSON: mcpJSON)
        let pm = PluginManager(paths: paths)
        await pm.loadAll()

        let plugins = await pm.plugins()
        guard case .needsConfig = plugins[0].status else {
            Issue.record("expected needsConfig, got \(plugins[0].status)")
            return
        }
        #expect(await pm.mcpConfigs().isEmpty)
    }

    @Test("broken manifest isolates to that plugin")
    func brokenIsolated() async throws {
        let (paths, _) = try fixture(manifest: "not a manifest", id: "broken")
        let dir2 = paths.pluginsDir.appendingPathComponent("good-one")
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        try "---\nipf: \"1.0\"\nid: good-one\nname: Good\nversion: 1.0.0\n---\n"
            .write(to: dir2.appendingPathComponent("plugin.md"), atomically: true, encoding: .utf8)

        let pm = PluginManager(paths: paths)
        await pm.loadAll()
        let plugins = await pm.plugins()
        #expect(plugins.count == 2)
        #expect(plugins.first { $0.directory.lastPathComponent == "good-one" }?.status == .ok)
        guard case .failed = plugins.first(where: { $0.directory.lastPathComponent == "broken" })?.status else {
            Issue.record("expected failed status for broken plugin")
            return
        }
    }

    @Test("disabled plugin contributes nothing")
    func disabled() async throws {
        let (paths, _) = try fixture(manifest: simpleManifest, id: "echo-plug", mcpJSON: mcpJSON)
        KeychainManager.shared.saveSecrets(["TOKEN": "t"], service: KeychainManager.pluginService("echo-plug"))
        defer { KeychainManager.shared.deleteSecrets(service: KeychainManager.pluginService("echo-plug")) }

        let pm = PluginManager(paths: paths)
        await pm.loadAll()
        await pm.setEnabled("echo-plug", enabled: false)
        #expect(await pm.mcpConfigs().isEmpty)
        #expect(await pm.plugins()[0].status == .disabled)
    }

    @Test("skill roots and rule files come from enabled plugins")
    func skillAndRuleRoots() async throws {
        let manifest = """
        ---
        ipf: "1.0"
        id: skills-plug
        name: Skills Plug
        version: 1.0.0
        components:
          skills: skills/
          rules: rules/
        ---
        """
        let (paths, dir) = try fixture(manifest: manifest, id: "skills-plug")
        let skillDir = dir.appendingPathComponent("skills/my-skill")
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "---\nname: my-skill\ndescription: Does things.\n---\n"
            .write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let rulesDir = dir.appendingPathComponent("rules")
        try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        try "Always be excellent.".write(to: rulesDir.appendingPathComponent("conduct.md"), atomically: true, encoding: .utf8)

        let pm = PluginManager(paths: paths)
        await pm.loadAll()
        #expect(await pm.skillRoots() == [dir.appendingPathComponent("skills")])
        #expect(await pm.ruleFiles().map(\.lastPathComponent) == ["conduct.md"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginManagerTests 2>&1 | tail -5`
Expected: compile FAILURE.

- [ ] **Step 3: Implement**

Create `Sources/iris/PluginManager.swift`:

```swift
import Foundation

enum PluginStatus: Sendable, Equatable {
    case ok
    case needsConfig(String)
    case failed(String)
    case disabled
}

struct LoadedPlugin: Sendable {
    let manifest: IPFManifest
    let directory: URL
    var state: PluginState
    var status: PluginStatus
}

/// Registry for installed plugins. Discovers directories under `~/.iris/plugins/`, validates
/// manifests, resolves references, and exposes components to the subsystems that own them
/// (MCPManager, SkillManager, prompt rules). Executes nothing itself. A broken plugin is
/// isolated to a `.failed` status and never blocks other plugins.
actor PluginManager {
    static let shared = PluginManager()

    private let paths: IrisPaths
    private var loaded: [String: LoadedPlugin] = [:]

    init(paths: IrisPaths = .default) {
        self.paths = paths
    }

    func loadAll() async {
        loaded = [:]
        let store = PluginStateStore(paths: paths)
        var states = store.load()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: paths.pluginsDir.path) else { return }

        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let dir = paths.pluginsDir.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            var state = states[entry] ?? PluginState()
            states[entry] = state

            guard let content = try? String(contentsOf: dir.appendingPathComponent("plugin.md"), encoding: .utf8) else {
                loaded[entry] = LoadedPlugin(
                    manifest: placeholderManifest(id: entry), directory: dir, state: state,
                    status: .failed("plugin.md is missing"))
                continue
            }
            let manifest: IPFManifest
            do {
                manifest = try IPFManifest.parse(markdown: content, directoryName: entry)
            } catch {
                loaded[entry] = LoadedPlugin(
                    manifest: placeholderManifest(id: entry), directory: dir, state: state,
                    status: .failed(String(describing: error)))
                continue
            }

            if !state.enabled {
                loaded[entry] = LoadedPlugin(manifest: manifest, directory: dir, state: state, status: .disabled)
                continue
            }
            state.installedVersion = manifest.version
            states[entry] = state
            let status = evaluateReadiness(manifest: manifest, directory: dir, state: state)
            loaded[entry] = LoadedPlugin(manifest: manifest, directory: dir, state: state, status: status)
        }
        store.save(states)
    }

    func plugins() -> [LoadedPlugin] {
        loaded.values.sorted {
            $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending
        }
    }

    func setEnabled(_ id: String, enabled: Bool) async {
        let store = PluginStateStore(paths: paths)
        var states = store.load()
        var state = states[id] ?? PluginState()
        state.enabled = enabled
        states[id] = state
        store.save(states)
        await loadAll()
    }

    func setConfigValue(_ id: String, key: String, value: String) async {
        let store = PluginStateStore(paths: paths)
        var states = store.load()
        var state = states[id] ?? PluginState()
        state.configValues[key] = value
        states[id] = state
        store.save(states)
        await loadAll()
    }

    /// Resolved, namespaced MCP configs from all enabled+ready plugins. Secrets are expanded
    /// in memory here and go straight into Process environments — never to disk.
    func mcpConfigs() -> [String: MCPServerConfig] {
        var result: [String: MCPServerConfig] = [:]
        for plugin in loaded.values where plugin.status == .ok {
            guard let mcpRel = plugin.manifest.components?.mcp else { continue }
            let mcpURL = plugin.directory.appendingPathComponent(mcpRel)
            guard let data = try? Data(contentsOf: mcpURL),
                  let servers = try? JSONDecoder().decode([String: MCPServerConfig].self, from: data) else {
                continue
            }
            let config = effectiveConfigValues(plugin)
            let secrets = KeychainManager.shared.secrets(service: KeychainManager.pluginService(plugin.manifest.id))
            for (serverName, server) in servers {
                guard let resolved = resolveServer(server, plugin: plugin, serverName: serverName,
                                                   config: config, secrets: secrets) else { continue }
                result["\(plugin.manifest.id).\(serverName)"] = resolved
            }
        }
        return result
    }

    func skillRoots() -> [URL] {
        loaded.values
            .filter { $0.status == .ok }
            .compactMap { plugin in
                plugin.manifest.components?.skills.map { plugin.directory.appendingPathComponent($0) }
            }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    func ruleFiles() -> [URL] {
        var files: [URL] = []
        for plugin in loaded.values where plugin.status == .ok {
            guard let rulesRel = plugin.manifest.components?.rules else { continue }
            let rulesDir = plugin.directory.appendingPathComponent(rulesRel)
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: rulesDir.path) else { continue }
            for item in items.sorted() where item.hasSuffix(".md") && !item.hasPrefix(".") {
                files.append(rulesDir.appendingPathComponent(item))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - Private

    private func placeholderManifest(id: String) -> IPFManifest {
        var m = try! IPFManifest.parse(
            markdown: "---\nipf: \"1.0\"\nid: \(id)\nname: \(id)\nversion: 0.0.0\n---\n",
            directoryName: id)
        m.markdownBody = ""
        return m
    }

    private func effectiveConfigValues(_ plugin: LoadedPlugin) -> [String: String] {
        var values: [String: String] = [:]
        for field in plugin.manifest.config ?? [] {
            if let def = field.default { values[field.key] = def }
        }
        values.merge(plugin.state.configValues) { _, user in user }
        return values
    }

    /// Ready when: required secrets present, required config present, declared binaries found,
    /// and every ${keychain:} ref in mcp.json is declared. Any gap → .needsConfig with a reason.
    private func evaluateReadiness(manifest: IPFManifest, directory: URL, state: PluginState) -> PluginStatus {
        let secrets = KeychainManager.shared.secrets(service: KeychainManager.pluginService(manifest.id))
        for field in manifest.secrets ?? [] where field.required == true {
            if secrets[field.key] == nil {
                return .needsConfig("Missing secret \(field.key)")
            }
        }
        var config: [String: String] = [:]
        for field in manifest.config ?? [] {
            config[field.key] = state.configValues[field.key] ?? field.default
            if field.required == true && (config[field.key] ?? "").isEmpty {
                return .needsConfig("Missing config \(field.key)")
            }
        }
        for binary in manifest.requires?.binaries ?? [] {
            if BinaryResolver.resolve(command: binary.name, pinned: state.pinnedBinaries[binary.name]) == nil {
                let hint = binary.installHint.map { " — install with: \($0)" } ?? ""
                return .needsConfig("Binary '\(binary.name)' not found\(hint)")
            }
        }
        if let mcpRel = manifest.components?.mcp,
           let raw = try? String(contentsOf: directory.appendingPathComponent(mcpRel), encoding: .utf8) {
            let declared = Set((manifest.secrets ?? []).map(\.key))
            for key in PluginReferences.keychainKeys(in: raw) where !declared.contains(key) {
                return .failed(IPFError.undeclaredSecret(key).description)
            }
            for key in PluginReferences.keychainKeys(in: raw) where secrets[key] == nil {
                return .needsConfig("Missing secret \(key)")
            }
            for key in PluginReferences.configKeys(in: raw) where config[key] == nil {
                return .needsConfig("Missing config \(key)")
            }
        }
        if let skillsRel = manifest.components?.skills {
            let skillsDir = directory.appendingPathComponent(skillsRel)
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: skillsDir.path) {
                for entry in entries where !entry.hasPrefix(".") {
                    let violations = AgentSkillValidator.validate(directory: skillsDir.appendingPathComponent(entry))
                    if let first = violations.first {
                        return .failed("Skill '\(entry)': \(first)")
                    }
                }
            }
        }
        return .ok
    }

    private func resolveServer(_ server: MCPServerConfig, plugin: LoadedPlugin, serverName: String,
                               config: [String: String], secrets: [String: String]) -> MCPServerConfig? {
        guard let command = BinaryResolver.resolve(
            command: server.command, pinned: plugin.state.pinnedBinaries[serverName]) else { return nil }
        var env: [String: String]? = nil
        if let rawEnv = server.env {
            var expanded: [String: String] = [:]
            for (key, value) in rawEnv {
                guard let v = try? PluginReferences.expand(value, config: config, secrets: secrets) else { return nil }
                expanded[key] = v
            }
            env = expanded
        }
        return MCPServerConfig(command: command, args: server.args, env: env)
    }
}
```

Note: `MCPServerConfig`'s memberwise init is internal and available (same module).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PluginManagerTests 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/PluginManager.swift Tests/irisTests/PluginManagerTests.swift
git commit -m "feat: add PluginManager registry actor"
```

---

### Task 8: MCPManager — plugin source, statuses, legacy keychain refs

**Files:**
- Modify: `Sources/iris/MCPManager.swift`
- Test: `Tests/irisTests/MCPManagerConfigTests.swift`

**Interfaces:**
- Consumes: `PluginReferences` (Task 4), `KeychainManager.secrets(service:)` + `mcpFileService` (Task 3).
- Produces (on `MCPManager`):

```swift
enum ServerStatus: Sendable, Equatable { case running(toolCount: Int); case failed(String) }
func setPluginConfigs(_ configs: [String: MCPServerConfig])
func serverStatuses() -> [String: ServerStatus]
func stopServers(withPrefix prefix: String)     // "gemini-notebook." stops that plugin's servers
static func expandLegacyEnv(_ config: MCPServerConfig, secrets: [String: String]) -> MCPServerConfig
static func mergeConfigs(legacy: [String: MCPServerConfig], plugin: [String: MCPServerConfig]) -> [String: MCPServerConfig]
```

`startServers()` starts the merge of both sources and records per-server status instead of only printing.

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/MCPManagerConfigTests.swift` (pure functions only — no process spawning):

```swift
import Testing
@testable import iris

@Suite("MCPManager Config Merge Tests")
struct MCPManagerConfigTests {
    @Test("legacy env keychain refs expand; plain values pass through")
    func legacyExpansion() {
        let config = MCPServerConfig(command: "/bin/x", args: [],
                                     env: ["A": "${keychain:PG}", "B": "plain"])
        let out = MCPManager.expandLegacyEnv(config, secrets: ["PG": "s3cret"])
        #expect(out.env?["A"] == "s3cret")
        #expect(out.env?["B"] == "plain")
    }

    @Test("unresolvable legacy ref leaves value untouched (back-compat)")
    func legacyUnresolvable() {
        let config = MCPServerConfig(command: "/bin/x", args: [], env: ["A": "${keychain:NOPE}"])
        let out = MCPManager.expandLegacyEnv(config, secrets: [:])
        #expect(out.env?["A"] == "${keychain:NOPE}")
    }

    @Test("merge: plugin keys are namespaced so they never collide with legacy")
    func merge() {
        let legacy = ["sqlite": MCPServerConfig(command: "/bin/a", args: [], env: nil)]
        let plugin = ["my-plug.echo": MCPServerConfig(command: "/bin/b", args: [], env: nil)]
        let merged = MCPManager.mergeConfigs(legacy: legacy, plugin: plugin)
        #expect(merged.count == 2)
        #expect(merged["sqlite"]?.command == "/bin/a")
        #expect(merged["my-plug.echo"]?.command == "/bin/b")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MCPManagerConfigTests 2>&1 | tail -5`
Expected: compile FAILURE.

- [ ] **Step 3: Implement**

In `Sources/iris/MCPManager.swift`:

(a) Add inside the actor, below `private var servers`:

```swift
    enum ServerStatus: Sendable, Equatable {
        case running(toolCount: Int)
        case failed(String)
    }
    private var pluginConfigs: [String: MCPServerConfig] = [:]
    private var statuses: [String: ServerStatus] = [:]

    func setPluginConfigs(_ configs: [String: MCPServerConfig]) {
        pluginConfigs = configs
    }

    func serverStatuses() -> [String: ServerStatus] { statuses }

    func stopServers(withPrefix prefix: String) {
        for (name, server) in servers where name.hasPrefix(prefix) {
            server.process.terminate()
            servers[name] = nil
            statuses[name] = nil
        }
    }
```

(b) Replace the body of `startServers()`:

```swift
    func startServers() async {
        var legacy: [String: MCPServerConfig] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let configs = try? JSONDecoder().decode([String: MCPServerConfig].self, from: data) {
            let fileSecrets = KeychainManager.shared.secrets(service: KeychainManager.mcpFileService)
            legacy = configs.mapValues { Self.expandLegacyEnv($0, secrets: fileSecrets) }
        }
        let merged = Self.mergeConfigs(legacy: legacy, plugin: pluginConfigs)

        for (name, config) in merged where servers[name] == nil {
            do {
                try await startServer(name: name, config: config)
            } catch {
                statuses[name] = .failed(String(describing: error))
                print("Failed to start MCP server \(name): \(error)")
            }
        }
    }
```

(c) At the end of `startServer(name:config:)`, after the `servers[name] = ActiveServer(...)` assignment, add:

```swift
        statuses[name] = .running(toolCount: toolsResult.tools.count)
```

(d) In `stopServers()`, after `servers.removeAll()`, add:

```swift
        statuses.removeAll()
```

(e) Add the pure static helpers at the bottom of the actor:

```swift
    /// Expands `${keychain:KEY}` refs in a legacy mcp_servers.json entry against the shared
    /// `iris.mcp` Keychain service. Unresolvable refs are left as-is so pre-existing files
    /// that happen to contain `${...}` strings keep working unchanged.
    static func expandLegacyEnv(_ config: MCPServerConfig, secrets: [String: String]) -> MCPServerConfig {
        guard let env = config.env else { return config }
        var expanded: [String: String] = [:]
        for (key, value) in env {
            expanded[key] = (try? PluginReferences.expand(value, config: [:], secrets: secrets)) ?? value
        }
        return MCPServerConfig(command: config.command, args: config.args, env: expanded)
    }

    /// Plugin keys are already namespaced `<plugin-id>.<server>`, so a straight merge cannot
    /// collide with legacy names; legacy wins if a collision is somehow constructed.
    static func mergeConfigs(legacy: [String: MCPServerConfig],
                             plugin: [String: MCPServerConfig]) -> [String: MCPServerConfig] {
        var merged = plugin
        for (k, v) in legacy { merged[k] = v }
        return merged
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MCPManagerConfigTests 2>&1 | tail -5` — Expected: PASS.
Run: `swift build 2>&1 | tail -3` — Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/MCPManager.swift Tests/irisTests/MCPManagerConfigTests.swift
git commit -m "feat: MCPManager merges plugin configs, tracks statuses, expands legacy keychain refs"
```

---

### Task 9: Plugin skills and rules in SkillManager

**Files:**
- Modify: `Sources/iris/SkillManager.swift`
- Test: `Tests/irisTests/SkillManagerPluginTests.swift`

**Interfaces:**
- Consumes: `PluginManager.shared.skillRoots()` / `.ruleFiles()` (Task 7).
- Produces: `SkillInfo` gains `let skillFilePath: String` (absolute path of SKILL.md). `listSkills(paths:extraRoots:)` and `loadCustomRules(paths:extraRuleFiles:)` gain optional parameters: `extraRoots: [URL]? = nil` / `extraRuleFiles: [URL]? = nil`; when nil they pull from `PluginManager.shared`. `discoverSkills` prints each skill's real `skillFilePath` instead of hardcoding `~/.iris/memory/skills/`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/SkillManagerPluginTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

@Suite("SkillManager Plugin Integration Tests")
struct SkillManagerPluginTests {
    func tempSkillRoot(skillName: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-sm-test-\(UUID().uuidString)/skills")
        let dir = root.appendingPathComponent(skillName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(skillName)\ndescription: Plugin-provided skill.\n---\nBody."
            .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("listSkills includes skills from extra roots with real paths")
    func extraRoots() async throws {
        let paths = IrisPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-sm-empty-\(UUID().uuidString)"))
        try paths.ensureDirectories()
        let root = try tempSkillRoot(skillName: "notebook-research")

        let skills = await SkillManager.shared.listSkills(paths: paths, extraRoots: [root])
        #expect(skills.count == 1)
        #expect(skills[0].name == "notebook-research")
        #expect(skills[0].skillFilePath == root.appendingPathComponent("notebook-research/SKILL.md").path)
    }

    @Test("discoverSkills shows the real path")
    func discoverPath() async throws {
        let paths = IrisPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-sm-empty2-\(UUID().uuidString)"))
        try paths.ensureDirectories()
        let root = try tempSkillRoot(skillName: "notebook-research")

        let summary = await SkillManager.shared.discoverSkills(paths: paths, extraRoots: [root])
        #expect(summary.contains(root.appendingPathComponent("notebook-research/SKILL.md").path))
    }

    @Test("loadCustomRules appends extra rule files")
    func pluginRules() async throws {
        let paths = IrisPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-sm-empty3-\(UUID().uuidString)"))
        try paths.ensureDirectories()
        let ruleFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-rule-\(UUID().uuidString).md")
        try "Plugin rule content.".write(to: ruleFile, atomically: true, encoding: .utf8)

        let rules = await SkillManager.shared.loadCustomRules(paths: paths, extraRuleFiles: [ruleFile])
        #expect(rules.contains("Plugin rule content."))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SkillManagerPluginTests 2>&1 | tail -5`
Expected: compile FAILURE — no `extraRoots` parameter / `skillFilePath`.

- [ ] **Step 3: Implement**

In `Sources/iris/SkillManager.swift`:

(a) `SkillInfo` (line 46) gains the path:

```swift
    struct SkillInfo: Sendable {
        let name: String
        let description: String
        let folderName: String
        let skillFilePath: String
    }
```

(b) Replace `listSkills` with a multi-root version:

```swift
    /// Deterministic list of registered skills across the built-in skills dir and any plugin
    /// skill roots. `extraRoots: nil` pulls enabled plugins' roots from PluginManager; tests
    /// pass explicit roots. Sorted by display name.
    func listSkills(paths: IrisPaths = .default, extraRoots: [URL]? = nil) async -> [SkillInfo] {
        let pluginRoots = extraRoots ?? (await PluginManager.shared.skillRoots())
        let roots = [paths.skillsDir] + pluginRoots
        let fileManager = FileManager.default

        var skills: [SkillInfo] = []
        for root in roots {
            guard let items = try? fileManager.contentsOfDirectory(atPath: root.path) else { continue }
            for item in items where !item.hasPrefix(".") {
                let skillPath = root.appendingPathComponent(item).appendingPathComponent("SKILL.md").path
                guard fileManager.fileExists(atPath: skillPath),
                      let content = try? String(contentsOfFile: skillPath, encoding: .utf8) else {
                    continue
                }
                skills.append(parseFrontmatter(from: content, folderName: item, skillFilePath: skillPath))
            }
        }
        return skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
```

(c) `parseFrontmatter` signature becomes `parseFrontmatter(from content: String, folderName: String, skillFilePath: String) -> SkillInfo`; its return becomes:

```swift
        return SkillInfo(name: name, description: description, folderName: folderName, skillFilePath: skillFilePath)
```

(d) `discoverSkills` gains passthrough `extraRoots: [URL]? = nil` (forwarded to `listSkills`) and the path line (line 98) becomes:

```swift
            skillsSummary += "**Path:** \(skill.skillFilePath)\n\n"
```

(e) `readSkillBody` reads from `skill.skillFilePath` instead of rebuilding the path:

```swift
        return try? String(contentsOfFile: skill.skillFilePath, encoding: .utf8)
```

Also pass `extraRoots` through: `readSkillBody(name:paths:extraRoots:)` with `extraRoots: [URL]? = nil` forwarded to `listSkills`.

(f) `loadCustomRules` gains plugin rules:

```swift
    func loadCustomRules(paths: IrisPaths = .default, extraRuleFiles: [URL]? = nil) async -> String {
        // ... existing body unchanged up to `return rulesContent` ...
        let pluginRules = extraRuleFiles ?? (await PluginManager.shared.ruleFiles())
        for fileURL in pluginRules {
            if let content = try? String(contentsOf: fileURL, encoding: .utf8),
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rulesContent += "\n\n# Rule (plugin): \(fileURL.lastPathComponent)\n\(content)\n"
            }
        }
        return rulesContent
    }
```

- [ ] **Step 4: Run new tests and full suite**

Run: `swift test --filter SkillManagerPluginTests 2>&1 | tail -5` — Expected: PASS.
Run: `swift test 2>&1 | tail -5` — Expected: no new failures (existing callers use default params; `ToolExecutor.createSkill`/`updateSkill`/`deleteSkill` and `JourneyManager` compile against the changed `SkillInfo` — fix any missing-argument errors by adding the `skillFilePath` argument where `SkillInfo` is constructed).

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/SkillManager.swift Tests/irisTests/SkillManagerPluginTests.swift
git commit -m "feat: surface plugin skills and rules through SkillManager"
```

---

### Task 10: Startup wiring

**Files:**
- Modify: `Sources/iris/iris.swift` (line 78 area)
- Modify: `Sources/iris/AppState.swift` (line 1180 area)

**Interfaces:**
- Consumes: `PluginManager.shared.loadAll()` / `.mcpConfigs()` (Task 7), `MCPManager.shared.setPluginConfigs(_:)` (Task 8).
- Produces: plugins load at app start and on MCP reload; no new API.

- [ ] **Step 1: Wire startup**

In `Sources/iris/iris.swift`, replace line 78 (`await MCPManager.shared.startServers()`) with:

```swift
        await PluginManager.shared.loadAll()
        await MCPManager.shared.setPluginConfigs(PluginManager.shared.mcpConfigs())
        await MCPManager.shared.startServers()
```

Note: `PluginManager.shared.mcpConfigs()` is an actor method — the call is `await PluginManager.shared.mcpConfigs()`; write it as:

```swift
        await PluginManager.shared.loadAll()
        let pluginConfigs = await PluginManager.shared.mcpConfigs()
        await MCPManager.shared.setPluginConfigs(pluginConfigs)
        await MCPManager.shared.startServers()
```

In `Sources/iris/AppState.swift` around line 1180, before `await MCPManager.shared.reloadServers()`, add the same two lines (`loadAll` + `setPluginConfigs`).

- [ ] **Step 2: Build and verify manually**

Run: `swift build 2>&1 | tail -3` — Expected: `Build complete!`

Manual check: `swift run iris` — app launches; with no `~/.iris/plugins/` content, behavior is unchanged; existing `mcp_servers.json` servers still connect (check the log line `MCP Server <name> connected`).

- [ ] **Step 3: Commit**

```bash
git add Sources/iris/iris.swift Sources/iris/AppState.swift
git commit -m "feat: load plugins and feed MCPManager at startup and reload"
```

---

## Phase 2 — Install flows and UI

### Task 11: PluginInstaller — staged install and uninstall

**Files:**
- Create: `Sources/iris/PluginInstaller.swift`
- Test: `Tests/irisTests/PluginInstallerTests.swift`

**Interfaces:**
- Consumes: `IPFManifest.parse` (Task 1), `PluginStateStore` (Task 2), `KeychainManager` service APIs (Task 3), `MCPManager.stopServers(withPrefix:)` (Task 8).
- Produces:

```swift
struct PluginDraft: Sendable {
    var manifest: IPFManifest
    var files: [String: Data]            // relative path -> content, includes "plugin.md"
    var secretValues: [String: String]   // collected by wizard, headed to Keychain
    var configValues: [String: String]
    var source: String
}
struct PluginInstaller: Sendable {
    let paths: IrisPaths
    func stage(directory: URL, source: String) throws -> PluginDraft   // local-dir flow: reads + validates, does not install
    func commit(_ draft: PluginDraft) throws                           // atomic: temp dir -> validate -> move; then Keychain + state
    func uninstall(id: String) async throws                            // stop servers, delete dir, delete Keychain service, drop state
}
```

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/PluginInstallerTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

@Suite("Plugin Installer Tests", .serialized)
struct PluginInstallerTests {
    func tempPaths() throws -> IrisPaths {
        let paths = IrisPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-installer-\(UUID().uuidString)"))
        try paths.ensureDirectories()
        return paths
    }

    func sourceDir(manifest: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-src-\(UUID().uuidString)/neat-plug")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(to: dir.appendingPathComponent("plugin.md"), atomically: true, encoding: .utf8)
        try #"{ "s": { "command": "/bin/echo", "args": [] } }"#
            .write(to: dir.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
        return dir
    }

    let manifest = """
    ---
    ipf: "1.0"
    id: neat-plug
    name: Neat Plug
    version: 2.0.0
    components:
      mcp: mcp.json
    secrets:
      - key: API_KEY
        required: true
    ---
    Docs.
    """

    @Test("stage reads a local directory into a draft without installing")
    func stage() throws {
        let paths = try tempPaths()
        let src = try sourceDir(manifest: manifest)
        let draft = try PluginInstaller(paths: paths).stage(directory: src, source: "local")
        #expect(draft.manifest.id == "neat-plug")
        #expect(draft.files.keys.contains("plugin.md"))
        #expect(draft.files.keys.contains("mcp.json"))
        #expect(!FileManager.default.fileExists(atPath: paths.pluginsDir.appendingPathComponent("neat-plug").path))
    }

    @Test("commit installs atomically: directory, keychain, state")
    func commit() throws {
        let paths = try tempPaths()
        let src = try sourceDir(manifest: manifest)
        var draft = try PluginInstaller(paths: paths).stage(directory: src, source: "local")
        draft.secretValues["API_KEY"] = "sk-123"
        try PluginInstaller(paths: paths).commit(draft)

        let installed = paths.pluginsDir.appendingPathComponent("neat-plug")
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("plugin.md").path))
        #expect(KeychainManager.shared.secrets(service: "iris.plugin.neat-plug")["API_KEY"] == "sk-123")
        let state = PluginStateStore(paths: paths).load()["neat-plug"]
        #expect(state?.source == "local")
        #expect(state?.installedVersion == "2.0.0")
        KeychainManager.shared.deleteSecrets(service: "iris.plugin.neat-plug")
    }

    @Test("uninstall removes directory, keychain service, and state")
    func uninstall() async throws {
        let paths = try tempPaths()
        let src = try sourceDir(manifest: manifest)
        var draft = try PluginInstaller(paths: paths).stage(directory: src, source: "local")
        draft.secretValues["API_KEY"] = "sk-123"
        let installer = PluginInstaller(paths: paths)
        try installer.commit(draft)
        try await installer.uninstall(id: "neat-plug")

        #expect(!FileManager.default.fileExists(atPath: paths.pluginsDir.appendingPathComponent("neat-plug").path))
        #expect(KeychainManager.shared.secrets(service: "iris.plugin.neat-plug").isEmpty)
        #expect(PluginStateStore(paths: paths).load()["neat-plug"] == nil)
    }

    @Test("commit of an invalid draft leaves no trace")
    func atomicity() throws {
        let paths = try tempPaths()
        let src = try sourceDir(manifest: manifest)
        var draft = try PluginInstaller(paths: paths).stage(directory: src, source: "local")
        draft.files["plugin.md"] = Data("garbage".utf8)   // corrupt it post-stage
        #expect(throws: (any Error).self) {
            try PluginInstaller(paths: paths).commit(draft)
        }
        #expect(!FileManager.default.fileExists(atPath: paths.pluginsDir.appendingPathComponent("neat-plug").path))
        #expect(PluginStateStore(paths: paths).load()["neat-plug"] == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginInstallerTests 2>&1 | tail -5`
Expected: compile FAILURE.

- [ ] **Step 3: Implement**

Create `Sources/iris/PluginInstaller.swift`:

```swift
import Foundation

/// A fully-specified pending install. Secrets ride in memory only; `commit` moves them to
/// the Keychain and never writes them into the plugin directory.
struct PluginDraft: Sendable {
    var manifest: IPFManifest
    var files: [String: Data]
    var secretValues: [String: String] = [:]
    var configValues: [String: String] = [:]
    var source: String
}

/// The one install/uninstall primitive every flow converges on. All writes are staged into a
/// temp directory and validated before anything lands in `~/.iris/plugins/` — cancel or
/// failure at any point leaves no trace.
struct PluginInstaller: Sendable {
    let paths: IrisPaths

    /// Local-directory flow: read every regular file into a draft and validate the manifest.
    func stage(directory: URL, source: String) throws -> PluginDraft {
        let fm = FileManager.default
        let manifestURL = directory.appendingPathComponent("plugin.md")
        let content = try String(contentsOf: manifestURL, encoding: .utf8)
        let manifest = try IPFManifest.parse(markdown: content, directoryName: directory.lastPathComponent)

        var files: [String: Data] = [:]
        let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            files[relative] = try Data(contentsOf: url)
        }
        return PluginDraft(manifest: manifest, files: files, source: source)
    }

    func commit(_ draft: PluginDraft) throws {
        let fm = FileManager.default
        let id = draft.manifest.id

        // Stage into a temp dir and re-validate what will actually land on disk.
        let staging = fm.temporaryDirectory.appendingPathComponent("iris-staging-\(UUID().uuidString)/\(id)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }

        for (relative, data) in draft.files {
            let target = staging.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        }
        let written = try String(contentsOf: staging.appendingPathComponent("plugin.md"), encoding: .utf8)
        _ = try IPFManifest.parse(markdown: written, directoryName: id)

        // Move into place (replace an existing install of the same id).
        let destination = paths.pluginsDir.appendingPathComponent(id)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: staging, to: destination)

        // Only after the directory landed: secrets to Keychain, state to plugins.json.
        if !draft.secretValues.isEmpty {
            let service = KeychainManager.pluginService(id)
            var existing = KeychainManager.shared.secrets(service: service)
            existing.merge(draft.secretValues) { _, new in new }
            KeychainManager.shared.saveSecrets(existing, service: service)
        }
        let store = PluginStateStore(paths: paths)
        var states = store.load()
        var state = states[id] ?? PluginState()
        state.source = draft.source
        state.installedVersion = draft.manifest.version
        state.configValues.merge(draft.configValues) { _, new in new }
        states[id] = state
        store.save(states)
    }

    /// Stop the plugin's servers, delete its directory, Keychain service, and state entry.
    /// External auth credential stores (e.g. nlm's cookie directory) belong to the tool and
    /// are deliberately left alone.
    func uninstall(id: String) async throws {
        await MCPManager.shared.stopServers(withPrefix: "\(id).")
        let dir = paths.pluginsDir.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        KeychainManager.shared.deleteSecrets(service: KeychainManager.pluginService(id))
        let store = PluginStateStore(paths: paths)
        var states = store.load()
        states[id] = nil
        store.save(states)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PluginInstallerTests 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/PluginInstaller.swift Tests/irisTests/PluginInstallerTests.swift
git commit -m "feat: staged atomic plugin install and uninstall"
```

---

### Task 12: Wrap-and-lift — snippet to plugin draft

**Files:**
- Modify: `Sources/iris/PluginInstaller.swift`
- Test: `Tests/irisTests/SnippetLiftTests.swift`

**Interfaces:**
- Consumes: `PluginDraft`, `IPFManifest` (Tasks 1, 11).
- Produces (static members on `PluginInstaller`):

```swift
struct LiftedEnv: Sendable, Equatable {
    var secrets: [String: String]   // env key -> literal value, headed to Keychain
    var config: [String: String]    // env key -> literal value, stays plain
}
static func isSecretLooking(key: String) -> Bool
static func classifyEnv(_ env: [String: String]) -> LiftedEnv
static func draft(fromSnippet json: String) throws -> PluginDraft   // throws IPFError.yamlError(...) on bad JSON
```

`draft(fromSnippet:)` accepts either `{"mcpServers": {...}}` or a bare `{"name": {"command": ...}}` object; plugin id derives from the first server name (lowercased, non-`[a-z0-9]` runs collapsed to `-`); generated `mcp.json` replaces lifted env values with `${keychain:KEY}` / `${config:KEY}` refs; generated `plugin.md` declares them.

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/SnippetLiftTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

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

    @Test("invalid JSON throws")
    func invalidJSON() {
        #expect(throws: (any Error).self) {
            _ = try PluginInstaller.draft(fromSnippet: "not json")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SnippetLiftTests 2>&1 | tail -5`
Expected: compile FAILURE.

- [ ] **Step 3: Implement**

Append to `Sources/iris/PluginInstaller.swift`:

```swift
// MARK: - Wrap-and-lift (snippet -> plugin draft)

struct LiftedEnv: Sendable, Equatable {
    var secrets: [String: String] = [:]
    var config: [String: String] = [:]
}

extension PluginInstaller {
    private static let secretMarkers = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "COOKIE", "CREDENTIAL"]

    /// Heuristic pre-classification; the wizard shows the result for user confirmation and
    /// lets them re-tag any field before commit.
    static func isSecretLooking(key: String) -> Bool {
        let upper = key.uppercased()
        return secretMarkers.contains { upper.contains($0) }
    }

    static func classifyEnv(_ env: [String: String]) -> LiftedEnv {
        var lifted = LiftedEnv()
        for (key, value) in env {
            if isSecretLooking(key: key) {
                lifted.secrets[key] = value
            } else {
                lifted.config[key] = value
            }
        }
        return lifted
    }

    /// Builds a single-server plugin draft from a standard `mcpServers` JSON snippet (or a
    /// bare `{name: {command,...}}` object). Literal env values are lifted into declarations;
    /// the generated mcp.json carries only `${...}` references.
    static func draft(fromSnippet json: String) throws -> PluginDraft {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IPFError.yamlError("Snippet is not valid JSON")
        }
        let serverDict = (raw["mcpServers"] as? [String: Any]) ?? raw
        guard let (serverName, serverAny) = serverDict.first,
              let server = serverAny as? [String: Any],
              let command = server["command"] as? String else {
            throw IPFError.yamlError("Snippet has no server with a command")
        }
        let args = (server["args"] as? [String]) ?? []
        let env = (server["env"] as? [String: String]) ?? [:]
        let lifted = classifyEnv(env)

        let id = serverName.lowercased()
            .replacing(/[^a-z0-9]+/, with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        var refEnv: [String: String] = [:]
        for key in lifted.secrets.keys { refEnv[key] = "${keychain:\(key)}" }
        for key in lifted.config.keys { refEnv[key] = "${config:\(key)}" }

        let mcpConfig = [serverName: MCPServerConfig(command: command, args: args,
                                                     env: refEnv.isEmpty ? nil : refEnv)]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let mcpData = try encoder.encode(mcpConfig)

        let binaryName = (command as NSString).lastPathComponent
        var yaml = """
        ---
        ipf: "1.0"
        id: \(id)
        name: \(serverName)
        version: 0.1.0
        description: Wrapped MCP server \(serverName).
        components:
          mcp: mcp.json
        requires:
          binaries:
            - name: \(binaryName)
        """
        if !lifted.config.isEmpty {
            yaml += "\nconfig:"
            for key in lifted.config.keys.sorted() {
                yaml += "\n  - key: \(key)"
            }
        }
        if !lifted.secrets.isEmpty {
            yaml += "\nsecrets:"
            for key in lifted.secrets.keys.sorted() {
                yaml += "\n  - key: \(key)\n    required: true"
            }
        }
        yaml += "\n---\n\n# \(serverName)\n\nGenerated by Iris from an MCP snippet.\n"

        var pluginDraft = PluginDraft(
            manifest: try IPFManifest.parse(markdown: yaml, directoryName: id),
            files: ["plugin.md": Data(yaml.utf8), "mcp.json": mcpData],
            source: "snippet")
        pluginDraft.secretValues = lifted.secrets
        pluginDraft.configValues = lifted.config
        return pluginDraft
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SnippetLiftTests 2>&1 | tail -5`
Expected: PASS. (If the `DATABASE_URL` classification case fails: the expectation is `false` — URL is not in the marker list by design; connection strings are caught when the user marks them in the wizard.)

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/PluginInstaller.swift Tests/irisTests/SnippetLiftTests.swift
git commit -m "feat: wrap-and-lift snippet import with secret classification"
```

---

### Task 13: Harness config importer

**Files:**
- Create: `Sources/iris/HarnessConfigImporter.swift`
- Create: `Tests/irisTests/Fixtures/harness-configs/claude_desktop_config.json`, `Tests/irisTests/Fixtures/harness-configs/cursor_mcp.json`, `Tests/irisTests/Fixtures/harness-configs/gemini_settings.json`
- Test: `Tests/irisTests/HarnessConfigImporterTests.swift`

**Interfaces:**
- Consumes: `MCPServerConfig` (existing).
- Produces:

```swift
struct HarnessConfigImporter {
    struct DetectedHarness: Sendable, Equatable { let name: String; let configPath: URL }
    static let knownLocations: [(name: String, relativePath: String)]   // relative to home
    static func detect(home: URL) -> [DetectedHarness]
    static func servers(at url: URL) throws -> [String: [String: Any]]  // server name -> raw dict (command/args/env), ready for PluginInstaller.draft
    static func snippetJSON(serverName: String, raw: [String: Any]) -> String  // re-wraps one server as {"mcpServers": {...}} for the wrap-and-lift pipeline
}
```

- [ ] **Step 1: Create the fixtures**

`Tests/irisTests/Fixtures/harness-configs/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "filesystem": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"] },
    "github": { "command": "github-mcp", "args": [], "env": { "GITHUB_TOKEN": "ghp_abc" } }
  }
}
```

`Tests/irisTests/Fixtures/harness-configs/cursor_mcp.json`:

```json
{ "mcpServers": { "postgres": { "command": "postgres-mcp", "args": ["--readonly"] } } }
```

`Tests/irisTests/Fixtures/harness-configs/gemini_settings.json` (server block nested among other settings):

```json
{
  "theme": "dark",
  "mcpServers": { "sqlite": { "command": "sqlite-mcp", "args": [] } },
  "otherSetting": true
}
```

Note: `Package.swift` already excludes `Fixtures` from compilation (`exclude: ["Fixtures"]`) — tests reference fixtures by `#filePath`-relative URL (see test code).

- [ ] **Step 2: Write the failing tests**

Create `Tests/irisTests/HarnessConfigImporterTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

@Suite("Harness Config Importer Tests")
struct HarnessConfigImporterTests {
    func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/harness-configs/\(name)")
    }

    @Test("parses servers out of each harness format", arguments: [
        ("claude_desktop_config.json", 2), ("cursor_mcp.json", 1), ("gemini_settings.json", 1)
    ])
    func parses(file: String, count: Int) throws {
        let servers = try HarnessConfigImporter.servers(at: fixture(file))
        #expect(servers.count == count)
    }

    @Test("parsed server carries command, args, env")
    func fields() throws {
        let servers = try HarnessConfigImporter.servers(at: fixture("claude_desktop_config.json"))
        let github = try #require(servers["github"])
        #expect(github["command"] as? String == "github-mcp")
        #expect((github["env"] as? [String: String])?["GITHUB_TOKEN"] == "ghp_abc")
    }

    @Test("snippetJSON round-trips through the wrap-and-lift pipeline")
    func roundTrip() throws {
        let servers = try HarnessConfigImporter.servers(at: fixture("claude_desktop_config.json"))
        let json = HarnessConfigImporter.snippetJSON(serverName: "github", raw: servers["github"]!)
        let draft = try PluginInstaller.draft(fromSnippet: json)
        #expect(draft.manifest.id == "github")
        #expect(draft.secretValues["GITHUB_TOKEN"] == "ghp_abc")
    }

    @Test("detect only lists configs that exist")
    func detect() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-home-\(UUID().uuidString)")
        let cursorDir = home.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
        try #"{ "mcpServers": {} }"#.write(to: cursorDir.appendingPathComponent("mcp.json"),
                                           atomically: true, encoding: .utf8)
        let detected = HarnessConfigImporter.detect(home: home)
        #expect(detected.map(\.name) == ["Cursor"])
    }

    @Test("known locations cover the major harnesses")
    func coverage() {
        let names = HarnessConfigImporter.knownLocations.map(\.name)
        for expected in ["Claude Desktop", "Claude Code", "Cursor", "Windsurf", "Gemini CLI", "VS Code Copilot"] {
            #expect(names.contains(expected))
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter HarnessConfigImporterTests 2>&1 | tail -5`
Expected: compile FAILURE.

- [ ] **Step 4: Implement**

Create `Sources/iris/HarnessConfigImporter.swift`:

```swift
import Foundation

/// Read-only import of MCP server definitions from other harnesses' config files. Every
/// major harness stores the same `mcpServers` JSON shape; only the file location differs.
/// Iris never edits these files.
struct HarnessConfigImporter {
    struct DetectedHarness: Sendable, Equatable {
        let name: String
        let configPath: URL
    }

    static let knownLocations: [(name: String, relativePath: String)] = [
        ("Claude Desktop", "Library/Application Support/Claude/claude_desktop_config.json"),
        ("Claude Code", ".claude.json"),
        ("Cursor", ".cursor/mcp.json"),
        ("Windsurf", ".codeium/windsurf/mcp_config.json"),
        ("Gemini CLI", ".gemini/settings.json"),
        ("VS Code Copilot", "Library/Application Support/Code/User/mcp.json"),
    ]

    static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [DetectedHarness] {
        knownLocations.compactMap { name, relative in
            let url = home.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return DetectedHarness(name: name, configPath: url)
        }
    }

    /// Extracts the `mcpServers` object (top-level or nested among other settings) and
    /// returns each server's raw dict. Servers without a string `command` are skipped
    /// (remote/HTTP servers are out of scope in v1).
    static func servers(at url: URL) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IPFError.yamlError("\(url.lastPathComponent) is not a JSON object")
        }
        let dict = (root["mcpServers"] as? [String: Any]) ?? [:]
        var result: [String: [String: Any]] = [:]
        for (name, any) in dict {
            guard let server = any as? [String: Any], server["command"] is String else { continue }
            result[name] = server
        }
        return result
    }

    /// Re-wraps one parsed server as a standard snippet so it flows through
    /// `PluginInstaller.draft(fromSnippet:)` — one pipeline for all import sources.
    static func snippetJSON(serverName: String, raw: [String: Any]) -> String {
        let wrapper: [String: Any] = ["mcpServers": [serverName: raw]]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapper),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter HarnessConfigImporterTests 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/HarnessConfigImporter.swift Tests/irisTests/HarnessConfigImporterTests.swift Tests/irisTests/Fixtures/harness-configs
git commit -m "feat: cross-harness MCP config detection and import"
```

---

### Task 14: External auth runner

**Files:**
- Create: `Sources/iris/PluginAuthRunner.swift`
- Test: `Tests/irisTests/PluginAuthRunnerTests.swift`

**Interfaces:**
- Consumes: `PluginReferences.expand` (Task 4), `IPFManifest.AuthDeclaration` (Task 1), `ToolExecutor` (existing: `execute(name:args:cwd:conversationId:useSandbox:)`).
- Produces:

```swift
struct PluginAuthStatus: Sendable, Equatable { let signedIn: Bool; let output: String }
enum PluginAuthRunner {
    static func check(_ auth: IPFManifest.AuthDeclaration, config: [String: String]) async -> PluginAuthStatus
    static func runSetup(_ auth: IPFManifest.AuthDeclaration, config: [String: String]) async -> String
}
```

`check` runs `check_command` directly via `Process` (`/bin/sh -c`, 30 s timeout, exit 0 = signed in). `runSetup` routes through `ToolExecutor.execute(name: "run_command", ...)` with `useSandbox: false` so the command passes the existing Vibecop/permission gate and can open the user's browser.

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/PluginAuthRunnerTests.swift`:

```swift
import Testing
@testable import iris

@Suite("Plugin Auth Runner Tests")
struct PluginAuthRunnerTests {
    func auth(check: String) -> IPFManifest.AuthDeclaration {
        var a = try! YAMLAuthHelper.make(kind: "external")
        a.checkCommand = check
        return a
    }

    @Test("exit 0 means signed in")
    func signedIn() async {
        let status = await PluginAuthRunner.check(auth(check: "true"), config: [:])
        #expect(status.signedIn)
    }

    @Test("non-zero exit means signed out")
    func signedOut() async {
        let status = await PluginAuthRunner.check(auth(check: "false"), config: [:])
        #expect(!status.signedIn)
    }

    @Test("config refs expand in the command")
    func configExpansion() async {
        let status = await PluginAuthRunner.check(
            auth(check: "test \"${config:PROFILE}\" = work"), config: ["PROFILE": "work"])
        #expect(status.signedIn)
    }

    @Test("missing check command reports signed out with explanation")
    func missingCommand() async {
        var a = auth(check: "true")
        a.checkCommand = nil
        let status = await PluginAuthRunner.check(a, config: [:])
        #expect(!status.signedIn)
        #expect(status.output.contains("check_command"))
    }
}

/// Test-only helper: AuthDeclaration has no memberwise init exposed for `kind` alone.
enum YAMLAuthHelper {
    static func make(kind: String) throws -> IPFManifest.AuthDeclaration {
        let m = try IPFManifest.parse(
            markdown: "---\nipf: \"1.0\"\nid: t\nname: T\nversion: 1.0.0\nauth:\n  - kind: \(kind)\n---\n",
            directoryName: "t")
        return m.auth![0]
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginAuthRunnerTests 2>&1 | tail -5`
Expected: compile FAILURE.

- [ ] **Step 3: Implement**

Create `Sources/iris/PluginAuthRunner.swift`:

```swift
import Foundation

struct PluginAuthStatus: Sendable, Equatable {
    let signedIn: Bool
    let output: String
}

/// Orchestrates `kind: external` auth declared in a plugin manifest. Iris never stores these
/// credentials — the tool owns them. `check` is a quick, direct status probe; `runSetup`
/// goes through run_command so it passes the same Vibecop/permission gate as any command.
enum PluginAuthRunner {
    static func check(_ auth: IPFManifest.AuthDeclaration, config: [String: String]) async -> PluginAuthStatus {
        guard let raw = auth.checkCommand,
              let command = try? PluginReferences.expand(raw, config: config, secrets: [:]) else {
            return PluginAuthStatus(signedIn: false, output: "No check_command declared or reference unresolvable")
        }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let timeout = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)

            process.terminationHandler = { p in
                timeout.cancel()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: PluginAuthStatus(
                    signedIn: p.terminationStatus == 0, output: output))
            }
            do {
                try process.run()
            } catch {
                timeout.cancel()
                continuation.resume(returning: PluginAuthStatus(
                    signedIn: false, output: "Failed to run check: \(error)"))
            }
        }
    }

    static func runSetup(_ auth: IPFManifest.AuthDeclaration, config: [String: String]) async -> String {
        guard let raw = auth.setupCommand,
              let command = try? PluginReferences.expand(raw, config: config, secrets: [:]) else {
            return "No setup_command declared or reference unresolvable"
        }
        return await ToolExecutor().execute(
            name: "run_command",
            args: ["command": .string(command)],
            useSandbox: false)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PluginAuthRunnerTests 2>&1 | tail -5`
Expected: PASS. (If `JSONValue`'s `.string` case has a different spelling, check `Models.swift` for the `JSONValue` enum and use its actual string case.)

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/PluginAuthRunner.swift Tests/irisTests/PluginAuthRunnerTests.swift
git commit -m "feat: external auth check/setup runner for plugins"
```

---

### Task 15: Plugins Settings tab

**Files:**
- Create: `Sources/iris/PluginsSettingsView.swift`
- Modify: `Sources/iris/SettingsView.swift` (add `.tabItem` after the Sandboxing tab, before line 760's tab)

**Interfaces:**
- Consumes: `PluginManager.shared` (plugins/setEnabled/setConfigValue/loadAll/mcpConfigs), `MCPManager.shared` (serverStatuses/setPluginConfigs/reloadServers/stopServers(withPrefix:)), `KeychainManager` service APIs, `PluginAuthRunner`, `PluginInstaller.uninstall`, `MarkdownUI` (existing dependency).
- Produces: `struct PluginsSettingsView: View`. Wizard presentation hook: `@State private var showInstallWizard: InstallWizardSource?` where `enum InstallWizardSource: Identifiable { case folder(URL); case snippet; case harnessImport }` — the sheet itself lands in Task 16 (this task stubs it with `Text("Install wizard")`).

- [ ] **Step 1: Implement the view**

Create `Sources/iris/PluginsSettingsView.swift`:

```swift
import SwiftUI
import MarkdownUI

enum InstallWizardSource: Identifiable {
    case folder(URL)
    case snippet
    case harnessImport

    var id: String {
        switch self {
        case .folder(let url): return "folder:\(url.path)"
        case .snippet: return "snippet"
        case .harnessImport: return "import"
        }
    }
}

struct PluginsSettingsView: View {
    @State private var plugins: [LoadedPlugin] = []
    @State private var serverStatuses: [String: MCPManager.ServerStatus] = [:]
    @State private var selectedID: String?
    @State private var showInstallWizard: InstallWizardSource?
    @State private var confirmUninstallID: String?

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 230, maxWidth: 300)
            detailPane
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await refresh() }
        .sheet(item: $showInstallWizard) { source in
            PluginInstallWizardView(source: source) {
                Task { await refresh() }
            }
        }
    }

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selectedID) {
                Section("Plugins") {
                    ForEach(plugins, id: \.manifest.id) { plugin in
                        HStack {
                            statusLED(for: plugin)
                            VStack(alignment: .leading) {
                                Text(plugin.manifest.name).fontWeight(.medium)
                                Text(subtitle(for: plugin)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { plugin.state.enabled },
                                set: { enabled in
                                    Task {
                                        await PluginManager.shared.setEnabled(plugin.manifest.id, enabled: enabled)
                                        await reloadMCP()
                                        await refresh()
                                    }
                                }
                            )).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                        .tag(plugin.manifest.id)
                    }
                }
                Section("Configured in file") {
                    ForEach(legacyServerNames, id: \.self) { name in
                        HStack {
                            Circle().fill(legacyColor(name)).frame(width: 8, height: 8)
                            Text(name)
                            Spacer()
                        }
                    }
                    Button("Edit mcp_servers.json") {
                        NSWorkspace.shared.open(IrisPaths.default.mcpServersJSON)
                    }.buttonStyle(.link)
                }
            }
            Menu("＋ Add Plugin") {
                Button("From Folder…") { pickFolder() }
                Button("From MCP Snippet…") { showInstallWizard = .snippet }
                Button("Import from Another Harness…") { showInstallWizard = .harnessImport }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let plugin = plugins.first(where: { $0.manifest.id == selectedID }) {
            PluginDetailView(plugin: plugin, serverStatuses: serverStatuses) {
                Task { await refresh() }
            }
        } else {
            Text("Select a plugin").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func statusLED(for plugin: LoadedPlugin) -> some View {
        let color: Color
        switch plugin.status {
        case .ok: color = .green
        case .needsConfig: color = .orange
        case .failed: color = .red
        case .disabled: color = .gray
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private func subtitle(for plugin: LoadedPlugin) -> String {
        switch plugin.status {
        case .ok: return plugin.manifest.version
        case .needsConfig(let reason): return reason
        case .failed(let reason): return reason
        case .disabled: return "disabled"
        }
    }

    private var legacyServerNames: [String] {
        serverStatuses.keys.filter { !$0.contains(".") }.sorted()
    }

    private func legacyColor(_ name: String) -> Color {
        if case .running = serverStatuses[name] { return .green }
        return .red
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            showInstallWizard = .folder(url)
        }
    }

    private func refresh() async {
        plugins = await PluginManager.shared.plugins()
        serverStatuses = await MCPManager.shared.serverStatuses()
        if selectedID == nil { selectedID = plugins.first?.manifest.id }
    }

    private func reloadMCP() async {
        let configs = await PluginManager.shared.mcpConfigs()
        await MCPManager.shared.setPluginConfigs(configs)
        await MCPManager.shared.reloadServers()
    }
}

struct PluginDetailView: View {
    let plugin: LoadedPlugin
    let serverStatuses: [String: MCPManager.ServerStatus]
    let onChange: () -> Void

    @State private var secretDrafts: [String: String] = [:]
    @State private var configDrafts: [String: String] = [:]
    @State private var authStatuses: [Int: PluginAuthStatus] = [:]
    @State private var confirmingUninstall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if plugin.manifest.config?.isEmpty == false || plugin.manifest.secrets?.isEmpty == false
                    || plugin.manifest.auth?.isEmpty == false {
                    configurationCard
                }
                serversCard
                footer
                if !plugin.manifest.markdownBody.isEmpty {
                    Divider()
                    Markdown(plugin.manifest.markdownBody).textSelection(.enabled)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: plugin.manifest.id) { await loadDrafts() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(plugin.manifest.name).font(.title2).bold()
            Text([plugin.manifest.version, plugin.manifest.author, plugin.state.source]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if let homepage = plugin.manifest.homepage, let url = URL(string: homepage) {
                Link(homepage, destination: url).font(.caption)
            }
        }
    }

    private var configurationCard: some View {
        GroupBox("Configuration") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plugin.manifest.config ?? [], id: \.key) { field in
                    HStack {
                        Text(field.label ?? field.key).frame(width: 160, alignment: .trailing)
                        TextField(field.help ?? "", text: Binding(
                            get: { configDrafts[field.key] ?? "" },
                            set: { configDrafts[field.key] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveConfig(field.key) }
                    }
                }
                ForEach(plugin.manifest.secrets ?? [], id: \.key) { field in
                    HStack {
                        Text(field.label ?? field.key).frame(width: 160, alignment: .trailing)
                        SecureField("stored in Keychain", text: Binding(
                            get: { secretDrafts[field.key] ?? "" },
                            set: { secretDrafts[field.key] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveSecret(field.key) }
                    }
                }
                ForEach(Array((plugin.manifest.auth ?? []).enumerated()), id: \.offset) { index, auth in
                    HStack {
                        Text(auth.label ?? "Account").frame(width: 160, alignment: .trailing)
                        if authStatuses[index]?.signedIn == true {
                            Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label("Sign in required", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        }
                        Button("Sign In") { runSetup(index: index, auth: auth) }
                    }
                }
            }
            .padding(6)
        }
    }

    private var serversCard: some View {
        GroupBox("Servers & Tools") {
            VStack(alignment: .leading, spacing: 6) {
                let prefix = "\(plugin.manifest.id)."
                let mine = serverStatuses.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
                if mine.isEmpty {
                    Text("No servers running").foregroundStyle(.secondary)
                }
                ForEach(mine, id: \.key) { name, status in
                    HStack {
                        switch status {
                        case .running(let count):
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text("\(name.dropFirst(prefix.count)) — running · \(count) tools")
                        case .failed(let reason):
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                            Text("\(name.dropFirst(prefix.count)) — \(reason)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    private var footer: some View {
        HStack {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([plugin.directory])
            }
            Spacer()
            Button("Uninstall…", role: .destructive) { confirmingUninstall = true }
                .confirmationDialog(
                    "Uninstall \(plugin.manifest.name)? Its Keychain secrets are deleted. Credentials owned by external tools (e.g. nlm) are left alone.",
                    isPresented: $confirmingUninstall) {
                    Button("Uninstall", role: .destructive) {
                        Task {
                            try? await PluginInstaller(paths: .default).uninstall(id: plugin.manifest.id)
                            await PluginManager.shared.loadAll()
                            onChange()
                        }
                    }
                }
        }
    }

    private func loadDrafts() async {
        configDrafts = plugin.state.configValues
        let secrets = KeychainManager.shared.secrets(service: KeychainManager.pluginService(plugin.manifest.id))
        secretDrafts = secrets
        for (index, auth) in (plugin.manifest.auth ?? []).enumerated() {
            authStatuses[index] = await PluginAuthRunner.check(auth, config: configDrafts)
        }
    }

    private func saveConfig(_ key: String) {
        Task {
            await PluginManager.shared.setConfigValue(plugin.manifest.id, key: key, value: configDrafts[key] ?? "")
            onChange()
        }
    }

    private func saveSecret(_ key: String) {
        let service = KeychainManager.pluginService(plugin.manifest.id)
        var secrets = KeychainManager.shared.secrets(service: service)
        secrets[key] = secretDrafts[key]
        KeychainManager.shared.saveSecrets(secrets, service: service)
        Task {
            await PluginManager.shared.loadAll()
            onChange()
        }
    }

    private func runSetup(index: Int, auth: IPFManifest.AuthDeclaration) {
        Task {
            _ = await PluginAuthRunner.runSetup(auth, config: configDrafts)
            authStatuses[index] = await PluginAuthRunner.check(auth, config: configDrafts)
        }
    }
}
```

Add a temporary stub at the bottom (replaced in Task 16):

```swift
struct PluginInstallWizardView: View {
    let source: InstallWizardSource
    let onComplete: () -> Void
    var body: some View { Text("Install wizard").frame(width: 400, height: 200) }
}
```

- [ ] **Step 2: Add the tab**

In `Sources/iris/SettingsView.swift`, after the Sandboxing tab's `.tabItem` block (ends near line 760), insert:

```swift
            PluginsSettingsView()
            .tabItem {
                Label("Plugins", systemImage: "puzzlepiece.extension")
            }
```

- [ ] **Step 3: Build and verify manually**

Run: `swift build 2>&1 | tail -3` — Expected: `Build complete!`

Manual: `swift run iris` → Settings → Plugins tab. Verify: empty state renders; installing a test plugin by hand (`mkdir -p ~/.iris/plugins/test-plug` + minimal `plugin.md`) then relaunching shows it in the list with a status LED; the enable toggle flips and persists; legacy `mcp_servers.json` servers appear in the "Configured in file" group.

- [ ] **Step 4: Commit**

```bash
git add Sources/iris/PluginsSettingsView.swift Sources/iris/SettingsView.swift
git commit -m "feat: Plugins settings tab with list, detail, and status LEDs"
```

---

### Task 16: Install wizard sheet

**Files:**
- Create: `Sources/iris/PluginInstallWizardView.swift`
- Modify: `Sources/iris/PluginsSettingsView.swift` (delete the Task 15 stub)

**Interfaces:**
- Consumes: `PluginInstaller` (stage/draft/commit, Tasks 11–12), `HarnessConfigImporter` (Task 13), `BinaryResolver` (Task 5), `PluginAuthRunner` (Task 14), `InstallWizardSource` (Task 15).
- Produces: `struct PluginInstallWizardView: View { let source: InstallWizardSource; let onComplete: () -> Void }` — a sheet walking validate → binaries → configuration → confirm; nothing written before the final confirm (`PluginInstaller.commit` is the only write).

- [ ] **Step 1: Implement**

Delete the `PluginInstallWizardView` stub from `Sources/iris/PluginsSettingsView.swift`, then create `Sources/iris/PluginInstallWizardView.swift`:

```swift
import SwiftUI

/// Install wizard sheet. Builds a PluginDraft from the chosen source, walks the user through
/// binary checks and configuration, and only writes anything on the final Install click
/// (PluginInstaller.commit). Cancel at any step leaves no trace.
struct PluginInstallWizardView: View {
    let source: InstallWizardSource
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var draft: PluginDraft?
    @State private var loadError: String?
    @State private var snippetText = ""
    @State private var detectedHarnesses: [HarnessConfigImporter.DetectedHarness] = []
    @State private var selectedHarness: HarnessConfigImporter.DetectedHarness?
    @State private var harnessServers: [String: [String: Any]] = [:]
    @State private var selectedServer: String?
    @State private var secretKeys: Set<String> = []      // wizard-adjustable classification
    @State private var installing = false

    private let steps = ["Source", "Binaries", "Configuration", "Confirm"]

    var body: some View {
        HStack(spacing: 0) {
            stepRail
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                content
                Spacer()
                buttons
            }
            .padding(20)
            .frame(width: 460, alignment: .topLeading)
        }
        .frame(height: 400)
        .task { await prepare() }
    }

    private var stepRail: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft?.manifest.name ?? "Install Plugin").font(.title3).bold()
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(index < step ? Color.green : (index == step ? Color.accentColor : Color.gray.opacity(0.4)))
                            .frame(width: 20, height: 20)
                        if index < step {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    Text(title).fontWeight(index == step ? .bold : .regular)
                }
            }
            Spacer()
        }
        .padding(18)
        .frame(width: 180, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: sourceStep
        case 1: binariesStep
        case 2: configurationStep
        default: confirmStep
        }
    }

    @ViewBuilder
    private var sourceStep: some View {
        if let loadError {
            Label(loadError, systemImage: "xmark.octagon").foregroundStyle(.red)
        } else {
            switch source {
            case .folder:
                if let draft {
                    Text("Validated **\(draft.manifest.name)** \(draft.manifest.version) — \(draft.files.count) files.")
                } else {
                    ProgressView("Validating…")
                }
            case .snippet:
                Text("Paste a standard `mcpServers` JSON snippet:")
                TextEditor(text: $snippetText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 180)
                    .border(Color.gray.opacity(0.3))
                Button("Parse Snippet") { parseSnippet() }
                    .disabled(snippetText.isEmpty)
            case .harnessImport:
                if detectedHarnesses.isEmpty {
                    Text("No known harness configs found on this Mac.")
                } else {
                    Picker("Harness", selection: $selectedHarness) {
                        Text("Choose…").tag(nil as HarnessConfigImporter.DetectedHarness?)
                        ForEach(detectedHarnesses, id: \.configPath) { harness in
                            Text(harness.name).tag(harness as HarnessConfigImporter.DetectedHarness?)
                        }
                    }
                    .onChange(of: selectedHarness) { _, harness in loadHarnessServers(harness) }
                    Picker("Server", selection: $selectedServer) {
                        Text("Choose…").tag(nil as String?)
                        ForEach(harnessServers.keys.sorted(), id: \.self) { Text($0).tag($0 as String?) }
                    }
                    .onChange(of: selectedServer) { _, server in importServer(server) }
                    Text("Iris reads this config; it never edits it.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var binariesStep: some View {
        if let draft {
            ForEach(draft.manifest.requires?.binaries ?? [], id: \.name) { binary in
                if let path = BinaryResolver.resolve(command: binary.name) {
                    Label("\(binary.name) — \(path)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("\(binary.name) not found", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        if let hint = binary.installHint {
                            HStack {
                                Text(hint).font(.system(.caption, design: .monospaced))
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(hint, forType: .string)
                                }.controlSize(.small)
                            }
                        }
                    }
                }
            }
            if (draft.manifest.requires?.binaries ?? []).isEmpty {
                Text("No binary requirements declared.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var configurationStep: some View {
        if draft != nil {
            Text("Secrets go to the Keychain; config stays plain. Re-tag anything the classifier got wrong.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(allEnvKeys, id: \.self) { key in
                HStack {
                    Text(key).font(.system(.caption, design: .monospaced)).frame(width: 150, alignment: .trailing)
                    if secretKeys.contains(key) {
                        SecureField("", text: valueBinding(key)).textFieldStyle(.roundedBorder)
                    } else {
                        TextField("", text: valueBinding(key)).textFieldStyle(.roundedBorder)
                    }
                    Picker("", selection: tagBinding(key)) {
                        Text("Secret → Keychain").tag(true)
                        Text("Config").tag(false)
                    }.frame(width: 160).labelsHidden()
                }
            }
            if allEnvKeys.isEmpty {
                Text("Nothing to configure.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var confirmStep: some View {
        if let draft {
            Text("Install **\(draft.manifest.name)** \(draft.manifest.version)?")
            Text("→ \(IrisPaths.default.pluginsDir.appendingPathComponent(draft.manifest.id).path)")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Text("\(secretKeys.count) secret(s) to Keychain · \(draft.configValues.count) config value(s) · nothing written until Install.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            if step < steps.count - 1 {
                Button("Next") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == nil)
            } else {
                Button(installing ? "Installing…" : "Install") { install() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == nil || installing)
            }
        }
    }

    // MARK: - Data plumbing

    private var allEnvKeys: [String] {
        guard let draft else { return [] }
        return (draft.secretValues.keys.map { $0 } + draft.configValues.keys.map { $0 }).sorted()
    }

    private func valueBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { draft?.secretValues[key] ?? draft?.configValues[key] ?? "" },
            set: { newValue in
                if secretKeys.contains(key) { draft?.secretValues[key] = newValue }
                else { draft?.configValues[key] = newValue }
            })
    }

    private func tagBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { secretKeys.contains(key) },
            set: { isSecret in
                guard var d = draft else { return }
                let value = d.secretValues[key] ?? d.configValues[key] ?? ""
                if isSecret {
                    secretKeys.insert(key)
                    d.secretValues[key] = value
                    d.configValues[key] = nil
                } else {
                    secretKeys.remove(key)
                    d.configValues[key] = value
                    d.secretValues[key] = nil
                }
                draft = d
            })
    }

    private func prepare() async {
        switch source {
        case .folder(let url):
            do {
                let staged = try PluginInstaller(paths: .default).stage(directory: url, source: "local")
                draft = staged
                secretKeys = Set(staged.secretValues.keys)
            } catch {
                loadError = String(describing: error)
            }
        case .snippet:
            break
        case .harnessImport:
            detectedHarnesses = HarnessConfigImporter.detect()
        }
    }

    private func parseSnippet() {
        do {
            let parsed = try PluginInstaller.draft(fromSnippet: snippetText)
            draft = parsed
            secretKeys = Set(parsed.secretValues.keys)
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }

    private func loadHarnessServers(_ harness: HarnessConfigImporter.DetectedHarness?) {
        guard let harness else { return }
        harnessServers = (try? HarnessConfigImporter.servers(at: harness.configPath)) ?? [:]
    }

    private func importServer(_ server: String?) {
        guard let server, let raw = harnessServers[server] else { return }
        parseSnippetJSON(HarnessConfigImporter.snippetJSON(serverName: server, raw: raw),
                         source: "import:\(selectedHarness?.name ?? "harness")")
    }

    private func parseSnippetJSON(_ json: String, source: String) {
        do {
            var parsed = try PluginInstaller.draft(fromSnippet: json)
            parsed.source = source
            draft = parsed
            secretKeys = Set(parsed.secretValues.keys)
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }

    private func install() {
        guard let draft else { return }
        installing = true
        Task {
            do {
                try PluginInstaller(paths: .default).commit(draft)
                await PluginManager.shared.loadAll()
                let configs = await PluginManager.shared.mcpConfigs()
                await MCPManager.shared.setPluginConfigs(configs)
                await MCPManager.shared.startServers()
                onComplete()
                dismiss()
            } catch {
                loadError = String(describing: error)
                installing = false
            }
        }
    }
}
```

Note: `DetectedHarness` must conform to `Hashable` for the `Picker` tag — add `Hashable` to its declaration in `HarnessConfigImporter.swift` (`struct DetectedHarness: Sendable, Equatable, Hashable`).

- [ ] **Step 2: Build and verify manually**

Run: `swift build 2>&1 | tail -3` — Expected: `Build complete!`

Manual, end-to-end with the motivating plugin (requires `uv tool install notebooklm-mcp-cli` on the machine):
1. Settings → Plugins → Add Plugin → From MCP Snippet…, paste `{"mcpServers": {"gemini-notebook": {"command": "notebooklm-mcp"}}}`.
2. Walk the wizard: binary check finds `notebooklm-mcp` (or shows the copyable hint), Install.
3. Plugin appears with a green LED once the server connects; its tools appear to the agent.
4. Uninstall from the detail pane; directory and state are gone.

- [ ] **Step 3: Run the full suite**

Run: `swift test 2>&1 | tail -5` — Expected: no failures.

- [ ] **Step 4: Commit**

```bash
git add Sources/iris/PluginInstallWizardView.swift Sources/iris/PluginsSettingsView.swift Sources/iris/HarnessConfigImporter.swift
git commit -m "feat: plugin install wizard with snippet, folder, and harness-import flows"
```

---

### Task 17: Legacy-file conveniences and per-plugin toggle

**Files:**
- Modify: `Sources/iris/PluginsSettingsView.swift`
- Modify: `Sources/iris/MCPManager.swift`

**Interfaces:**
- Consumes: `FileWatcher` (existing — see `Sources/iris/FileWatcher.swift` for its API before use), `HarnessConfigImporter.snippetJSON` (Task 13), `MCPManager.stopServers(withPrefix:)` / `startServers()` (Task 8), `InstallWizardSource` (Task 15).
- Produces: `InstallWizardSource` gains `case convertLegacy(name: String)`; `MCPManager` gains `func removeLegacyServer(named: String)` (edits `mcp_servers.json` — the one place Iris writes its own legacy file, only on explicit Convert).

- [ ] **Step 1: Per-plugin toggle must not restart unrelated servers**

In `PluginsSettingsView`, replace the toggle's `reloadMCP()` call chain with a targeted restart:

```swift
Task {
    await PluginManager.shared.setEnabled(plugin.manifest.id, enabled: enabled)
    await MCPManager.shared.stopServers(withPrefix: "\(plugin.manifest.id).")
    let configs = await PluginManager.shared.mcpConfigs()
    await MCPManager.shared.setPluginConfigs(configs)
    await MCPManager.shared.startServers()   // starts only servers not already running
    await refresh()
}
```

(`startServers()` already skips names present in `servers` — Task 8 made the loop `where servers[name] == nil` — so unrelated running servers are untouched.)

- [ ] **Step 2: Hot-reload the legacy group on file save**

In `PluginsSettingsView`, add a `FileWatcher` on `IrisPaths.default.mcpServersJSON` (match the existing `FileWatcher` usage pattern found in the codebase — check its initializer before writing this). On change: `await MCPManager.shared.reloadServers()` then `await refresh()`.

- [ ] **Step 3: Convert-to-plugin action**

(a) In `MCPManager`, add:

```swift
    /// Removes one server entry from mcp_servers.json. Only called by the explicit
    /// "Convert to plugin" flow — Iris never otherwise edits the hand-edited file.
    func removeLegacyServer(named name: String) {
        let url = URL(fileURLWithPath: configPath)
        guard let data = try? Data(contentsOf: url),
              var configs = try? JSONDecoder().decode([String: MCPServerConfig].self, from: data) else { return }
        configs[name] = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let out = try? encoder.encode(configs) {
            try? out.write(to: url, options: .atomic)
        }
    }
```

(b) In `PluginsSettingsView`'s legacy row, add a context menu:

```swift
.contextMenu {
    Button("Convert to Plugin…") { showInstallWizard = .convertLegacy(name: name) }
}
```

(c) Add `case convertLegacy(name: String)` to `InstallWizardSource` (id: `"convert:\(name)"`). In `PluginInstallWizardView.prepare()`, handle it by reading the legacy file via `HarnessConfigImporter.servers(at: IrisPaths.default.mcpServersJSON)`, then `parseSnippetJSON(HarnessConfigImporter.snippetJSON(serverName: name, raw: raw), source: "convert")`. In `install()`, when the source is `.convertLegacy(let name)`, after a successful `commit` also call `await MCPManager.shared.removeLegacyServer(named: name)` and `await MCPManager.shared.reloadServers()`.

- [ ] **Step 4: Build and verify manually**

Run: `swift build 2>&1 | tail -3` — Expected: `Build complete!`

Manual: add a server to `mcp_servers.json` while the Plugins tab is open → group updates on save. Right-click it → Convert to Plugin → wizard pre-filled; after install the entry is gone from the JSON and the plugin runs the same server (namespaced).

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/PluginsSettingsView.swift Sources/iris/PluginInstallWizardView.swift Sources/iris/MCPManager.swift
git commit -m "feat: legacy file hot-reload, convert-to-plugin, targeted per-plugin restart"
```

---

## Phase 3 — Docs

### Task 18: IPF spec-as-product docs

**Files:**
- Create: `docs/ipf/spec.md`, `docs/ipf/authoring.md`, `docs/ipf/CHANGELOG.md`
- Modify: `README.md` (add a Plugins subsection)

**Interfaces:** none (documentation).

- [ ] **Step 1: Write `docs/ipf/spec.md`**

Normative spec, IPF 1.0.0. Content requirements (write these as full prose, not placeholders — the design doc `docs/specs/2026-08-27-iris-plugin-system-design.md` sections "Iris Plugin Format (IPF)", "Manifest rules", "Configuration model", and "Skills component" contain the normative material to transcribe):

1. **Header:** `# Iris Plugin Format (IPF) Specification`, version `1.0.0`, status line, link to CHANGELOG.
2. **Directory layout** — the `plugin.md` / `mcp.json` / `skills/` / `rules/` tree with one-line roles.
3. **Manifest schema** — every field of `IPFManifest` (name, type, required?, constraints), exactly matching `Sources/iris/IPFManifest.swift`. Include the id rule (`^[a-z0-9]+(-[a-z0-9]+)*$`, ≤64, equals directory name) and the ipf-version acceptance rule (any 1.x; other majors refused).
4. **Reference syntax** — `${keychain:KEY}` / `${config:KEY}`, key charset, where each may appear, cross-validation rule (every keychain ref must be declared in `secrets`).
5. **Components** — `mcp` (standard `mcpServers` JSON, stdio only), `skills` (Agent Skills spec directories, link agentskills.io), `rules` (plain Markdown, each file appended to the system prompt). Unknown component keys: ignored with a warning.
6. **Configuration model** — the config/secrets/auth table from the design doc, including `kind: external` semantics (setup_command, check_command, exit-0 contract).
7. **Versioning policy** — IPF semver rules (patch/minor/major as defined in the design doc), and the manifest `version` field being informational in v1.

- [ ] **Step 2: Write `docs/ipf/authoring.md`**

Plugin-author guide with two complete worked examples, copied verbatim from the fixtures used in this plan: the simple API-key server manifest (Task 11's `neat-plug` shape, renamed sensibly) and the gemini-notebook external-auth manifest (from the design doc's IPF section). For each: full `plugin.md`, full `mcp.json`, and a "test your plugin" section (install From Folder with dev-mode, check the status LED, where errors appear).

- [ ] **Step 3: Write `docs/ipf/CHANGELOG.md`**

```markdown
# IPF Changelog

## 1.0.0 — 2026-08-27

Initial release: manifest schema (id/name/version/components/requires/config/secrets/auth),
`${keychain:}`/`${config:}` reference syntax, components mcp/skills/rules, external auth kind.
```

- [ ] **Step 4: Update `README.md`**

Add a `### Plugins` subsection under the Portable Memory & Skill System section: what a plugin bundles, the Settings → Plugins tab, the three install flows, secrets-in-Keychain, link to `docs/ipf/spec.md` and `docs/ipf/authoring.md`.

- [ ] **Step 5: Verify and commit**

Check: `grep -ri "TBD\|TODO" docs/ipf/` — Expected: no matches.

```bash
git add docs/ipf README.md
git commit -m "docs: IPF 1.0.0 spec, authoring guide, and changelog"
```

---

## Final verification (after all tasks)

- [ ] `swift test 2>&1 | tail -5` — full suite green.
- [ ] `swift run iris` manual pass: legacy `mcp_servers.json` unchanged behavior; snippet install of gemini-notebook works end-to-end; disable/enable toggles servers; uninstall leaves no trace (`ls ~/.iris/plugins`, `security find-generic-password -s iris.plugin.gemini-notebook` → not found).
- [ ] Spec coverage check against `docs/specs/2026-08-27-iris-plugin-system-design.md`: every Summary-table row implemented or explicitly out-of-scope (registry, git installs, HTTP transport, auto-update, `allowed-tools` enforcement).
