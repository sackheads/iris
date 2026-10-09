import Foundation

actor GoogleWorkspaceManager {
    static let shared = GoogleWorkspaceManager()
    
    private init() {}
    
    func getTools() -> [FunctionDeclaration] {
        return [
            // Calendar
            FunctionDeclaration(
                name: "google_calendar_list_events",
                description: "List upcoming events from the primary Google Calendar.",
                parameters: Schema(
                    type: "OBJECT",
                    properties: [
                        "maxResults": Schema(type: "STRING", description: "Maximum number of events to return (default: 10)")
                    ],
                    required: []
                )
            ),
            FunctionDeclaration(
                name: "google_calendar_create_event",
                description: "Create a new event in the primary Google Calendar. Dates must be RFC3339 format (e.g. 2024-12-31T10:00:00Z).",
                parameters: Schema(
                    type: "OBJECT",
                    properties: [
                        "summary": Schema(type: "STRING", description: "Title of the event"),
                        "start": Schema(type: "STRING", description: "Start time in RFC3339 format"),
                        "end": Schema(type: "STRING", description: "End time in RFC3339 format")
                    ],
                    required: ["summary", "start", "end"]
                )
            ),
            
            // Docs
            FunctionDeclaration(
                name: "google_docs_get",
                description: "Fetch the content of a Google Document.",
                parameters: Schema(
                    type: "OBJECT",
                    properties: [
                        "documentId": Schema(type: "STRING", description: "The ID of the document")
                    ],
                    required: ["documentId"]
                )
            ),
            
            // Drive
            FunctionDeclaration(
                name: "google_drive_search",
                description: "Search Google Drive for files.",
                parameters: Schema(
                    type: "OBJECT",
                    properties: [
                        "query": Schema(type: "STRING", description: "The search query (e.g. \"name contains 'budget'\")")
                    ],
                    required: ["query"]
                )
            ),
            
            // Sheets
            FunctionDeclaration(
                name: "google_sheets_get",
                description: "Get values from a Google Sheet.",
                parameters: Schema(
                    type: "OBJECT",
                    properties: [
                        "spreadsheetId": Schema(type: "STRING", description: "The ID of the spreadsheet"),
                        "range": Schema(type: "STRING", description: "The A1 notation of the values to retrieve (e.g. 'Sheet1!A1:D5')")
                    ],
                    required: ["spreadsheetId", "range"]
                )
            ),
            
            // Gmail
            FunctionDeclaration(
                name: "gmail_list_unread",
                description: "List unread emails in the user's Gmail inbox.",
                parameters: Schema(
                    type: "OBJECT",
                    properties: [
                        "maxResults": Schema(type: "STRING", description: "Max results to fetch (default: 10)")
                    ],
                    required: []
                )
            ),
            FunctionDeclaration(
                name: "gmail_send_email",
                description: "Send an email using Gmail.",
                parameters: Schema(
                    type: "OBJECT",
                    properties: [
                        "to": Schema(type: "STRING", description: "Recipient email address"),
                        "subject": Schema(type: "STRING", description: "Subject of the email"),
                        "body": Schema(type: "STRING", description: "Body content of the email")
                    ],
                    required: ["to", "subject", "body"]
                )
            )
        ]
    }
    
    func execute(name: String, args: [String: JSONValue]) async -> String {
        switch name {
        case "google_calendar_list_events":
            return await listCalendarEvents(maxResults: args["maxResults"]?.stringValue)
        case "google_calendar_create_event":
            guard let summary = args["summary"]?.stringValue, let start = args["start"]?.stringValue, let end = args["end"]?.stringValue else {
                return "Error: Missing required parameters."
            }
            return await createCalendarEvent(summary: summary, start: start, end: end)
        case "google_docs_get":
            guard let documentId = args["documentId"]?.stringValue else { return "Error: Missing documentId" }
            return await getDocument(documentId: documentId)
        case "google_drive_search":
            guard let query = args["query"]?.stringValue else { return "Error: Missing query" }
            return await searchDrive(query: query)
        case "google_sheets_get":
            guard let spreadsheetId = args["spreadsheetId"]?.stringValue, let range = args["range"]?.stringValue else { return "Error: Missing parameters" }
            return await getSheetValues(spreadsheetId: spreadsheetId, range: range)
        case "gmail_list_unread":
            return await listUnreadGmail(maxResults: args["maxResults"]?.stringValue)
        case "gmail_send_email":
            guard let to = args["to"]?.stringValue, let subject = args["subject"]?.stringValue, let body = args["body"]?.stringValue else {
                return "Error: Missing required parameters."
            }
            return await sendEmail(to: to, subject: subject, body: body)
        default:
            return "Error: Unknown tool \(name)"
        }
    }
    
    private func getAuthHeader() async throws -> String {
        let token = try await OAuthManager.shared.getValidAccessToken()
        return "Bearer \(token)"
    }
    
    // MARK: - Calendar
    
    private func listCalendarEvents(maxResults: String?) async -> String {
        do {
            let authHeader = try await getAuthHeader()
            let max = maxResults ?? "10"
            let timeMin = ISO8601DateFormatter().string(from: Date())
            let encodedTimeMin = timeMin.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? timeMin
            let urlStr = "https://www.googleapis.com/calendar/v3/calendars/primary/events?maxResults=\(max)&timeMin=\(encodedTimeMin)&singleEvents=true&orderBy=startTime"

            guard let url = URL(string: urlStr) else {
                return "Error: Failed to construct calendar request URL."
            }
            var request = URLRequest(url: url)
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return "Failed to fetch calendar events: \(String(data: data, encoding: .utf8) ?? "Unknown")"
            }
            
            return String(data: data, encoding: .utf8) ?? "Unknown response"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
    
    private func createCalendarEvent(summary: String, start: String, end: String) async -> String {
        do {
            let authHeader = try await getAuthHeader()
            var request = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!)
            request.httpMethod = "POST"
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let body: [String: Any] = [
                "summary": summary,
                "start": ["dateTime": start],
                "end": ["dateTime": end]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return "Failed to create event: \(String(data: data, encoding: .utf8) ?? "Unknown")"
            }
            
            return "Event created successfully: \(String(data: data, encoding: .utf8) ?? "")"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Docs
    
    private func getDocument(documentId: String) async -> String {
        do {
            let authHeader = try await getAuthHeader()
            var request = URLRequest(url: URL(string: "https://docs.googleapis.com/v1/documents/\(documentId)")!)
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return "Failed to fetch document: \(String(data: data, encoding: .utf8) ?? "Unknown")"
            }
            
            return String(data: data, encoding: .utf8) ?? "Unknown response"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Drive
    
    private func searchDrive(query: String) async -> String {
        do {
            let authHeader = try await getAuthHeader()
            guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return "Error encoding query" }
            var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?q=\(encodedQuery)")!)
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return "Failed to search drive: \(String(data: data, encoding: .utf8) ?? "Unknown")"
            }
            
            return String(data: data, encoding: .utf8) ?? "Unknown response"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Sheets
    
    private func getSheetValues(spreadsheetId: String, range: String) async -> String {
        do {
            let authHeader = try await getAuthHeader()
            guard let encodedRange = range.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return "Error encoding range" }
            var request = URLRequest(url: URL(string: "https://sheets.googleapis.com/v4/spreadsheets/\(spreadsheetId)/values/\(encodedRange)")!)
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return "Failed to get sheet values: \(String(data: data, encoding: .utf8) ?? "Unknown")"
            }
            
            return String(data: data, encoding: .utf8) ?? "Unknown response"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Gmail
    
    private func listUnreadGmail(maxResults: String?) async -> String {
        do {
            let authHeader = try await getAuthHeader()
            let max = maxResults ?? "10"
            let urlStr = "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=is:unread&maxResults=\(max)"
            
            var request = URLRequest(url: URL(string: urlStr)!)
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return "Failed to list emails: \(String(data: data, encoding: .utf8) ?? "Unknown")"
            }
            
            // To get full contents, we'd need to iterate over IDs, but returning IDs is a start
            return String(data: data, encoding: .utf8) ?? "Unknown response"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
    
    private func sendEmail(to: String, subject: String, body: String) async -> String {
        do {
            let authHeader = try await getAuthHeader()
            var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
            request.httpMethod = "POST"
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let rawMessage = "To: \(to)\nSubject: \(subject)\n\n\(body)"
            guard let rawData = rawMessage.data(using: .utf8) else {
                return "Error: Failed to encode email body as UTF-8."
            }
            let encodedMessage = rawData.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
                
            let jsonBody: [String: Any] = ["raw": encodedMessage]
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return "Failed to send email: \(String(data: data, encoding: .utf8) ?? "Unknown")"
            }
            
            return "Email sent successfully."
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
