import Foundation

/// Anthropic Messages streaming (`"stream": true`). Text deltas pass through; a `tool_use`
/// block's `input_json_delta` fragments are buffered per block index and emitted as one
/// `functionCall` on `content_block_stop`; `message_start`/`message_delta` carry the two
/// halves of usage. Every block is also folded as it arrived, and a complete reply that thought
/// emits its content array once, before `done` (#314); `ping` is dropped.
struct AnthropicStreamMapper: StreamMapper {
    private struct ToolBlock { var id: String; var name: String; var json = "" }
    private var tools: [Int: ToolBlock] = [:]
    /// #314: every block of the reply by index, so the array can be stored as received.
    private var blocks: [Int: AnthropicBlocks.Streamed] = [:]
    private var stopReason: String?
    private var stopped = false

    mutating func handle(_ sse: SSEEvent) throws -> [LLMStreamEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(sse.data.utf8)),
              let json = object as? [String: Any] else {
            throw APIError(message: "Anthropic stream: unexpected payload")
        }
        let type = (json["type"] as? String) ?? sse.event ?? ""
        switch type {
        case "message_start":
            var out: [LLMStreamEvent] = []
            let message = json["message"] as? [String: Any]
            if let usage = message?["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int
                let cacheRead = usage["cache_read_input_tokens"] as? Int
                let cacheWrite = usage["cache_creation_input_tokens"] as? Int
                // Emit whenever any of the three is present, not only when `input_tokens` is —
                // requiring `input_tokens` dropped cache fields that WERE present whenever it
                // itself was missing (5a review F8). `anthropicPromptTokenCount` is nil exactly
                // when all three are absent, so it doubles as the "anything to report" check.
                if let prompt = UsageMetadata.anthropicPromptTokenCount(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite) {
                    out.append(.usage(UsageMetadata(promptTokenCount: prompt, candidatesTokenCount: nil, totalTokenCount: nil,
                                                    cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
                                                    cacheWrite1hTokens: UsageMetadata.anthropicOneHourWrites(usage))))
                }
            }
            // #314: the stream carries it here (measured on Vertex); `message_delta` is read too.
            if let entries = InputTransformation.list(message?["input_transformations"]) {
                out.append(.inputTransformations(entries))
            }
            return out
        case "content_block_start":
            guard let index = json["index"] as? Int, let block = json["content_block"] as? [String: Any] else { break }
            let type = block["type"] as? String ?? ""
            var streamed = AnthropicBlocks.Streamed(type: type)
            streamed.text = block["text"] as? String ?? ""
            streamed.thinking = block["thinking"] as? String ?? ""
            streamed.signature = block["signature"] as? String ?? ""
            streamed.data = block["data"] as? String ?? ""
            if type == "tool_use", let id = block["id"] as? String, let name = block["name"] as? String {
                tools[index] = ToolBlock(id: id, name: name)
                streamed.id = id
                streamed.name = name
            }
            blocks[index] = streamed
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any] else { break }
            let index = json["index"] as? Int
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String {
                    if let index { blocks[index]?.text += text }
                    return [.textDelta(text)]
                }
            case "input_json_delta":
                if let index, let partial = delta["partial_json"] as? String {
                    tools[index]?.json += partial
                    blocks[index]?.json += partial
                }
            case "thinking_delta":
                if let index, let thinking = delta["thinking"] as? String { blocks[index]?.thinking += thinking }
            case "signature_delta":
                if let index, let signature = delta["signature"] as? String { blocks[index]?.signature += signature }
            default:
                // A delta this mapper does not fold (citations): the block cannot be rebuilt as it
                // arrived, so the reply stores nothing.
                if let index { blocks[index]?.type = "unfolded" }
            }
        case "content_block_stop":
            if let index = json["index"] as? Int {
                blocks[index]?.stopped = true
                if let block = tools.removeValue(forKey: index) {
                    let args = try Self.decodeArguments(block.json)
                    return [.functionCall(FunctionCall(name: block.name, args: args, id: block.id))]
                }
            }
        case "message_delta":
            var out: [LLMStreamEvent] = []
            if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String { stopReason = reason }
            if let usage = json["usage"] as? [String: Any], let output = usage["output_tokens"] as? Int {
                out.append(.usage(UsageMetadata(promptTokenCount: nil, candidatesTokenCount: output, totalTokenCount: nil)))
            }
            if let entries = InputTransformation.list(json["input_transformations"]) { out.append(.inputTransformations(entries)) }
            return out
        case "message_stop":
            stopped = true
            var out: [LLMStreamEvent] = []
            // Every index from 0, with none missing: otherwise the array is not what arrived.
            let indices = blocks.keys.sorted()
            if indices == Array(0..<indices.count),
               let raw = AnthropicBlocks.render(indices.compactMap { blocks[$0] }) {
                out.append(.anthropicBlocks(raw))
            }
            out.append(.done(finishReason: stopReason))
            return out
        case "error":
            // Same shape and builder as a non-2xx body, so the pill and retry classification match.
            let errorType = (json["error"] as? [String: Any])?["type"] as? String
            let status = Self.statusCode(forErrorType: errorType)
            throw APIError.http(provider: "Anthropic", statusCode: status, body: Data(sse.data.utf8))
        default:
            break
        }
        return []
    }

    mutating func finish() throws -> [LLMStreamEvent] {
        stopped ? [] : [.done(finishReason: stopReason)]
    }

    mutating func headers(_ fields: [AnyHashable: Any]) -> [LLMStreamEvent] {
        InputTransformation.diagnosis(in: fields).map { [.prefixMismatchDiagnosis($0)] } ?? []
    }

    /// Maps Anthropic's error `type` to the status a non-2xx response would have carried, so
    /// `APIError.isRetryable` classifies a streamed error the same way as an HTTP failure.
    private static func statusCode(forErrorType errorType: String?) -> Int {
        switch errorType {
        case "rate_limit_error": return 429
        case "overloaded_error": return 529
        case "authentication_error": return 401
        case "permission_error": return 403
        case "not_found_error": return 404
        case "invalid_request_error": return 400
        default: return 500
        }
    }
}
