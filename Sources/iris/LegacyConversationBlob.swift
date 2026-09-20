import Foundation

/// One-time move from the UserDefaults JSON blob to the conversation store (#163, spec §6).
enum LegacyConversationBlob {
    static let key = "iris_conversations"
    static let legacyKey = "iris_conversations_legacy"

    enum Outcome: Equatable {
        case nothingToDo
        case imported(Int)
        case storeNotEmpty
        case undecodable
    }

    static func migrateIfNeeded(into store: ConversationStore, defaults: UserDefaults, now: Date = Date()) -> Outcome {
        guard let data = defaults.data(forKey: key) else { return .nothingToDo }
        let decoded: [Conversation]
        do {
            decoded = try JSONDecoder().decode([Conversation].self, from: data)
        } catch {
            // Same behaviour as the old loader: keep the blob, park a copy, start empty.
            print("Failed to decode legacy conversations: \(error)")
            defaults.set(data, forKey: "iris_conversations_backup_\(now.timeIntervalSince1970)")
            return .undecodable
        }
        let durable = AppState.durableConversations(decoded)
        let imported: Bool
        do {
            imported = try store.importLegacy(durable)
        } catch {
            print("Legacy conversation import failed; leaving the blob in place: \(error)")
            return .undecodable
        }
        // Only after the transaction committed: park the blob and stop reading it.
        defaults.set(data, forKey: legacyKey)
        defaults.removeObject(forKey: key)
        return imported ? .imported(durable.count) : .storeNotEmpty
    }
}
