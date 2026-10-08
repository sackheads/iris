import Foundation

actor GoogleTasksManager {
    static let shared = GoogleTasksManager()
    
    private init() {}
    
    func getTools() -> [FunctionDeclaration] {
        return [
            FunctionDeclaration(
                name: "google_tasks_list_tasklists",
                description: "List all Google Tasks tasklists for the authenticated user. Useful to find the tasklist ID before listing or creating tasks.",
                parameters: Schema(
                    type: "OBJECT",
                    properties: [:],
                    required: []
                )
            ),
            FunctionDeclaration(
                name: "google_tasks_list_tasks",
                description: "List all tasks in a specific Google Tasks tasklist.",
                parameters: Schema(
                    type: "OBJECT",
                    properties: [
                        "tasklist": Schema(type: "STRING", description: "The ID of the tasklist to fetch tasks from")
                    ],
                    required: ["tasklist"]
                )
            ),
            FunctionDeclaration(
                name: "google_tasks_create_task",
                description: "Create a new task in a specific Google Tasks tasklist.",
                parameters: Schema(
                    type: "OBJECT",
                    properties: [
                        "tasklist": Schema(type: "STRING", description: "The ID of the tasklist"),
                        "title": Schema(type: "STRING", description: "The title of the new task"),
                        "notes": Schema(type: "STRING", description: "Optional notes/description for the task")
                    ],
                    required: ["tasklist", "title"]
                )
            )
        ]
    }
    
    func execute(name: String, args: [String: JSONValue]) async -> String {
        switch name {
        case "google_tasks_list_tasklists":
            return await listTaskLists()
        case "google_tasks_list_tasks":
            guard let tasklist = args["tasklist"]?.stringValue else { return "Error: Missing tasklist ID" }
            return await listTasks(tasklist: tasklist)
        case "google_tasks_create_task":
            guard let tasklist = args["tasklist"]?.stringValue, let title = args["title"]?.stringValue else { return "Error: Missing tasklist ID or title" }
            return await createTask(tasklist: tasklist, title: title, notes: args["notes"]?.stringValue)
        default:
            return "Error: Unknown Google Tasks tool \(name)"
        }
    }
    
    private func getAuthHeader() async throws -> String {
        let token = try await OAuthManager.shared.getValidAccessToken()
        return "Bearer \(token)"
    }
    
    private func listTaskLists() async -> String {
        do {
            let authHeader = try await getAuthHeader()
            var request = URLRequest(url: URL(string: "https://tasks.googleapis.com/tasks/v1/users/@me/lists")!)
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return "Failed to fetch tasklists: \(String(data: data, encoding: .utf8) ?? "Unknown error")"
            }
            
            if let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "Success, but could not parse response as UTF-8."
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
    
    private func listTasks(tasklist: String) async -> String {
        do {
            let authHeader = try await getAuthHeader()
            var request = URLRequest(url: URL(string: "https://tasks.googleapis.com/tasks/v1/lists/\(tasklist)/tasks")!)
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return "Failed to fetch tasks: \(String(data: data, encoding: .utf8) ?? "Unknown error")"
            }
            
            if let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "Success, but could not parse response as UTF-8."
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
    
    private func createTask(tasklist: String, title: String, notes: String?) async -> String {
        do {
            let authHeader = try await getAuthHeader()
            var request = URLRequest(url: URL(string: "https://tasks.googleapis.com/tasks/v1/lists/\(tasklist)/tasks")!)
            request.httpMethod = "POST"
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            var body: [String: Any] = ["title": title]
            if let notes = notes {
                body["notes"] = notes
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return "Failed to create task: \(String(data: data, encoding: .utf8) ?? "Unknown error")"
            }
            
            if let str = String(data: data, encoding: .utf8) {
                return "Successfully created task:\n\(str)"
            }
            return "Successfully created task."
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
