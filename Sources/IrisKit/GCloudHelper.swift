import Foundation

/// Lightweight helper for running `gcloud` CLI commands relevant to the
/// Google Workspace OAuth setup flow.  All Process invocations hop off
/// the calling actor so the settings UI stays responsive.
///
/// Searches for the `gcloud` binary in explicit paths so that the helper
/// works even when Iris is launched from Finder/Dock (which inherits a
/// restricted `PATH` that excludes Homebrew and custom SDK directories).
enum GCloudHelper {
    
    struct APIInfo: Identifiable {
        let id: String           // gcloud service name, e.g. "calendar-json.googleapis.com"
        let displayName: String  // human-readable, e.g. "Google Calendar"
        let scope: String        // OAuth scope, e.g. "https://www.googleapis.com/auth/calendar"
        var enabled: Bool
    }
    
    /// The nine APIs required by the Google Workspace and Gemini ADC integrations.
    /// (userinfo.email is an OIDC scope — no People API enablement needed.)
    static let requiredAPIs: [APIInfo] = [
        APIInfo(id: "calendar-json.googleapis.com",      displayName: "Google Calendar",    scope: "https://www.googleapis.com/auth/calendar", enabled: false),
        APIInfo(id: "drive.googleapis.com",              displayName: "Google Drive",       scope: "https://www.googleapis.com/auth/drive", enabled: false),
        APIInfo(id: "docs.googleapis.com",               displayName: "Google Docs",        scope: "https://www.googleapis.com/auth/documents", enabled: false),
        APIInfo(id: "sheets.googleapis.com",             displayName: "Google Sheets",      scope: "https://www.googleapis.com/auth/spreadsheets", enabled: false),
        APIInfo(id: "gmail.googleapis.com",              displayName: "Gmail",              scope: "https://www.googleapis.com/auth/gmail.modify", enabled: false),
        APIInfo(id: "tasks.googleapis.com",              displayName: "Google Tasks",       scope: "https://www.googleapis.com/auth/tasks", enabled: false),
        APIInfo(id: "aiplatform.googleapis.com",         displayName: "Vertex AI",          scope: "https://www.googleapis.com/auth/cloud-platform", enabled: false),
        APIInfo(id: "cloudaicompanion.googleapis.com",   displayName: "Cloud AI Companion", scope: "https://www.googleapis.com/auth/cloud-platform", enabled: false),
        APIInfo(id: "generativelanguage.googleapis.com", displayName: "Gemini API",         scope: "https://www.googleapis.com/auth/generative-language", enabled: false),
    ]
    
    // MARK: - Binary resolution
    
    /// Search paths for the `gcloud` binary, ordered by priority.
    /// macOS GUI apps inherit a restricted PATH, so we probe these explicitly.
    static let gcloudSearchPaths: [String] = [
        "/opt/homebrew/bin/gcloud",                       // Homebrew on Apple Silicon
        "/usr/local/bin/gcloud",                          // Homebrew on Intel / manual install
        "\(NSHomeDirectory())/google-cloud-sdk/bin/gcloud", // Google Cloud SDK standalone
    ]
    
    /// Resolved absolute path to the gcloud binary, or nil if not found.
    static var resolvedGCloudPath: String? {
        for path in gcloudSearchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    /// Returns true if a `gcloud` binary was found at any of the search paths.
    static var isAvailable: Bool {
        resolvedGCloudPath != nil
    }
    
    // MARK: - Auth helpers
    
    /// Returns the authenticated account email, or nil.  Runs off the calling actor.
    static func activeAccount() async -> String? {
        await runAsync("auth", "list", "--format=value(account)", "--filter=status:ACTIVE")
    }
    
    /// Returns the current GCP project ID, or nil.  Runs off the calling actor.
    static func currentProject() async -> String? {
        await runAsync("config", "get-value", "project")
    }
    
    // MARK: - API enablement
    
    /// Parses the raw output of `gcloud services list --enabled --format=value(config.name)`
    /// into a set of enabled service names.  Pure function — testable without gcloud.
    static func parseEnabledServices(from output: String) -> Set<String> {
        Set(output.components(separatedBy: .newlines).filter { !$0.isEmpty })
    }
    
    /// Returns the set of enabled service names.  Runs off the calling actor.
    static func enabledServices() async -> Set<String> {
        guard let raw = await runAsync("services", "list", "--enabled", "--format=value(config.name)") else {
            return []
        }
        return parseEnabledServices(from: raw)
    }
    
    /// How long a `gcloud` read may take, and how long enabling an API may (it provisions on Google's side),
    /// before the process group is killed (#1272).
    static let commandTimeoutSeconds = 60.0
    static let enableTimeoutSeconds = 180.0

    /// Enables a single API. Returns true on success.  Runs off the calling actor, under `ProcessGroupRunner`
    /// so a hung `gcloud` is killed at the deadline or when the caller is cancelled, not waited on forever.
    @discardableResult
    static func enableAPI(_ serviceName: String, gcloudPath: String? = nil, timeoutSeconds: Double = enableTimeoutSeconds) async -> Bool {
        guard let gcloudPath = gcloudPath ?? resolvedGCloudPath else { return false }
        guard case .success(let output) = await ProcessGroupRunner.capture(
            executable: gcloudPath, arguments: ["services", "enable", serviceName, "--quiet"],
            environment: nil, timeoutSeconds: timeoutSeconds) else { return false }
        return output.status == 0 && !output.timedOut && !output.killed
    }

    // MARK: - Internal

    /// Runs a gcloud subcommand and returns its trimmed stdout, or nil on failure, an empty output, the
    /// deadline or a cancel.
    static func runAsync(gcloudPath: String? = nil, timeoutSeconds: Double = commandTimeoutSeconds, _ args: String...) async -> String? {
        guard let gcloudPath = gcloudPath ?? resolvedGCloudPath else { return nil }
        guard case .success(let output) = await ProcessGroupRunner.capture(
            executable: gcloudPath, arguments: args, environment: nil, timeoutSeconds: timeoutSeconds),
              output.status == 0, !output.timedOut, !output.killed else { return nil }
        let text = String(data: output.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == true ? nil : text
    }
}
