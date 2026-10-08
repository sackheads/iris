import Testing
import Foundation
@testable import IrisKit

@Suite("Schema array items")
struct SchemaItemsTests {
    @Test("an ARRAY schema encodes its items as a single object under \"items\"")
    func arrayEncodesItems() throws {
        let schema = Schema(type: "ARRAY", description: "list of strings", items: Schema(type: "STRING"))
        let data = try JSONEncoder().encode(schema)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "ARRAY")
        let items = try #require(json["items"] as? [String: Any])
        #expect(items["type"] as? String == "STRING")
    }

    @Test("a non-array schema omits the items key entirely")
    func scalarOmitsItems() throws {
        let schema = Schema(type: "STRING", description: "just a string")
        let data = try JSONEncoder().encode(schema)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["items"] == nil)
    }

    @Test("items round-trips through Codable")
    func roundTrips() throws {
        let schema = Schema(type: "ARRAY", items: Schema(type: "OBJECT", properties: [
            "text": Schema(type: "STRING"),
            "kind": Schema(type: "STRING")
        ], required: ["text"]))
        let back = try JSONDecoder().decode(Schema.self, from: JSONEncoder().encode(schema))
        #expect(back.items?.type == "OBJECT")
        #expect(back.items?.properties?["text"]?.type == "STRING")
        #expect(back.items?.required == ["text"])
    }

    @Test("the violation walker flags an ARRAY missing items, at any nesting depth")
    func walkerCatchesMissingItems() {
        // A tool whose top-level property is an ARRAY with no items, plus a nested one.
        let bad = FunctionDeclaration(
            name: "bad", description: "d",
            parameters: Schema(type: "OBJECT", properties: [
                "tags": Schema(type: "ARRAY"),                                  // missing items
                "wrapper": Schema(type: "OBJECT", properties: [
                    "nested": Schema(type: "ARRAY")                             // missing items, nested
                ])
            ]))
        let violations = [bad].arrayItemsViolations()
        #expect(violations.contains("bad.tags"))
        #expect(violations.contains("bad.wrapper.nested"))
    }

    @Test("a well-formed ARRAY (with items) produces no violations")
    func wellFormedHasNoViolations() {
        let good = FunctionDeclaration(
            name: "good", description: "d",
            parameters: Schema(type: "OBJECT", properties: [
                "tags": Schema(type: "ARRAY", items: Schema(type: "STRING")),
                "rows": Schema(type: "ARRAY", items: Schema(type: "OBJECT", properties: [
                    "x": Schema(type: "STRING")
                ]))
            ]))
        #expect([good].arrayItemsViolations().isEmpty)
    }
}
