import Foundation

enum ToolIntent {
    static let description =
        "One short phrase: why you're making this tool call (shown to the user)."

    /// Returns `tools` with an optional `intent` STRING added to each tool's parameter
    /// schema. Idempotent (a tool that already declares `intent` is left unchanged). A
    /// tool with no parameters gets a fresh OBJECT schema carrying only `intent`.
    /// `intent` is never added to `required`.
    static func augment(_ tools: [FunctionDeclaration]) -> [FunctionDeclaration] {
        tools.map { original in
            var tool = original
            let intentSchema = Schema(type: "STRING", description: description)
            if var params = tool.parameters {
                var props = params.properties ?? [:]
                if props["intent"] == nil {
                    props["intent"] = intentSchema
                    params.properties = props
                    tool.parameters = params
                }
            } else {
                tool.parameters = Schema(type: "OBJECT", properties: ["intent": intentSchema])
            }
            return tool
        }
    }
}
