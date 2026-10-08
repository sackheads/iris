import Foundation
import AppKit

struct ReleaseInfo: Sendable, Codable, Equatable {
    let tagName: String
    let name: String
    let body: String
    let htmlUrl: String
    let downloadUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case assets
    }
    
    struct Asset: Codable, Equatable {
        let name: String
        let browserDownloadUrl: String
        
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }
    
    init(tagName: String, name: String, body: String, htmlUrl: String, downloadUrl: String? = nil) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlUrl = htmlUrl
        self.downloadUrl = downloadUrl
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tagName = try container.decode(String.self, forKey: .tagName)
        self.name = (try? container.decode(String.self, forKey: .name)) ?? self.tagName
        self.body = (try? container.decode(String.self, forKey: .body)) ?? ""
        self.htmlUrl = try container.decode(String.self, forKey: .htmlUrl)
        
        if let assets = try? container.decode([Asset].self, forKey: .assets) {
            self.downloadUrl = assets.first(where: { $0.name.hasSuffix(".zip") || $0.name.hasSuffix(".dmg") })?.browserDownloadUrl ?? assets.first?.browserDownloadUrl
        } else {
            self.downloadUrl = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tagName, forKey: .tagName)
        try container.encode(name, forKey: .name)
        try container.encode(body, forKey: .body)
        try container.encode(htmlUrl, forKey: .htmlUrl)
    }
}

enum UpdateCheckResult: Sendable, Equatable {
    case updateAvailable(ReleaseInfo)
    case upToDate
    case error(String)
}

final class UpdateManager: Sendable {
    static let shared = UpdateManager()
    
    private init() {}
    
    /// SemVer comparison: returns true if `latest` is newer than `current`.
    static func isVersionNewer(current: String, latest: String) -> Bool {
        let cleanCurrent = current.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let cleanLatest = latest.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        
        let currentParts = cleanCurrent.split(separator: ".").compactMap { Int($0) }
        let latestParts = cleanLatest.split(separator: ".").compactMap { Int($0) }
        
        let maxCount = max(currentParts.count, latestParts.count)
        for i in 0..<maxCount {
            let curr = i < currentParts.count ? currentParts[i] : 0
            let lat = i < latestParts.count ? latestParts[i] : 0
            if lat > curr { return true }
            if lat < curr { return false }
        }
        return false
    }
    
    /// Queries GitHub API for the latest release of `repo`.
    func checkForUpdates(currentVersion: String = Constants.appVersion, repo: String = Constants.gitHubRepo) async -> UpdateCheckResult {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return .error("Invalid update URL")
        }
        
        var request = URLRequest(url: url)
        request.setValue("Iris/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10.0
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .error("Invalid server response")
            }
            
            if httpResponse.statusCode == 404 {
                return .upToDate
            }
            guard httpResponse.statusCode == 200 else {
                return .error("HTTP \(httpResponse.statusCode)")
            }
            
            let release = try JSONDecoder().decode(ReleaseInfo.self, from: data)
            if Self.isVersionNewer(current: currentVersion, latest: release.tagName) {
                return .updateAvailable(release)
            } else {
                return .upToDate
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }
    
    /// Opens the release page in the default web browser.
    @MainActor
    func openReleasePage(url: String) {
        if let targetURL = URL(string: url) {
            NSWorkspace.shared.open(targetURL)
        }
    }
}
