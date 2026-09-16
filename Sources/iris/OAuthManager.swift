import Foundation
import Network
import AppKit

actor ContinuationState {
    var isCalled = false
    func setCalled() -> Bool {
        if isCalled { return true }
        isCalled = true
        return false
    }
}

final class OAuthManager: @unchecked Sendable {
    static let shared = OAuthManager()
    let scopes = [
        "https://www.googleapis.com/auth/calendar",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/drive",
        "https://www.googleapis.com/auth/documents",
        "https://www.googleapis.com/auth/spreadsheets",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/tasks"
    ]
    
    func startOAuthFlow() async throws {
        let clientId = ConfigManager.shared.googleClientID
        let clientSecret = ConfigManager.shared.googleClientSecret
        
        guard !clientId.isEmpty, !clientSecret.isEmpty else {
            throw NSError(domain: "OAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Client ID and Secret required"])
        }
        
        let code = try await listenForCode()
        try await exchangeCode(code)
    }
    
    private func listenForCode() async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let continuationState = ContinuationState()
            
            do {
                let parameters = NWParameters.tcp
                let localEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
                parameters.requiredLocalEndpoint = localEndpoint
                let listener = try NWListener(using: parameters)
                let localScopes = self.scopes // capture safely
                let csrfState = UUID().uuidString
                
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard let port = listener.port?.rawValue else { return }
                        let redirectUri = "http://localhost:\(port)/callback"
                        
                        IrisDefaults.store.set(redirectUri, forKey: "OAUTH_REDIRECT_URI")
                        
                        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                        components.queryItems = [
                            URLQueryItem(name: "client_id", value: ConfigManager.shared.googleClientID),
                            URLQueryItem(name: "redirect_uri", value: redirectUri),
                            URLQueryItem(name: "response_type", value: "code"),
                            URLQueryItem(name: "scope", value: localScopes.joined(separator: " ")),
                            URLQueryItem(name: "access_type", value: "offline"),
                            URLQueryItem(name: "prompt", value: "consent"),
                            URLQueryItem(name: "state", value: csrfState)
                        ]
                        
                        if let url = components.url {
                            DispatchQueue.main.async {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        
                    case .failed(let error):
                        Task {
                            let alreadyCalled = await continuationState.setCalled()
                            if !alreadyCalled {
                                continuation.resume(throwing: error)
                            }
                        }
                    default:
                        break
                    }
                }
                
                listener.newConnectionHandler = { connection in
                    connection.start(queue: .main)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                        if let data = data, let requestStr = String(data: data, encoding: .utf8) {
                            
                            guard let firstLine = requestStr.components(separatedBy: .newlines).first,
                                  let urlPart = firstLine.components(separatedBy: " ").dropFirst().first,
                                  let urlComps = URLComponents(string: urlPart),
                                  let code = urlComps.queryItems?.first(where: { $0.name == "code" })?.value,
                                  let state = urlComps.queryItems?.first(where: { $0.name == "state" })?.value,
                                  state == csrfState else {
                                connection.cancel()
                                return
                            }
                            
                            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<html><head><style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;background:#f5f5f7;}</style></head><body><div style='background:white;padding:40px;border-radius:12px;box-shadow:0 4px 12px rgba(0,0,0,0.1);text-align:center;'><h2>Iris Connected! 🌈</h2><p>Authentication successful. You can close this tab and return to Iris.</p></div></body></html>"
                            
                            connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
                                connection.cancel()
                                listener.cancel()
                                Task {
                                    let alreadyCalled = await continuationState.setCalled()
                                    if !alreadyCalled {
                                        continuation.resume(returning: code)
                                    }
                                }
                            }))
                        }
                    }
                }
                
                listener.start(queue: .main)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                    listener.cancel()
                    Task {
                        let alreadyCalled = await continuationState.setCalled()
                        if !alreadyCalled {
                            continuation.resume(throwing: NSError(domain: "OAuth", code: 408, userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for auth code"]))
                        }
                    }
                }
                
            } catch {
                Task {
                    let alreadyCalled = await continuationState.setCalled()
                    if !alreadyCalled {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    private func exchangeCode(_ code: String) async throws {
        let clientId = ConfigManager.shared.googleClientID
        let clientSecret = ConfigManager.shared.googleClientSecret
        let redirectUri = IrisDefaults.store.string(forKey: "OAUTH_REDIRECT_URI") ?? "http://localhost"
        
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "grant_type", value: "authorization_code")
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OAuth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Exchange failed"])
        }
        
        if httpResponse.statusCode != 200 {
            let errorStr = String(data: data, encoding: .utf8) ?? "Unknown"
            throw NSError(domain: "OAuth", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Token exchange failed: \(errorStr)"])
        }
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let accessToken = json["access_token"] as? String,
           let expiresIn = json["expires_in"] as? Double {
            
            if let refreshToken = json["refresh_token"] as? String {
                await MainActor.run { ConfigManager.shared.googleRefreshToken = refreshToken }
            }
            
            await MainActor.run {
                ConfigManager.shared.googleAccessToken = accessToken
                ConfigManager.shared.googleTokenExpiry = Date().timeIntervalSince1970 + expiresIn
            }
        }
    }
    
    func getValidAccessToken() async throws -> String {
        let expiry = ConfigManager.shared.googleTokenExpiry
        let currentAccessToken = ConfigManager.shared.googleAccessToken
        
        if !currentAccessToken.isEmpty && Date().timeIntervalSince1970 < expiry - 60 {
            return currentAccessToken
        }
        
        return try await refreshToken()
    }
    
    private func refreshToken() async throws -> String {
        let refreshToken = ConfigManager.shared.googleRefreshToken
        let clientId = ConfigManager.shared.googleClientID
        let clientSecret = ConfigManager.shared.googleClientSecret
        
        guard !refreshToken.isEmpty else {
            throw NSError(domain: "OAuth", code: 3, userInfo: [NSLocalizedDescriptionKey: "No refresh token available. Re-authenticate."])
        }
        
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "OAuth", code: 4, userInfo: [NSLocalizedDescriptionKey: "Refresh failed"])
        }
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let accessToken = json["access_token"] as? String,
           let expiresIn = json["expires_in"] as? Double {
            
            await MainActor.run {
                ConfigManager.shared.googleAccessToken = accessToken
                ConfigManager.shared.googleTokenExpiry = Date().timeIntervalSince1970 + expiresIn
            }
            return accessToken
        }
        
        throw NSError(domain: "OAuth", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid refresh response"])
    }
}
