import Foundation

enum ModelTier: String, Codable, CaseIterable {
    case easy
    case medium
    case hard
}

struct GeminiRequest: Codable {
    var contents: [Content]
    var systemInstruction: Content?
    var tools: [Tool]?
}

struct Content: Codable, Sendable {
    var role: String?
    var parts: [Part]
}

public struct Part: Codable, Sendable {
    public var text: String?
    public var functionCall: FunctionCall?
    public var functionResponse: FunctionResponse?
    public var inlineData: InlineData? = nil
    public var thought_signature: String?
    public var thoughtSignature: String?

    public init(
        text: String? = nil,
        functionCall: FunctionCall? = nil,
        functionResponse: FunctionResponse? = nil,
        inlineData: InlineData? = nil,
        thought_signature: String? = nil,
        thoughtSignature: String? = nil
    ) {
        self.text = text
        self.functionCall = functionCall
        self.functionResponse = functionResponse
        self.inlineData = inlineData
        self.thought_signature = thought_signature
        self.thoughtSignature = thoughtSignature
    }

    /// Lenient decoder (invariant 1, #204 round 2): every field here was already `Optional`, so the
    /// synthesized decoder already treated a missing key as nil — this makes that explicit rather
    /// than incidental, and protects a decode error inside a present-but-malformed nested value
    /// (`functionCall`/`functionResponse`/`inlineData`) the same way. `decodeIfPresent` on an
    /// Optional nested type still throws if the key IS present but its value fails to decode;
    /// nothing here can make that safe without silently discarding a real tool call, so that case
    /// is unchanged.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        functionCall = try c.decodeIfPresent(FunctionCall.self, forKey: .functionCall)
        functionResponse = try c.decodeIfPresent(FunctionResponse.self, forKey: .functionResponse)
        inlineData = try c.decodeIfPresent(InlineData.self, forKey: .inlineData)
        thought_signature = try c.decodeIfPresent(String.self, forKey: .thought_signature)
        thoughtSignature = try c.decodeIfPresent(String.self, forKey: .thoughtSignature)
    }
}

public struct FunctionCall: Codable, Sendable {
    public var name: String
    public var args: [String: JSONValue]
    public var id: String?
    public var thought_signature: String?
    public var thoughtSignature: String?

    public init(name: String, args: [String: JSONValue], id: String? = nil, thought_signature: String? = nil, thoughtSignature: String? = nil) {
        self.name = name
        self.args = args
        self.id = id
        self.thought_signature = thought_signature
        self.thoughtSignature = thoughtSignature
    }

    /// Lenient decoder (invariant 1, #204 round 2). `name` stays required: it selects which tool
    /// dispatches, so there is no default that would not either silently no-op or call the wrong
    /// tool — an old row is degraded but honest by failing this one `Part` rather than
    /// misrepresenting a call. `args` defaults to `[:]`, matching a tool invoked with no arguments.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        args = try c.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
        id = try c.decodeIfPresent(String.self, forKey: .id)
        thought_signature = try c.decodeIfPresent(String.self, forKey: .thought_signature)
        thoughtSignature = try c.decodeIfPresent(String.self, forKey: .thoughtSignature)
    }
}

/// Synthesized in this file (same-file requirement for auto `==`); used by `LLMStreamEvent`
/// (LLMStream.swift) to compare replayed events.
extension FunctionCall: Equatable {}

public struct FunctionResponse: Codable, Sendable {
    public var name: String
    public var response: [String: JSONValue]
    public var id: String?

    public init(name: String, response: [String: JSONValue], id: String? = nil) {
        self.name = name
        self.response = response
        self.id = id
    }

    /// Lenient decoder (invariant 1, #204 round 2), same rationale as `FunctionCall`: `name`
    /// correlates the response back to the call it answers, so it stays required; `response`
    /// defaults to `[:]`, matching a tool that returned nothing.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        response = try c.decodeIfPresent([String: JSONValue].self, forKey: .response) ?? [:]
        id = try c.decodeIfPresent(String.self, forKey: .id)
    }
}

struct Tool: Codable {
    var functionDeclarations: [FunctionDeclaration]
}

struct FunctionDeclaration: Codable {
    var name: String
    var description: String
    var parameters: Schema?
}

struct Schema: Codable {
    var type: String
    var properties: [String: Schema]?
    var required: [String]?
    var description: String?

    /// Element schema for `type: "ARRAY"`. Gemini rejects an array property that omits this
    /// (HTTP 400 "items: missing field"), so every ARRAY schema MUST set it.
    ///
    /// Backed by a single-element array: a value type can't store `Schema?` inline (infinite
    /// size), but `Array` boxes its contents on the heap — the same indirection `properties`
    /// already relies on. Exposed as a scalar and encoded as a single `items` object.
    private var itemsStorage: [Schema]?
    var items: Schema? {
        get { itemsStorage?.first }
        set { itemsStorage = newValue.map { [$0] } }
    }

