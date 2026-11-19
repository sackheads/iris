import Testing
import Foundation
@testable import IrisKit

/// #974 Task 6 (C1): a non-owner binding executes only in the sandbox. `resolve` ignores the master
/// switch and every preference for it, and refuses rather than return `.host` when there is no
/// container runtime. The owner binding keeps today's cascade exactly (the named exception).
@Suite("SandboxPolicy.resolve: a non-owner binding never runs on the host (#974 C1)")
struct SandboxPolicyNonOwnerTests {
    private func r(master: Bool = true, principal: Principal, owner: Bool,
                   conv: SandboxPref? = nil, ws: SandboxPref? = nil,
                   def: SandboxPref = .host, runtime: Bool = true) -> SandboxDecision {
        SandboxPolicy.resolve(masterEnabled: master, principal: principal, isOwner: owner,
                              perConversation: conv, perWorkspace: ws, globalDefault: def,
                              runtimeAvailable: runtime)
    }

    private static let principals: [Principal] = [.main, .subagent, .evaluator, .mcpGuest, .broker]
    private static let prefs: [SandboxPref?] = [nil, .host, .sandboxed]

    @Test("a non-owner with the master switch off runs in the sandbox when a runtime exists: the switch is ignored")
    func switchOffIgnored() {
        for p in Self.principals {
            #expect(r(master: false, principal: p, owner: false) == .sandboxed, "\(p)")
        }
    }

    @Test("a non-owner with the master switch off and no runtime is refused, never host")
    func switchOffNoRuntimeRefused() {
        for p in Self.principals {
            let d = r(master: false, principal: p, owner: false, runtime: false)
            #expect(d == .refused(reason: SandboxPolicy.nonOwnerNoRuntimeReason), "\(p): \(d)")
        }
    }

    @Test("a non-owner with the master switch on and no runtime is refused, not host(warnNoRuntime:)")
    func noRuntimeRefusedNotWarned() {
        for p in Self.principals {
            #expect(r(principal: p, owner: false, runtime: false) == .refused(reason: SandboxPolicy.nonOwnerNoRuntimeReason), "\(p)")
        }
    }

    @Test("no combination of inputs ever gives a non-owner the host")
    func neverHost() {
        for p in Self.principals { for master in [true, false] { for conv in Self.prefs { for ws in Self.prefs {
            for def in [SandboxPref.host, .sandboxed] { for runtime in [true, false] {
                let d = r(master: master, principal: p, owner: false, conv: conv, ws: ws, def: def, runtime: runtime)
                if case .host = d { Issue.record("non-owner \(p) master=\(master) conv=\(String(describing: conv)) ws=\(String(describing: ws)) def=\(def) runtime=\(runtime) -> \(d)") }
            } }
        } } } }
    }

    @Test("a per-conversation or per-workspace 'host' preference cannot move a non-owner onto the host")
    func hostPreferencesIgnored() {
        #expect(r(principal: .main, owner: false, conv: .host, ws: .host, def: .host) == .sandboxed)
    }

    @Test("a .main dropped to a named profile is a non-owner: sandbox only")
    func mainDroppedToAProfile() {
        #expect(r(master: false, principal: .main, owner: false) == .sandboxed)
        #expect(r(principal: .main, owner: false, runtime: false) == .refused(reason: SandboxPolicy.nonOwnerNoRuntimeReason))
    }

    // MARK: the owner exception: today's cascade, unchanged

    @Test("the owner main with the master switch off still runs on the host")
    func ownerMainSwitchOff() {
        #expect(r(master: false, principal: .main, owner: true) == .host(warnNoRuntime: false))
        #expect(r(master: false, principal: .main, owner: true, conv: .sandboxed) == .host(warnNoRuntime: false))
    }

    @Test("the owner main sandboxed with no runtime still warns and falls back to the host")
    func ownerMainNoRuntime() {
        #expect(r(principal: .main, owner: true, def: .sandboxed, runtime: false) == .host(warnNoRuntime: true))
    }

    @Test("a subagent on the owner's binding is the owner (Invariant 1): the cascade, not the refusal")
    func ownerSubagent() {
        #expect(r(master: false, principal: .subagent, owner: true) == .host(warnNoRuntime: false))
        #expect(r(principal: .subagent, owner: true) == .sandboxed)
        #expect(r(principal: .evaluator, owner: true, runtime: false) == .host(warnNoRuntime: true))
    }

    @Test("the owner main's preferences still apply")
    func ownerPreferences() {
        #expect(r(principal: .main, owner: true, conv: .host, ws: .sandboxed, def: .sandboxed) == .host(warnNoRuntime: false))
        #expect(r(principal: .main, owner: true, conv: .sandboxed, ws: .host, def: .host) == .sandboxed)
    }
}
