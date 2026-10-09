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
    
    /// Enables a single API. Returns true on success.  Runs off the calling actor.
    @discardableResult
    static func enableAPI(_ serviceName: String) async -> Bool {
        guard let gcloudPath = resolvedGCloudPath else { return false }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: gcloudPath)
                task.arguments = ["services", "enable", serviceName, "--quiet"]
                task.standardOutput = Pipe()
                task.standardError = Pipe()
                do {
                    try task.run()
                    task.waitUntilExit()
                } catch {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: task.terminationStatus == 0)
            }
        }
    }
    
    // MARK: - Internal
    
    /// Runs a gcloud subcommand asynchronously on a background queue and returns its stdout.
    private static func runAsync(_ args: String...) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let result = run(args)
                continuation.resume(returning: result)
            }
        }
    }
    
    private static func run(_ args: [String]) -> String? {
        guard let gcloudPath = resolvedGCloudPath else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: gcloudPath)
        task.arguments = args
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == true ? nil : output
    }
}
