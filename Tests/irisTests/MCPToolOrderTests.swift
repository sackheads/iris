import Testing
import Foundation
import MCP
@testable import iris

/// MCP servers live in a dictionary, whose iteration order changes from one launch to the next.
/// The declarations it produced changed order with it, and a reordered tool list misses the whole
/// prompt cache on the first turn after a relaunch (5a §0.6: declaration order is fixed by
/// construction). Servers are emitted by name; each server's tools keep the order it reported.
@Suite("MCP tool declaration order (5a)")
struct MCPToolOrderTests {
    private func tool(_ name: String) -> MCP.Tool {
        MCP.Tool(name: name, description: "d", inputSchema: .object(["type": .string("object")]))
    }

    @Test("servers are declared in name order, whatever order they arrive in")
    func serversSortedByName() {
        let zeta = (name: "zeta", tools: [tool("b"), tool("a")], sanitizedDescriptions: [String: String]())
        let alpha = (name: "alpha", tools: [tool("y")], sanitizedDescriptions: [String: String]())
        let mid = (name: "mid", tools: [tool("x")], sanitizedDescriptions: [String: String]())
        let expected = [MCPManager.qualifiedName(server: "alpha", tool: "y"),
                        MCPManager.qualifiedName(server: "mid", tool: "x"),
                        MCPManager.qualifiedName(server: "zeta", tool: "b"),
                        MCPManager.qualifiedName(server: "zeta", tool: "a")]
        for order in [[zeta, alpha, mid], [mid, zeta, alpha], [alpha, mid, zeta]] {
            #expect(MCPManager.declarations(for: order).map(\.name) == expected)
        }
    }
}
