import Foundation

/// Where an Anthropic request goes and how it authenticates (#181). The Messages API is the same
/// on both; the differences are confined to `AnthropicClient.makeURLRequest`, so everything after
/// the wire — the stream mapper, `parseResponse`, the cache usage fields 5a's budgets and perf
/// read — is shared by construction.
enum AnthropicTransport: Equatable, Sendable {
    /// `api.anthropic.com` (or a compatible proxy at `baseURL`) with an API key.
    case direct(apiKey: String, baseURL: String)
    /// Vertex AI: the model is part of the URL, `anthropic_version` is in the body, and auth is a
    /// Google access token from Application Default Credentials, with `project` as the quota
    /// project. `location` is `global` (recommended; the only place current-generation models
    /// are served), a multi-region (`us`, `eu`) or a region such as `us-east5`.
    case vertex(project: String, location: String, accessToken: String)

    /// The body field Vertex requires in place of the `anthropic-version` header.
    static let vertexAnthropicVersion = "vertex-2023-10-16"

    /// The transport the Anthropic provider is configured for. `accessToken` is only called in
    /// Vertex mode, and only after the project has been checked: a missing project is a settings
    /// mistake, not a credentials one, and the sentence should say which.
    static func resolve(config: ConfigManager, accessToken: () async throws -> String) async throws -> AnthropicTransport {
        guard config.anthropicAuthMode == AnthropicAuthMode.vertex.rawValue else {
            return .direct(apiKey: config.anthropicAPIKey, baseURL: config.anthropicBaseURL)
        }
        let project = config.anthropicVertexProject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else {
            throw APIError(message: "Anthropic on Vertex AI needs a Google Cloud project. Set it in Settings → LLM Providers → Vertex AI project.")
        }
        return .vertex(project: project, location: config.effectiveVertexLocation, accessToken: try await accessToken())
    }
}

/// The project and location half of the Vertex transport, without a token: what Settings knows
/// before it asks ADC for one, and what the catalog and the perf request dump need.
struct AnthropicVertexTarget: Equatable, Sendable {
    let project: String
    let location: String

    /// `global` has no regional host; `us`/`eu` are multi-region hosts; anything else is a region.
    var host: String {
        switch location {
        case "global": return "aiplatform.googleapis.com"
        case "us", "eu": return "aiplatform.\(location).rep.googleapis.com"
        default: return "\(location)-aiplatform.googleapis.com"
        }
    }

    /// nil unless the config is in Vertex mode with a project.
    static func current(from config: ConfigManager) -> AnthropicVertexTarget? {
        guard config.anthropicAuthMode == AnthropicAuthMode.vertex.rawValue else { return nil }
        let project = config.anthropicVertexProject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else { return nil }
        return AnthropicVertexTarget(project: project, location: config.effectiveVertexLocation)
    }
}
