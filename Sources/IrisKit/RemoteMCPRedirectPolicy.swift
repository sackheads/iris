import Foundation

/// #1116: a remote MCP server's headers carry the plugin's secrets (`${keychain:KEY}`, expanded by
/// `MCPManager.resolveHeaders`), and URLSession copies a request's headers onto a redirect. CFNetwork
/// drops `Authorization` when the host changes, but not a custom header such as `X-Api-Key`, so a 307
/// from the configured endpoint to another host sent the key there. This strips every header the
/// plugin configured, and the credential headers, from a redirect that leaves the endpoint's origin,
/// rather than rely on what CFNetwork happens to drop. A same-origin redirect is followed unchanged.
final class RemoteMCPRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    /// Sent by URLSession or the SDK rather than by the plugin, but a credential all the same.
    static let credentialHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie", "mcp-session-id"]

    private let origin: Origin?
    private let stripped: Set<String>

    init(endpoint: URL, configuredHeaders: Set<String>) {
        origin = Origin(endpoint)
        stripped = Self.credentialHeaders.union(configuredHeaders.map { $0.lowercased() })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        redirect(request)
    }

    /// The request a redirect may send: unchanged within the endpoint's origin, without the
    /// stripped headers anywhere else. Origins are compared from the endpoint, not the previous hop,
    /// so a chain that leaves and comes back does not regain them.
    func redirect(_ request: URLRequest) -> URLRequest {
        guard let origin, let target = request.url.flatMap(Origin.init), target == origin else {
            var bare = request
            for name in (request.allHTTPHeaderFields ?? [:]).keys where stripped.contains(name.lowercased()) {
                bare.setValue(nil, forHTTPHeaderField: name)
            }
            return bare
        }
        return request
    }

    /// Scheme, host and port, with the scheme's default port filled in: an https-to-http hop on the
    /// same host is a different origin.
    struct Origin: Equatable, Sendable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
            guard let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil) else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = port
        }
    }
}
