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

/// The minimal wiring Task 6 needs so the rule above does not regress goal grading: the grader's
/// engine carries a copy of the binding of the run it grades (the full C6 semantics are Task 10).
@Suite("The grader is routed by the binding of the run it grades (#974 Task 6)")
struct EvaluatorBindingWiringTests {
    private let nonOwner = AccessBinding(profile: AccessProfile(memoryRead: .task), principal: .subagent, isOwner: false)
    private let owner = AccessBinding(profile: .owner, principal: .main, isOwner: true)

    @Test("an owner run's grader is the owner, with the grader's own principal")
    func ownerCopied() {
        let b = GoalEvaluator.evaluatorBinding(ofParent: owner)
        #expect(b?.isOwner == true && b?.profile == .owner && b?.principal == .evaluator)
    }

    @Test("a non-owner run's grader is a copy of its profile and stays a non-owner: never widened")
    func nonOwnerCopied() {
        let b = GoalEvaluator.evaluatorBinding(ofParent: nonOwner)
        #expect(b?.isOwner == false && b?.profile == nonOwner.profile && b?.principal == .evaluator)
    }

    @Test("no parent binding gives none, so the engine falls back to its deny-all default, never the owner")
    func noneStaysNone() {
        #expect(GoalEvaluator.evaluatorBinding(ofParent: nil) == nil)
    }

    @Test("every production grader call threads its run's binding")
    func callersThreadTheBinding() throws {
        let dir = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit")
        var sites = 0
        for name in ["iris.swift", "SubagentManager.swift"] {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            var rest = Substring(text)
            while let r = rest.range(of: "GoalEvaluator.shared.evaluate(") {
                let call = String(rest[r.lowerBound...].prefix(700))
                let end = call.range(of: "recentWrites")
                let tail = String(call[(end?.lowerBound ?? call.startIndex)...].prefix(120))
                #expect(tail.contains("parentBinding:"), "\(name): \(tail)")
                // #1216: iris.swift's two sites read the TURN's binding (a guest-steered `.main` turn
                // is not the owner's); SubagentManager's grader passes its own parent's binding.
                if name == "iris.swift" {
                    #expect(tail.contains("parentBinding: await self.bindingForCall(conversationId: conversationId)"), "\(name): \(tail)")
                }
                sites += 1
                rest = rest[r.upperBound...]
            }
        }
        #expect(sites == 3)
    }
}

@Suite("The dispatcher refuses a non-owner's command that has no sandbox (#974 Task 6)")
struct NonOwnerDispatchRefusalTests {
    @Test("only a refused decision is refused; sandboxed and host decisions are not")
    func onlyRefused() {
        #expect(IrisEngine.refusesNonOwnerCommand(.refused(reason: SandboxPolicy.nonOwnerNoRuntimeReason)))
        #expect(!IrisEngine.refusesNonOwnerCommand(.sandboxed))
        #expect(!IrisEngine.refusesNonOwnerCommand(.host(warnNoRuntime: false)))
        #expect(!IrisEngine.refusesNonOwnerCommand(.host(warnNoRuntime: true)))
    }

    @Test("the refusal text says why and that nothing ran on the host")
    func refusalText() {
        #expect(IrisEngine.nonOwnerNoSandboxRefusal.hasPrefix("Not run:"))
        #expect(IrisEngine.nonOwnerNoSandboxRefusal.contains("not run on the host"))
    }

    @Test("the model-turn dispatcher refuses before approval, and the sandbox decision routes by the turn's binding")
    func dispatcherWiring() throws {
        let src = try String(contentsOf: PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/iris.swift"), encoding: .utf8)
        let at = try #require(src.range(of: "#974 C1: a non-owner run's command is run in the sandbox or not at all."))
        let block = String(src[at.lowerBound...].prefix(400))
        #expect(block.contains("Self.refusesNonOwnerCommand("))
        #expect(block.contains("return Self.nonOwnerNoSandboxRefusal"))
        let decision = try #require(src.range(of: "private func sandboxDecision("))
        let body = String(src[decision.lowerBound...].prefix(1300))
        // #1216: the owner bit is the TURN's binding, not the engine's own.
        #expect(body.contains("let callBinding = await bindingForCall(conversationId: conversationId)"))
        #expect(body.contains("isOwner: callBinding.isOwner"))
        #expect(!body.contains("isOwner: binding.isOwner"))
    }
}
