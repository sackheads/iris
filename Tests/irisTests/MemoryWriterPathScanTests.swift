import Testing
import Foundation
@testable import IrisKit

/// #974 Task 7: proof that every code path that writes the owner's memory, facts or skills sits behind
/// `MemoryBindingGate`, not a list of tool names. The scan finds every CALL (not definition) of a
/// store-mutating primitive in `Sources/`, names it by file, enclosing function and primitive, and
/// pins the set. A new writer is a new line here, so it cannot be added without deciding, in review,
/// whether it is gated. (The 8 tool names alone missed `writeGoalLearnings`, a ninth path that stores
/// a fact without the dispatcher.)
@Suite("Every memory, fact and skill write path is accounted for (#974 Task 7)")
struct MemoryWriterPathScanTests {
    static let primitives = ["saveFact", "addFact", "retractFact", "supersedeFact", "restoreFact", "recordFeedback",
                             "removeFact", "evictOldFacts", "updateMemory", "updateSoul", "updateUserProfile",
                             "createSkill", "updateSkill", "deleteSkill"]

    /// `file:enclosingFunction:primitive`, with how each is gated.
    static let expected: [String: String] = [
        // Model tools: refused by `MemoryBindingGate.writeRefusal` at the one dispatch choke point in
        // `executeFunctionCall` (and again on an approved card, `executeApprovedCall`).
        "iris.swift:executeFunctionCall:saveFact": "dispatch gate",
        "iris.swift:executeFunctionCall:updateMemory": "dispatch gate",
        "iris.swift:executeFunctionCall:updateSoul": "dispatch gate",
        "iris.swift:executeFunctionCall:updateUserProfile": "dispatch gate",
        "iris.swift:manageFact:retractFact": "dispatch gate (manage_fact is the only caller)",
        "iris.swift:manageFact:supersedeFact": "dispatch gate (manage_fact is the only caller)",
        "iris.swift:manageFact:restoreFact": "dispatch gate (manage_fact is the only caller)",
        "iris.swift:manageFact:recordFeedback": "dispatch gate (manage_fact is the only caller)",
        "ToolExecutor.swift:execute:createSkill": "dispatch gate (reached only through executeToolWithHooks)",
        "ToolExecutor.swift:execute:updateSkill": "dispatch gate (reached only through executeToolWithHooks)",
        "ToolExecutor.swift:execute:deleteSkill": "dispatch gate (reached only through executeToolWithHooks)",
        "ToolExecutor.swift:updateSkill:createSkill": "dispatch gate (update_skill creating a missing skill)",
        // Not a tool call: gated by its own check on the same table.
        "iris.swift:writeGoalLearnings:saveFact": "writeGoalLearnings gate",
        // Not model-reachable.
        "AppState.swift:handleSkillsCommand:createSkill": "owner's /skills slash command (UI, not a model call)",
        "ScenarioRunner.swift:openConversation:addFact": "scenario harness seeding its own store",
        // The store's own internals.
        "FactStoreManager.swift:addFact:saveFact": "store internal",
        "FactStoreManager.swift:saveFact:evictOldFacts": "store internal",
    ]

    private func sourcesDir() -> URL { PerfPaths.repoRoot().appendingPathComponent("Sources") }

    static func callSites(in text: String, file: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: #"\b("# + primitives.joined(separator: "|") + #")\("#)
        let funcRegex = try! NSRegularExpression(pattern: #"\bfunc\s+(\w+)"#)
        let lines = text.components(separatedBy: "\n")
        var found: Set<String> = []
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            let range = NSRange(line.startIndex..., in: line)
            // Every match on the line, minus a primitive's own definition (`func saveFact(`): a one-line
            // function body that calls one is still a call.
            let calls = regex.matches(in: line, range: range).compactMap { m -> Range<String.Index>? in
                guard let pr = Range(m.range(at: 1), in: line) else { return nil }
                return line[..<pr.lowerBound].hasSuffix("func ") ? nil : pr
            }
            for pr in calls {
            var enclosing = "?"
            var j = i
            while j >= 0 {
                let l = lines[j]
                if let fm = funcRegex.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let nr = Range(fm.range(at: 1), in: l) {
                    enclosing = String(l[nr]); break
                }
                j -= 1
            }
            found.insert("\(file):\(enclosing):\(line[pr])")
            }
        }
        return found
    }

    @Test("the call sites of every store-mutating primitive are exactly the accounted-for set")
    func callSitesArePinned() throws {
        var found: Set<String> = []
        let files = FileManager.default.enumerator(at: sourcesDir(), includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for url in files where url.pathExtension == "swift" {
            found.formUnion(Self.callSites(in: try String(contentsOf: url, encoding: .utf8), file: url.lastPathComponent))
        }
        #expect(found == Set(Self.expected.keys),
                Comment(rawValue: "new: \(found.subtracting(Self.expected.keys).sorted()); gone: \(Set(Self.expected.keys).subtracting(found).sorted())"))
    }

    @Test("the scanner sees a call and ignores a definition and a comment")
    func scannerBehaves() {
        let text = """
        struct S {
            func saveFact(x: Int) {}
            // saveFact(x: 1)
            func caller() {
                try? store.saveFact(content: "x")
            }
            func oneLine() { _ = try? store.updateSoul(content: "y") }
        }
        """
        #expect(Self.callSites(in: text, file: "T.swift") == ["T.swift:caller:saveFact", "T.swift:oneLine:updateSoul"])
    }

    @Test("the dispatcher gate and the two direct gates are really on the paths the table claims")
    func gatesAreWhereTheTableSays() throws {
        let iris = try String(contentsOf: sourcesDir().appendingPathComponent("IrisKit/iris.swift"), encoding: .utf8)
        // The dispatch choke point, the approved-card path and writeGoalLearnings each call the gate.
        #expect(iris.components(separatedBy: "MemoryBindingGate.writeRefusal(").count - 1 >= 3)
        let goal = try #require(iris.range(of: "func writeGoalLearnings"))
        let tail = String(iris[goal.lowerBound...].prefix(2500))
        #expect(tail.contains("MemoryBindingGate.writeRefusal(tool: \"save_fact\""), "writeGoalLearnings must gate before it stores")
        let gate = try #require(tail.range(of: "MemoryBindingGate.writeRefusal("))
        let store = try #require(tail.range(of: "factStore.saveFact("))
        #expect(gate.lowerBound < store.lowerBound, "the gate comes before the store write")
        // manage_fact is the only caller of manageFact, so its four primitives are behind the dispatch gate.
        #expect(iris.components(separatedBy: "manageFact(action:").count - 1 == 2, "one definition, one caller")
    }
}
