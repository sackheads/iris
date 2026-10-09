import Testing
import Foundation
@testable import IrisKit

@Suite("SandboxPolicy.resolve")
struct SandboxPolicyResolveTests {
    private func r(master: Bool = true, principal: Principal = .main,
                   conv: SandboxPref? = nil, ws: SandboxPref? = nil,
                   def: SandboxPref = .host, runtime: Bool = true) -> SandboxDecision {
        SandboxPolicy.resolve(masterEnabled: master, principal: principal,
                              perConversation: conv, perWorkspace: ws,
                              globalDefault: def, runtimeAvailable: runtime)
    }

    @Test("master off -> host, no warning, regardless of anything")
    func masterOff() {
        #expect(r(master: false, principal: .subagent) == .host(warnNoRuntime: false))
        #expect(r(master: false, principal: .main, conv: .sandboxed, runtime: true) == .host(warnNoRuntime: false))
    }

    @Test("subagent is always sandboxed when runtime available")
    func subagentSandboxed() {
        #expect(r(principal: .subagent, def: .host) == .sandboxed)
    }

    @Test("subagent with no runtime warns and falls back to host")
    func subagentNoRuntime() {
        #expect(r(principal: .subagent, runtime: false) == .host(warnNoRuntime: true))
    }

    @Test("main defaults to global default when no overrides")
    func mainGlobalDefault() {
        #expect(r(def: .host) == .host(warnNoRuntime: false))
        #expect(r(def: .sandboxed) == .sandboxed)
    }

    @Test("main sandboxed but no runtime warns + host")
    func mainNoRuntime() {
        #expect(r(def: .sandboxed, runtime: false) == .host(warnNoRuntime: true))
    }

    @Test("per-workspace override beats global default")
    func workspaceBeatsGlobal() {
        #expect(r(ws: .sandboxed, def: .host) == .sandboxed)
        #expect(r(ws: .host, def: .sandboxed) == .host(warnNoRuntime: false))
    }

    @Test("per-conversation override beats per-workspace and global")
    func conversationBeatsAll() {
        #expect(r(conv: .host, ws: .sandboxed, def: .sandboxed) == .host(warnNoRuntime: false))
        #expect(r(conv: .sandboxed, ws: .host, def: .host) == .sandboxed)
    }
}

@Suite("SandboxPolicy per-workspace override I/O")
struct SandboxPolicyIOTests {
    private func tempWorkspace() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-sbx-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    @Test("missing file -> nil")
    func missing() {
        #expect(SandboxPolicy.perWorkspaceOverride(workspace: tempWorkspace()) == nil)
        #expect(SandboxPolicy.perWorkspaceOverride(workspace: nil) == nil)
    }

    @Test("write then read round-trips")
    func roundTrip() {
        let ws = tempWorkspace()
        SandboxPolicy.setWorkspaceOverride(.sandboxed, for: ws)
        #expect(SandboxPolicy.perWorkspaceOverride(workspace: ws) == .sandboxed)
        SandboxPolicy.setWorkspaceOverride(.host, for: ws)
        #expect(SandboxPolicy.perWorkspaceOverride(workspace: ws) == .host)
    }

    @Test("clear removes the override")
    func clear() {
        let ws = tempWorkspace()
        SandboxPolicy.setWorkspaceOverride(.sandboxed, for: ws)
        SandboxPolicy.setWorkspaceOverride(nil, for: ws)
        #expect(SandboxPolicy.perWorkspaceOverride(workspace: ws) == nil)
    }
}