    init(type: String,
         properties: [String: Schema]? = nil,
         required: [String]? = nil,
         description: String? = nil,
         items: Schema? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
        self.description = description
        self.items = items
    }

    enum CodingKeys: String, CodingKey { case type, properties, required, description, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        properties = try c.decodeIfPresent([String: Schema].self, forKey: .properties)
        required = try c.decodeIfPresent([String].self, forKey: .required)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        items = try c.decodeIfPresent(Schema.self, forKey: .items)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(properties, forKey: .properties)
        try c.encodeIfPresent(required, forKey: .required)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(items, forKey: .items)
    }

    /// Recursively collects the paths of any `ARRAY` schema missing `items`. Gemini rejects
    /// such a schema (HTTP 400 "items: missing field"), so this must return empty for every
    /// tool actually sent. Empty result = valid.
    func arrayItemsViolations(path: String) -> [String] {
        var out: [String] = []
        if type.uppercased() == "ARRAY" && items == nil { out.append(path) }
        if let items { out += items.arrayItemsViolations(path: "\(path)[]") }
        if let properties {
            for (key, sub) in properties { out += sub.arrayItemsViolations(path: "\(path).\(key)") }
        }
        return out
    }
}

extension Array where Element == FunctionDeclaration {
    /// Every `ARRAY` property (at any depth) across these tools that is missing `items`.
    /// Non-empty means Gemini will reject the request.
    func arrayItemsViolations() -> [String] {
        flatMap { $0.parameters?.arrayItemsViolations(path: $0.name) ?? [] }
    }
}

struct GeminiResponse: Codable {
    var candidates: [Candidate]?
    var usageMetadata: UsageMetadata?
    var promptFeedback: PromptFeedback? = nil

    /// Why the reply carries no content, or nil when the first candidate has parts. Gemini
    /// omits `parts` on an early stop (safety, recitation, empty answer) and reports the cause
    /// on the candidate or, for a blocked prompt, on `promptFeedback` (#136).
    var emptyReason: String? {
        if let content = candidates?.first?.content, !content.parts.isEmpty { return nil }
        if let finish = candidates?.first?.finishReason { return "finishReason: \(finish)" }
        if let block = promptFeedback?.blockReason { return "blockReason: \(block)" }
        return (candidates?.isEmpty == false) ? "empty candidate" : "no candidates"
    }
}

struct Candidate: Codable {
    var content: Content?
    var finishReason: String? = nil
}

struct PromptFeedback: Codable, Sendable {
    var blockReason: String?
}

extension Content {
    private enum CodingKeys: String, CodingKey { case role, parts }

    /// `parts` is absent on a candidate Gemini stopped early. This type is also the persisted
    /// conversation history, so absence must decode, never throw (#136).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        parts = try c.decodeIfPresent([Part].self, forKey: .parts) ?? []
    }
}

struct UsageMetadata: Codable, Sendable {
    var promptTokenCount: Int?
    var candidatesTokenCount: Int?
    var totalTokenCount: Int?
}

/// Synthesized in this file (same-file requirement for auto `==`); used by `LLMStreamEvent`
/// (LLMStream.swift) to compare replayed events.
extension UsageMetadata: Equatable {}

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode(String.self) { self = .string(x); return }
        if let x = try? container.decode(Int.self) { self = .int(x); return }
        if let x = try? container.decode(Double.self) { self = .double(x); return }
        if let x = try? container.decode(Bool.self) { self = .bool(x); return }
        if let x = try? container.decode([String: JSONValue].self) { self = .object(x); return }
        if let x = try? container.decode([JSONValue].self) { self = .array(x); return }
        if container.decodeNil() { self = .null; return }
        throw DecodingError.typeMismatch(JSONValue.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for JSONValue"))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let x): try container.encode(x)
        case .int(let x): try container.encode(x)
        case .double(let x): try container.encode(x)
        case .bool(let x): try container.encode(x)
        case .object(let x): try container.encode(x)
        case .array(let x): try container.encode(x)
        case .null: try container.encodeNil()
        }
    }
    
    public var stringValue: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        case .object: return "{...}"
        case .array: return "[...]"
        case .null: return "null"
        }
    }
    
    public var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .object(let dict): return dict.mapValues { $0.anyValue }
        case .array(let arr): return arr.map { $0.anyValue }
        case .null: return NSNull()
        }
    }
}
