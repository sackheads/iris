import Foundation

/// OpenAI Chat Completions streaming (`"stream": true` + `stream_options.include_usage`).
/// `delta.content` streams; `delta.tool_calls[]` fragments accumulate per `index` and are
/// emitted in index order when the stream ends (`[DONE]` or end of input); the choices-less
/// usage chunk maps to `usage`; `reasoning_content` is kept as the thought signature so the
/// streamed turn round-trips like the non-streaming decoder's.
struct OpenAIStreamMapper: StreamMapper {
    private struct Call { var id: String?; var name: String?; var arguments = "" }
    private var calls: [Int: Call] = [:]
    private var finishReason: String?
    private var reasoning = ""
    private var ended = false

    mutating func handle(_ sse: SSEEvent) throws -> [LLMStreamEvent] {
        let payload = sse.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" {
            ended = true
            return try endEvents()
        }
        guard let json = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw APIError(message: "OpenAI stream: unexpected payload")
        }
        var out: [LLMStreamEvent] = []
        if let choice = (json["choices"] as? [[String: Any]])?.first {
            if let delta = choice["delta"] as? [String: Any] {
                if let text = delta["content"] as? String, !text.isEmpty { out.append(.textDelta(text)) }
                if let r = delta["reasoning_content"] as? String { reasoning += r }
                for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = fragment["index"] as? Int ?? 0
                    var call = calls[index] ?? Call()
                    if let id = fragment["id"] as? String { call.id = id }
                    if let function = fragment["function"] as? [String: Any] {
                        if let name = function["name"] as? String { call.name = name }
                        if let arguments = function["arguments"] as? String { call.arguments += arguments }
                    }
                    calls[index] = call
                }
            }
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
        }
        if let usage = json["usage"] as? [String: Any] {
            out.append(.usage(UsageMetadata(promptTokenCount: usage["prompt_tokens"] as? Int,
                                            candidatesTokenCount: usage["completion_tokens"] as? Int,
                                            totalTokenCount: usage["total_tokens"] as? Int)))
        }
        return out
    }

    mutating func finish() throws -> [LLMStreamEvent] {
        ended ? [] : try endEvents()
    }

    private mutating func endEvents() throws -> [LLMStreamEvent] {
        var out: [LLMStreamEvent] = []
        let signature = reasoning.isEmpty ? nil : reasoning
        for index in calls.keys.sorted() {
            guard let call = calls[index], let name = call.name else { continue }
            let args = try Self.decodeArguments(call.arguments)
            out.append(.functionCall(FunctionCall(name: name, args: args, id: call.id ?? "call_\(name)_\(index)",
                                                  thought_signature: signature, thoughtSignature: signature)))
        }
        calls = [:]
        if let signature { out.append(.thoughtSignature(signature)) }
        out.append(.done(finishReason: finishReason))
        return out
    }
}
