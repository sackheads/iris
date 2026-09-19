import Foundation

/// Anthropic Messages streaming (`"stream": true`). Text deltas pass through; a `tool_use`
/// block's `input_json_delta` fragments are buffered per block index and emitted as one
/// `functionCall` on `content_block_stop`; `message_start`/`message_delta` carry the two
/// halves of usage; `thinking`/`signature` deltas and `ping` are dropped.
struct AnthropicStreamMapper: StreamMapper {
    private struct ToolBlock { var id: String; var name: String; var json = "" }
    private var tools: [Int: ToolBlock] = [:]
    private var stopReason: String?
    private var stopped = false

    mutating func handle(_ sse: SSEEvent) throws -> [LLMStreamEvent] {
        guard let json = try JSONSerialization.jsonObject(with: Data(sse.data.utf8)) as? [String: Any] else {
            throw APIError(message: "Anthropic stream: unexpected payload")
        }
        let type = (json["type"] as? String) ?? sse.event ?? ""
        switch type {
        case "message_start":
            if let usage = (json["message"] as? [String: Any])?["usage"] as? [String: Any],
               let input = usage["input_tokens"] as? Int {
                return [.usage(UsageMetadata(promptTokenCount: input, candidatesTokenCount: nil, totalTokenCount: nil))]
            }
        case "content_block_start":
            if let index = json["index"] as? Int, let block = json["content_block"] as? [String: Any],
               block["type"] as? String == "tool_use",
               let id = block["id"] as? String, let name = block["name"] as? String {
                tools[index] = ToolBlock(id: id, name: name)
            }
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any] else { break }
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String { return [.textDelta(text)] }
            case "input_json_delta":
                if let index = json["index"] as? Int, let partial = delta["partial_json"] as? String {
                    tools[index]?.json += partial
                }
            default:
                break
            }
        case "content_block_stop":
            if let index = json["index"] as? Int, let block = tools.removeValue(forKey: index) {
                let args = try Self.decodeArguments(block.json)
                return [.functionCall(FunctionCall(name: block.name, args: args, id: block.id))]
            }
        case "message_delta":
            var out: [LLMStreamEvent] = []
            if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String { stopReason = reason }
            if let usage = json["usage"] as? [String: Any], let output = usage["output_tokens"] as? Int {
                out.append(.usage(UsageMetadata(promptTokenCount: nil, candidatesTokenCount: output, totalTokenCount: nil)))
            }
            return out
        case "message_stop":
            stopped = true
            return [.done(finishReason: stopReason)]
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
