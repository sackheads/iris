import Testing
@testable import IrisKit

@Suite("Evaluator toolset")
struct EvaluatorToolsetTests {
    private func fullToolset() -> [FunctionDeclaration] {
        ["read_file", "run_command", "write_file", "goal_complete", "invoke_subagent",
         "propose_goal_contract", "amend_goal_contract", "search_web", "create_skill"].map {
            FunctionDeclaration(name: $0, description: "d", parameters: nil)
        }
    }

    @Test("restrict keeps only read_file, run_command, submit_evaluation")
    func restricts() {
        let out = EvaluatorToolset.restrict(fullToolset())
        let names = Set(out.map { $0.name })
        #expect(names == ["read_file", "run_command", "submit_evaluation"])
    }

    @Test("submit_evaluation is present and its evaluations array declares items")
    func submitDeclared() {
        let out = EvaluatorToolset.restrict(fullToolset())
        let submit = out.first { $0.name == "submit_evaluation" }
        #expect(submit != nil)
        let evals = submit?.parameters?.properties?["evaluations"]
        #expect(evals?.type == "ARRAY")
        #expect(evals?.items != nil)                      // Gemini requires items on arrays
        #expect(submit?.parameters?.required == ["evaluations"])
    }

    @Test("no mutation or goal tool survives")
    func noMutation() {
        let names = Set(EvaluatorToolset.restrict(fullToolset()).map { $0.name })
        for banned in ["write_file", "goal_complete", "invoke_subagent", "propose_goal_contract",
                       "amend_goal_contract", "search_web", "create_skill"] {
            #expect(!names.contains(banned))
        }
    }
}
