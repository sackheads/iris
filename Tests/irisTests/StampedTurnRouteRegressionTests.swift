import Testing
import Foundation
@testable import IrisKit

/// Walks every paren-balanced call to `functionPrefix` (e.g. `"Foo.bar("`) in `source`, in order,
/// and returns each call's full text (opening name through its matching close paren). Shared by
/// the source-scan suites below to avoid three copies of the same paren-matching walk.
private enum SourceCallScan {
    static func callSites(of functionPrefix: String, in source: String) -> [Substring] {
        var calls: [Substring] = []
        var searchRange = source.startIndex..<source.endIndex
        while let callRange = source.range(of: functionPrefix, range: searchRange) {
            let openIndex = source.index(before: callRange.upperBound)
            var depth = 0
            var i = openIndex
            while i < source.endIndex {
                if source[i] == "(" { depth += 1 } else if source[i] == ")" { depth -= 1; if depth == 0 { break } }
                i = source.index(after: i)
            }
            calls.append(source[callRange.lowerBound...i])
            searchRange = source.index(after: i)..<source.endIndex
        }
        return calls
    }
}

/// Regression pins for the stamped-non-owner-.main-turn audit: routes the audit traced clean by
/// reading the code, but that had no test driving them through the real stamp
/// (`AppState.markGuestSteeredBinding`) on a SHARED engine -- as opposed to an engine constructed
/// with that binding directly, which is a different, already-well-covered shape
/// (`ScrubKnownSecretsTests`, `MemoryBindingGateTests`). The two differ because production almost
/// always runs one shared `.main` engine across every conversation; a route that reads
/// `self.binding` instead of `bindingForCall(conversationId:)` passes the engine-constructed shape
/// but leaks on the shared one.
@MainActor
@Suite("Stamped non-owner .main turn: routes with no prior live-stamp regression test", .timeLimit(.minutes(2)))
struct StampedTurnRouteRegressionTests {
    /// `fsRoots: [dir]` so `read_file` actually reaches the secret file rather than being refused
    /// first by the unrelated granted-directory gate -- the scrub must be what stands between the
    /// secret and the model here, not a different access-control check standing in for it.
    private func nonOwnerBindingReading(_ dir: String) -> AccessBinding {
        AccessBinding(profile: AccessProfile(fsRoots: [dir]), principal: .main, isOwner: false)
    }

    // MARK: the scrub (scrubbedForBinding), via a stamped turn on a shared engine

    @Test("a known secret in a tool result is scrubbed on a stamped non-owner turn, not on the owner's own turn on the same shared engine")
    func scrubAppliesToTheStampedTurnNotTheEngine() async throws {
        let secret = "sk-stamped-1303-aaaaaaaaaaaa"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1303-scrub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("secret.txt")
        try secret.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        app.autoApproveTools = true
        let ownerId = app.createNewConversation(title: "owner")
        let stampedId = app.createNewConversation(title: "stamped")
        app.markGuestSteeredBinding(nonOwnerBindingReading(root.path), for: stampedId)

        // One shared engine, as production runs (dev-2's #1304 review note): two separately
        // constructed engines would not prove `bindingForCall` is what the route consults, since
        // each engine's own default binding could carry the answer instead.
        func readCall() -> GeminiResponse {
            let call = FunctionCall(name: "read_file", args: ["path": .string(file.path)])
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil)
        }
        func okText() -> GeminiResponse {
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        }
        let client = FakeLLMClient(responses: [readCall(), okText(), readCall(), okText()])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0,
                                knownSecrets: { [secret] })

        func lastResult(_ convId: UUID) -> String {
            let history = app.conversations.first { $0.id == convId }?.history ?? []
            return history.flatMap { $0.parts }.compactMap { part -> String? in
                guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
                return s
            }.last ?? ""
        }

        await engine.processInput("go", source: "UI", conversationId: ownerId)
        let ownerResult = lastResult(ownerId)
        #expect(ownerResult.contains(secret), "the owner's own turn must still see the secret unscrubbed (positive control): \(ownerResult)")
        await engine.processInput("go", source: "UI", conversationId: stampedId)
        let stampedResult = lastResult(stampedId)
        #expect(!stampedResult.contains(secret), "the stamped non-owner turn must have the known secret scrubbed: \(stampedResult)")
    }
}

