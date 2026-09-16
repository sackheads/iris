import Foundation

struct WatcherRule: Codable, Identifiable {
    var id = UUID()
    var path: String
    var instructions: String
}

actor WatcherManager {
    static let shared = WatcherManager()
    
    private var rules: [WatcherRule] = []
    private var activeWatchers: [UUID: FileWatcher] = [:]
    private var onEventCallback: ((String, String) async -> Void)?
    
    init() {
        if let data = IrisDefaults.store.data(forKey: "WATCHER_RULES"),
           let decoded = try? JSONDecoder().decode([WatcherRule].self, from: data) {
            self.rules = decoded
        }
    }
    
    func setCallback(_ callback: @escaping @Sendable (String, String) async -> Void) {
        self.onEventCallback = callback
    }
    
    func addRule(path: String, instructions: String) {
        // Prevent duplicate paths
        if let existingIndex = rules.firstIndex(where: { $0.path == path }) {
            let id = rules[existingIndex].id
            activeWatchers[id]?.stop()
            activeWatchers.removeValue(forKey: id)
            rules.remove(at: existingIndex)
        }
        
        let rule = WatcherRule(path: path, instructions: instructions)
        rules.append(rule)
        saveRules()
        startWatcher(for: rule)
    }
    
    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
        if let watcher = activeWatchers[id] {
            watcher.stop()
            activeWatchers.removeValue(forKey: id)
        }
        saveRules()
    }
    

    private func saveRules() {
        if let data = try? JSONEncoder().encode(rules) {
            IrisDefaults.store.set(data, forKey: "WATCHER_RULES")
        }
    }
    
    func startAll() {
        for rule in rules {
            startWatcher(for: rule)
        }
    }
    
    private func startWatcher(for rule: WatcherRule) {
        if activeWatchers[rule.id] != nil { return }
        
        let watcher = FileWatcher()
        activeWatchers[rule.id] = watcher
        
        Task {
            let events = watcher.watch(paths: [rule.path])
            for await eventPaths in events {
                let pathsString = eventPaths.joined(separator: ", ")
                let message = "System Event: Files modified at \(pathsString).\nYour standing instructions for this event are: \(rule.instructions)\nAnalyze the event and take action silently or acknowledge it if necessary."
                
                await onEventCallback?(message, "FileWatcher")
            }
        }
    }
}
