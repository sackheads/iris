import Testing
import MCP
@testable import iris

@Suite("MCP-to-Gemini schema conversion")
struct MCPSchemaConversionTests {

    @Test("array of strings converts to ARRAY with STRING items")
    func arrayOfStrings() {
        let mcp: MCP.Value = .object([
            "type": .string("array"),
            "description": .string("Notebook IDs"),
            "items": .object(["type": .string("string")])
        ])
        let schema = MCPManager.geminiSchema(fromMCP: mcp)
        #expect(schema.type == "ARRAY")
        #expect(schema.items?.type == "STRING")
        #expect(schema.description == "Notebook IDs")
        #expect(schema.arrayItemsViolations(path: "collection_create.notebook_ids").isEmpty)
    }

    @Test("array missing items falls back to STRING items")
    func arrayMissingItems() {
        let mcp: MCP.Value = .object([
            "type": .string("array")
        ])
        let schema = MCPManager.geminiSchema(fromMCP: mcp)
        #expect(schema.type == "ARRAY")
        #expect(schema.items?.type == "STRING")
        #expect(schema.arrayItemsViolations(path: "tool.param").isEmpty)
    }

    @Test("nested object with its own array property recurses and sets items")
    func nestedObjectWithArray() {
        let mcp: MCP.Value = .object([
            "type": .string("object"),
            "description": .string("Filter"),
            "properties": .object([
                "tags": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "limit": .object(["type": .string("integer")])
            ]),
            "required": .array([.string("tags")])
        ])
        let schema = MCPManager.geminiSchema(fromMCP: mcp)
        #expect(schema.type == "OBJECT")
        #expect(schema.required == ["tags"])
        #expect(schema.properties?["tags"]?.type == "ARRAY")
        #expect(schema.properties?["tags"]?.items?.type == "STRING")
        #expect(schema.properties?["limit"]?.type == "INTEGER")
        #expect(schema.arrayItemsViolations(path: "tool.filter").isEmpty)
    }

    @Test("scalar passthrough preserves description")
    func scalarPassthrough() {
        let mcp: MCP.Value = .object([
            "type": .string("string"),
            "description": .string("The notebook title")
        ])
        let schema = MCPManager.geminiSchema(fromMCP: mcp)
        #expect(schema.type == "STRING")
        #expect(schema.description == "The notebook title")
        #expect(schema.arrayItemsViolations(path: "tool.title").isEmpty)
    }

    @Test("missing type falls back to STRING so nested arrays/objects never drop the property")
    func missingTypeFallback() {
        let mcp: MCP.Value = .object([
            "description": .string("Untyped nested field")
        ])
        let schema = MCPManager.geminiSchema(fromMCP: mcp)
        #expect(schema.type == "STRING")
        #expect(schema.description == "Untyped nested field")
        #expect(schema.arrayItemsViolations(path: "tool.untyped").isEmpty)
    }

    @Test("array of objects: items themselves are recursively converted")
    func arrayOfObjects() {
        let mcp: MCP.Value = .object([
            "type": .string("array"),
            "items": .object([
                "type": .string("object"),
                "properties": .object([
                    "ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")])
                    ])
                ])
            ])
        ])
        let schema = MCPManager.geminiSchema(fromMCP: mcp)
        #expect(schema.type == "ARRAY")
        #expect(schema.items?.type == "OBJECT")
        #expect(schema.items?.properties?["ids"]?.type == "ARRAY")
        #expect(schema.items?.properties?["ids"]?.items?.type == "STRING")
        #expect(schema.arrayItemsViolations(path: "tool.rows").isEmpty)
    }

    // MARK: Read-only annotations (#187 §0.2)

    /// The join and the annotation read, as a pure function over what a server reported, because
    /// the actor's `servers` map has no fixture to build. `readOnlyToolNames()` is this plus the
    /// map, so the rule a read-only job run depends on is testable without a live MCP server.
    @Test("only a tool its server annotated read-only is named read-only")
    func readOnlyNamesFromAnnotations() {
        let names = MCPManager.readOnlyToolNames(in: [
            ("github", "list_issues", true),
            ("github", "create_issue", false),
            ("notion", "append_block", nil),   // says nothing: not a claim we can act on
        ])
        #expect(names == ["github___list_issues"])
        // And the join is the separator the declarations use, not a second spelling of it.
        #expect(names.first?.contains(JobProfile.mcpNameSeparator) == true)
        #expect(MCPManager.readOnlyToolNames(in: []).isEmpty)
    }
}