/// `GoalEvaluator.evaluatorBinding(ofParent:)` is directly testable (`EvaluatorInheritsBindingTests`),
/// and so is `bindingForCall` itself (`MemoryBindingGateTests`'s `seamReturnsTheEnginesBinding`), but
/// neither pins that the three call sites which spawn a grader (iris.swift x2, SubagentManager x1)
/// actually pass the TURN's resolved binding rather than a literal nil or `self.binding`. A source
/// scan pins the wiring itself, the same pattern as `SubagentManagerBindingWiringSourceScanTests`
/// above (which pins `SubagentManager`'s own internal construction, not these call sites). Each
/// scan asserts the EXACT correct form at every matched call, not merely that it appears somewhere:
/// since a call has exactly one `parentBinding:` argument, asserting its correct text already
/// excludes `self.binding` (or any other value) by construction, and the `count ==` check (the
/// same completeness shape as `writerTiers`) keeps an empty match set from passing vacuously.
@Suite("GoalEvaluator call-site binding wiring source scan")
struct GoalEvaluatorCallSiteWiringSourceScanTests {
    @Test("every GoalEvaluator.evaluate call site in iris.swift passes the turn's own bindingForCall, never self.binding")
    func iriswiftCallSitesUseBindingForCall() throws {
        let url = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/iris.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let calls = SourceCallScan.callSites(of: "GoalEvaluator.shared.evaluate(", in: source)
        for call in calls {
            #expect(call.contains("parentBinding: await self.bindingForCall(conversationId: conversationId)"),
                    "a GoalEvaluator.evaluate call in iris.swift must thread the turn's own bindingForCall, not self.binding or a literal nil -- the grader would silently inherit the engine's default otherwise")
        }
        #expect(calls.count == 2, "expected the 2 known iris.swift call sites -- a count of 0 would pass the check above vacuously, and a changed count means this scan needs updating")
    }

    @Test("SubagentManager's own GoalEvaluator.evaluate call site passes childBinding (parent capped by the subagent floor), never the parent's raw binding")
    func subagentManagerCallSiteUsesChildBinding() throws {
        let url = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/SubagentManager.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let calls = SourceCallScan.callSites(of: "GoalEvaluator.shared.evaluate(", in: source)
        for call in calls {
            #expect(call.contains("parentBinding: childBinding"),
                    "SubagentManager's own grading call must pass the capped childBinding, not the raw parentBinding it received")
        }
        #expect(calls.count == 1, "expected the 1 known SubagentManager.swift call site -- a count of 0 would pass the check above vacuously, and a changed count means this scan needs updating")
    }
}

/// The analogous scan for `invoke_subagent`'s own dispatch sites in iris.swift: `SubagentManager`'s
/// internal wiring (`childBinding = Self.childBinding(ofParent: parentBinding, ...)`, `binding:
/// childBinding`) is pinned by `SubagentManagerBindingWiringSourceScanTests` above, but that does
/// not prove the CALLER passes the turn's real binding as `parentBinding` in the first place.
@Suite("invoke_subagent call-site binding wiring source scan")
struct InvokeSubagentCallSiteWiringSourceScanTests {
    @Test("every runSubagent call site in iris.swift passes the turn's own bindingForCall as parentBinding, never self.binding")
    func allCallSitesUseBindingForCall() throws {
        let url = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/iris.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let calls = SourceCallScan.callSites(of: "SubagentManager.shared.runSubagent(", in: source)
        for call in calls {
            #expect(call.contains("parentBinding: await self.bindingForCall(conversationId: conversationId)"),
                    "a runSubagent call in iris.swift must thread the turn's own bindingForCall as parentBinding, not self.binding -- a subagent spawned from a stamped non-owner turn would silently inherit the shared engine's owner default otherwise")
        }
        #expect(calls.count == 3, "expected the 3 known iris.swift call sites -- a count of 0 would pass the check above vacuously, and a changed count means this scan needs updating")
    }
}
