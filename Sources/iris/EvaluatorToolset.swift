/// The evaluator's world is read-only + running the contract's checks + reporting a verdict.
/// This restricts an assembled tool list to exactly that surface (spec §4.1) and guarantees the
/// terminal `submit_evaluation` tool is present.
enum EvaluatorToolset {
    /// The evaluator's complete surface. Note `restrict(_:)` does NOT use this as its sole filter:
    /// it excludes `submit_evaluation` from the caller's list and re-appends the canonical
    /// declaration below, so the tool is present exactly once regardless of what came in. The name
    /// stays in the set because this is the honest description of the surface.
    static let allowedNames: Set<String> = ["read_file", "run_command", "submit_evaluation"]

    static let submitEvaluation = FunctionDeclaration(
        name: "submit_evaluation",
        description: "Report your independent verdict for the goal contract and end the evaluation. Provide one entry per criterion you graded. Honesty: use cannot_verify when you genuinely can't determine a criterion; never claim met without evidence. Do not grade human-judged criteria.",
        parameters: Schema(type: "OBJECT", properties: [
            "evaluations": Schema(type: "ARRAY", description: "One verdict per graded criterion.", items: Schema(type: "OBJECT", properties: [
                "criterion_id": Schema(type: "STRING", description: "The id of the criterion (copied from the contract you were given)."),
                "verdict": Schema(type: "STRING", description: "met | not_met | cannot_verify"),
                "evidence": Schema(type: "STRING", description: "Concrete evidence: a command + exit code, a file:line, or a one-sentence observation.")
            ], required: ["criterion_id", "verdict"]))
        ], required: ["evaluations"]))

    /// Keep only the allowed tools, and ensure `submit_evaluation` is present exactly once.
    static func restrict(_ tools: [FunctionDeclaration]) -> [FunctionDeclaration] {
        var kept = tools.filter { allowedNames.contains($0.name) && $0.name != "submit_evaluation" }
        kept.append(submitEvaluation)
        return kept
    }
}
