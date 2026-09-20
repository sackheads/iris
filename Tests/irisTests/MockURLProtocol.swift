import Foundation

class MockURLProtocol: URLProtocol {
    private static let handlerLock = NSLock()
    nonisolated(unsafe) private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var _scopedHandlers: [String: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return _handler
        }
        set {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            _handler = newValue
        }
    }

    /// The header a `scopedSession` tags its requests with, so `startLoading` can find that
    /// session's own handler instead of the single process-global `handler` above.
    static let scopeHeaderField = "X-Iris-MockURLProtocol-Scope"

    /// A `URLSession` whose requests are answered by `handler`, without touching the global
    /// `handler` slot — so two Swift Testing suites can each build one of these and run
    /// concurrently without racing on which handler answers which request (the failure mode a
    /// single shared `handler` has when more than one suite uses it). Call the returned `remove`
    /// when the test is done, typically from a `defer`.
    static func scopedSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> (session: URLSession, remove: () -> Void) {
        let scopeId = UUID().uuidString
        handlerLock.lock()
        _scopedHandlers[scopeId] = handler
        handlerLock.unlock()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpAdditionalHeaders = [scopeHeaderField: scopeId]
        let session = URLSession(configuration: config)

        let remove = {
            handlerLock.lock()
            _scopedHandlers.removeValue(forKey: scopeId)
            handlerLock.unlock()
        }
        return (session, remove)
    }

    /// A request tagged for a scope resolves ONLY within that scope, even if the scope's handler
    /// has already been removed (or was never registered) — it must never silently borrow another
    /// suite's global `handler`, which would be the same class of cross-suite race `scopedSession`
    /// exists to prevent, just moved to the other slot. Only an untagged request falls back to the
    /// global `handler`.
    private enum Resolution {
        case handler((URLRequest) throws -> (HTTPURLResponse, Data))
        case missingScope(String)
        case noHandler
    }

    private static func resolvedHandler(for request: URLRequest) -> Resolution {
        if let scopeId = request.value(forHTTPHeaderField: scopeHeaderField) {
            handlerLock.lock()
            let scoped = _scopedHandlers[scopeId]
            handlerLock.unlock()
            if let scoped { return .handler(scoped) }
            return .missingScope(scopeId)
        }
        if let handler { return .handler(handler) }
        return .noHandler
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let handler: (URLRequest) throws -> (HTTPURLResponse, Data)
        switch Self.resolvedHandler(for: request) {
        case .handler(let h):
            handler = h
        case .missingScope(let scopeId):
            let message = "MockURLProtocol: request is tagged for scope \(scopeId), which has no handler " +
                "(never registered, or already removed by `remove()`). Refusing to fall back to the global " +
                "handler, which would belong to a different test."
            client?.urlProtocol(self, didFailWithError: URLError(.unknown, userInfo: [NSLocalizedDescriptionKey: message]))
            return
        case .noHandler:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            var (response, data) = try handler(request)
            // Handlers answer with one plain JSON message body. The engine streams by default, so
            // a request that asked for a stream is answered in the wire format it asked for:
            // the handler's message is synthesized into an SSE transcript. Only Anthropic's shape
            // is synthesized today, and only for 2xx — an error body stays as it is so the
            // non-2xx path still throws, and a non-JSON body (a hand-written SSE transcript)
            // passes through untouched. Any other provider asking for a stream fails loudly
            // rather than getting a JSON body it cannot parse as SSE.
            if Self.requestedStream(request), (200..<300).contains(response.statusCode),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                guard request.url?.path.hasSuffix("/messages") == true, let url = response.url,
                      let sseResponse = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: nil,
                                                        headerFields: ["Content-Type": "text/event-stream"]) else {
                    let message = "MockURLProtocol: SSE synthesis is implemented for Anthropic /messages only; "
                        + "\(request.url?.absoluteString ?? "<no url>") asked for a stream. Answer it with a "
                        + "hand-written SSE transcript, or turn streaming off for this test."
                    client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL,
                                                                         userInfo: [NSLocalizedDescriptionKey: message]))
                    return
                }
                data = Self.anthropicSSE(fromMessage: json)
                response = sseResponse
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// True for a request whose body asked for `"stream": true`.
    private static func requestedStream(_ request: URLRequest) -> Bool {
        guard let body = request.bodyData,
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else { return false }
        return json["stream"] as? Bool == true
    }

    /// One Anthropic message as the SSE transcript the streaming client expects.
    static func anthropicSSE(fromMessage json: [String: Any]) -> Data {
        let usage = json["usage"] as? [String: Any]
        let inputTokens = usage?["input_tokens"] as? Int ?? 0
        let outputTokens = usage?["output_tokens"] as? Int ?? 0
        let blocks = json["content"] as? [[String: Any]] ?? []

        var transcript = ""
        func emit(_ type: String, _ payload: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            transcript += "event: \(type)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
        }

        emit("message_start", ["type": "message_start",
                               "message": ["id": json["id"] as? String ?? "msg_mock",
                                           "usage": ["input_tokens": inputTokens, "output_tokens": 0]]])

        var sawToolUse = false
        for (index, block) in blocks.enumerated() {
            switch block["type"] as? String {
            case "text":
                emit("content_block_start", ["type": "content_block_start", "index": index,
                                             "content_block": ["type": "text", "text": ""]])
                emit("content_block_delta", ["type": "content_block_delta", "index": index,
                                             "delta": ["type": "text_delta", "text": block["text"] as? String ?? ""]])
                emit("content_block_stop", ["type": "content_block_stop", "index": index])
            case "tool_use":
                sawToolUse = true
                emit("content_block_start", ["type": "content_block_start", "index": index,
                                             "content_block": ["type": "tool_use",
                                                               "id": block["id"] as? String ?? "",
                                                               "name": block["name"] as? String ?? "",
                                                               "input": [:] as [String: Any]]])
                let input = block["input"] as? [String: Any] ?? [:]
                let inputData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                emit("content_block_delta", ["type": "content_block_delta", "index": index,
                                             "delta": ["type": "input_json_delta",
                                                       "partial_json": String(decoding: inputData, as: UTF8.self)]])
                emit("content_block_stop", ["type": "content_block_stop", "index": index])
            default:
                break
            }
        }

        let stopReason = json["stop_reason"] as? String ?? (sawToolUse ? "tool_use" : "end_turn")
        emit("message_delta", ["type": "message_delta", "delta": ["stop_reason": stopReason],
                               "usage": ["output_tokens": outputTokens]])
        emit("message_stop", ["type": "message_stop"])
        return Data(transcript.utf8)
    }
}

extension URLRequest {
    var bodyData: Data? {
        if let httpBody = httpBody {
            return httpBody
        }
        if let stream = httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read < 0 {
                    return nil
                } else if read == 0 {
                    break
                }
                data.append(buffer, count: read)
            }
            return data
        }
        return nil
    }
}
