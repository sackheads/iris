import Foundation

actor ADCCredentialManager {
    static let shared = ADCCredentialManager()
    
    private var cachedToken: String?
    private var tokenExpiration: Date?
    private var cachedQuotaProject: String?
    
    private init() {}
    
    func getAccessToken() async throws -> String {
        // Return cached token if valid (with 60s buffer)
        if let token = cachedToken, let exp = tokenExpiration, exp > Date().addingTimeInterval(60) {
            return token
        }
        
        // 1. Try to fetch via ADC JSON file (Direct refresh token flow if ~/.config/gcloud/application_default_credentials.json exists)
        if let jsonToken = await fetchTokenFromADCFile() {
            self.cachedToken = jsonToken.token
            self.tokenExpiration = Date().addingTimeInterval(jsonToken.expiresIn)
            return jsonToken.token
        }
        
        // 2. Try running gcloud CLI
        if let gcloudToken = try await fetchTokenFromGCloudCLI() {
            self.cachedToken = gcloudToken
            self.tokenExpiration = Date().addingTimeInterval(3300) // ~55 minutes
            return gcloudToken
        }
        
        throw APIError(message: "Application Default Credentials (ADC) token not found. Please run 'gcloud auth application-default login --scopes=\"https://www.googleapis.com/auth/cloud-platform\"' (or with --client-id-file for generative-language scope) in terminal.")
    }
    
    func getQuotaProject() async -> String? {
        if let cached = cachedQuotaProject {
            return cached
        }
        
        if let envProject = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_QUOTA_PROJECT"] ?? ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"], !envProject.isEmpty {
            self.cachedQuotaProject = envProject
            return envProject
        }
        
        let home = FileManager.default.homeDirectoryForCurrentUser
        let envADCPath = ProcessInfo.processInfo.environment["GOOGLE_APPLICATION_CREDENTIALS"]
        let adcURL: URL
        if let envADCPath = envADCPath, !envADCPath.isEmpty {
            adcURL = URL(fileURLWithPath: envADCPath)
        } else {
            adcURL = home.appendingPathComponent(".config/gcloud/application_default_credentials.json")
        }
        
        if FileManager.default.fileExists(atPath: adcURL.path),
           let data = try? Data(contentsOf: adcURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let quotaProject = json["quota_project_id"] as? String, !quotaProject.isEmpty {
            self.cachedQuotaProject = quotaProject
            return quotaProject
        }
        
        if let gcloudPath = findGCloudBinary() {
            if let project = try? await runGCloud(path: gcloudPath, args: ["config", "get-value", "project"]), !project.isEmpty, !project.contains(" ") {
                self.cachedQuotaProject = project
                return project
            }
        }
        
        return nil
    }
    
    func clearCache() {
        self.cachedToken = nil
        self.tokenExpiration = nil
        self.cachedQuotaProject = nil
    }
    
    private struct ADCFileToken {
        let token: String
        let expiresIn: TimeInterval
    }
    
    private func fetchTokenFromADCFile() async -> ADCFileToken? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        
        let envADCPath = ProcessInfo.processInfo.environment["GOOGLE_APPLICATION_CREDENTIALS"]
        let adcURL: URL
        if let envADCPath = envADCPath, !envADCPath.isEmpty {
            adcURL = URL(fileURLWithPath: envADCPath)
        } else {
            adcURL = home.appendingPathComponent(".config/gcloud/application_default_credentials.json")
        }
        
        guard FileManager.default.fileExists(atPath: adcURL.path) else { return nil }
        
        do {
            let data = try Data(contentsOf: adcURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let clientID = json["client_id"] as? String,
                  let clientSecret = json["client_secret"] as? String,
                  let refreshToken = json["refresh_token"] as? String else {
                return nil
            }
            
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            
            let bodyParams = [
                "client_id": clientID,
                "client_secret": clientSecret,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token"
            ]
            let bodyString = bodyParams.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&")
            request.httpBody = bodyString.data(using: .utf8)
            
            let (respData, resp) = try await URLSession.shared.data(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            
            guard let respJson = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let accessToken = respJson["access_token"] as? String else {
                return nil
            }
            let expiresIn = (respJson["expires_in"] as? Double) ?? 3600.0
            return ADCFileToken(token: accessToken, expiresIn: expiresIn)
        } catch {
            return nil
        }
    }
    
    private func findGCloudBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let possibleGCloudPaths = [
            "\(home)/google-cloud-sdk/bin/gcloud",
            "/opt/homebrew/bin/gcloud",
            "/usr/local/bin/gcloud",
            "/usr/bin/gcloud"
        ]
        
        for path in possibleGCloudPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    private func fetchTokenFromGCloudCLI() async throws -> String? {
        guard let binaryPath = findGCloudBinary() else {
            return nil
        }
        
        // Try `gcloud auth application-default print-access-token`
        if let token = try await runGCloud(path: binaryPath, args: ["auth", "application-default", "print-access-token"]) {
            return token
        }
        
        return nil
    }
    
    private func runGCloud(path: String, args: [String]) async throws -> String? {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                
                var env = ProcessInfo.processInfo.environment
                let pathEnv = env["PATH"] ?? ""
                env["PATH"] = "\(NSString(string: path).deletingLastPathComponent):/usr/local/bin:/usr/bin:/bin:\(pathEnv)"
                process.environment = env
                
                let pipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = pipe
                process.standardError = errPipe
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    if process.terminationStatus == 0 {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                            let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            if let lastLine = lines.last, !lastLine.isEmpty {
                                continuation.resume(returning: lastLine)
                                return
                            }
                        }
                    }
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
