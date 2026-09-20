import Testing
import Foundation
@testable import iris

@Suite("GoalContract")
struct GoalContractTests {
    private func draft() -> GoalContract {
        GoalContract(objective: "Fix the reflow",
                     criteria: [Criterion(text: "swift build green", kind: .executable, check: "swift build"),
                                Criterion(text: "twisty repaints without scroll", kind: .qualitative, check: nil)])
    }

    @Test("round-trips through Codable")
    func codable() throws {
        var c = draft(); c.lock()
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(GoalContract.self, from: data)
        #expect(back == c)
    }

    @Test("lock flips state and isLocked")
    func locking() {
        var c = draft()
        #expect(!c.isLocked)
        c.lock()
        #expect(c.isLocked && c.state == .locked)
    }

    @Test("a draft edit does not require a rationale and does not log")
    func draftEdit() {
        var c = draft()
        let ok = c.applyCriteriaEdit(rationale: "") { $0.append(Criterion(text: "x", kind: .qualitative, check: nil)) }
        #expect(ok)
        #expect(c.criteria.count == 3)
        #expect(c.changeLog.isEmpty)
    }

    @Test("a locked edit without a rationale is rejected and changes nothing")
    func lockedEditNoRationale() {
        var c = draft(); c.lock()
        let ok = c.applyCriteriaEdit(rationale: "   ") { $0.removeAll() }
        #expect(!ok)
        #expect(c.criteria.count == 2)   // unchanged
        #expect(c.changeLog.isEmpty)
    }

    @Test("a locked edit with a rationale applies and appends a change-log entry")
    func lockedEditWithRationale() {
        var c = draft(); c.lock()
        let ok = c.applyCriteriaEdit(rationale: "criterion was wrong") {
            $0.append(Criterion(text: "new", kind: .qualitative, check: nil))
        }
        #expect(ok)
        #expect(c.criteria.count == 3)
        #expect(c.changeLog.count == 1)
        #expect(c.changeLog.first?.rationale == "criterion was wrong")
    }

    @Test("oracleText includes objective, each criterion, out-of-scope, stop-before")
    func oracle() {
        var c = draft()
        c.outOfScope = ["selection refactor"]; c.stopBefore = ["force-push"]
        let t = c.oracleText()
        #expect(t.contains("Fix the reflow"))
        #expect(t.contains("swift build green"))
        #expect(t.contains("selection refactor"))
        #expect(t.contains("force-push"))
    }

    // MARK: - #204 round 2: lenient decoders for nested types

    @Test("a Criterion JSON missing text/kind/check decodes to defaults")
    func criterionLenientDecode() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)"}"#
        let c = try JSONDecoder().decode(Criterion.self, from: Data(json.utf8))
        #expect(c.id == id)
        #expect(c.text == "")
        #expect(c.kind == .qualitative)
        #expect(c.check == nil)
    }

    @Test("a Criterion JSON missing id decodes with a freshly minted one (round 3: losing the whole conversation is worse than an orphaned reference)")
    func criterionMissingIdDefaultsToFreshUUID() throws {
        let json = #"{"text":"x","kind":"qualitative"}"#
        let c = try JSONDecoder().decode(Criterion.self, from: Data(json.utf8))
        #expect(c.text == "x")
        #expect(c.kind == .qualitative)
        // id is not asserted to any specific value -- only that decode did not throw.
    }

    @Test("a Milestone JSON missing every field decodes to defaults, including a fresh id")
    func milestoneLenientDecode() throws {
        let m = try JSONDecoder().decode(Milestone.self, from: Data("{}".utf8))
        #expect(m.title == "")
        #expect(m.criterionIds == [])
        // id is never referenced elsewhere for correlation, so minting one on decode is safe.
    }

    @Test("a ContractChange JSON missing date/rationale decodes to defaults")
    func contractChangeLenientDecode() throws {
        let change = try JSONDecoder().decode(ContractChange.self, from: Data("{}".utf8))
        #expect(change.rationale == "")
    }

    @Test("a GoalContract whose criteria element is missing a defaultable field still decodes")
    func goalContractWithLenientNestedCriterionDecodes() throws {
        let criterionId = UUID()
        let json = """
        {"objective":"ship","criteria":[{"id":"\(criterionId.uuidString)"}]}
        """
        let contract = try JSONDecoder().decode(GoalContract.self, from: Data(json.utf8))
        #expect(contract.criteria.count == 1)
        #expect(contract.criteria.first?.id == criterionId)
        #expect(contract.criteria.first?.text == "")
        #expect(contract.criteria.first?.kind == .qualitative)
    }
}
