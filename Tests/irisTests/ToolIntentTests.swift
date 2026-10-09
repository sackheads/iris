import Testing
@testable import IrisKit

@Suite("ToolIntent augment")
struct ToolIntentTests {
    @Test("adds an optional intent to a tool that has parameters")
    func addsIntentToParamTool() {
        let tool = FunctionDeclaration(
            name: "t", description: "d",
            parameters: Schema(type: "OBJECT",
                               properties: ["x": Schema(type: "STRING", description: "x")],
                               required: ["x"]))
        let out = ToolIntent.augment([tool]).first!
        #expect(out.parameters?.properties?["intent"]?.type == "STRING")
        #expect(out.parameters?.properties?["x"] != nil)      // existing prop preserved
        #expect(out.parameters?.required == ["x"])            // intent NOT added to required
    }

    @Test("wraps a params-less tool in an OBJECT schema carrying intent")
    func wrapsParamlessTool() {
        let tool = FunctionDeclaration(name: "t", description: "d", parameters: nil)
        let out = ToolIntent.augment([tool]).first!
        #expect(out.parameters?.type == "OBJECT")
        #expect(out.parameters?.properties?["intent"]?.type == "STRING")
        #expect(out.parameters?.required?.contains("intent") != true)
    }

    @Test("is idempotent when intent is already present")
    func idempotent() {
        let tool = FunctionDeclaration(
            name: "t", description: "d",
            parameters: Schema(type: "OBJECT",
                               properties: ["intent": Schema(type: "STRING", description: "bespoke")],
                               required: nil))
        let out = ToolIntent.augment([tool]).first!
        #expect(out.parameters?.properties?["intent"]?.description == "bespoke")  // unchanged
    }
}
