import Foundation

/// One-time move from the UserDefaults JSON blob to the conversation store (#163, spec §6).
enum LegacyConversationBlob {
    static let key = "iris_conversations"
    static let legacyKey = "iris_conversations_legacy"

    enum Outcome: Equatable {
        case nothingToDo
        case imported(Int)
        /// The store's `legacy_import_done` marker was already set, so this blob is a leftover
        /// copy of an import that has already happened: nothing is written, but the stale live
        /// key is still moved out of the way.
        case alreadyImported
        /// The blob's JSON could not be decoded at all. A timestamped backup is kept and the live
        /// key is removed — the data is presumed lost, so there is nothing to retry, and leaving
        /// the key in place would re-run (and re-notify) this on every single launch.
        case undecodable
        /// The blob decoded fine but the write into the store failed (disk full, some other
        /// transient condition). The live key is left in place so the next launch retries.
        case importFailed
    }

    static func migrateIfNeeded(into store: ConversationStore, defaults: UserDefaults, now: Date = Date()) -> Outcome {
        guard let data = defaults.data(forKey: key) else { return .nothingToDo }
        let decoded: [Conversation]
        do {
            decoded = try JSONDecoder().decode([Conversation].self, from: data)
        } catch {
            // Park a copy under a timestamped key and stop reading the live key: the data is
            // presumed lost, and leaving the key in place made the old loader re-back-up (and,
            // with #163's notice, re-tell the user) on every single launch instead of once.
            print("Failed to decode legacy conversations: \(error)")
            defaults.set(data, forKey: "iris_conversations_backup_\(now.timeIntervalSince1970)")
            defaults.removeObject(forKey: key)
            return .undecodable
        }
        let durable = AppState.durableConversations(decoded)
        let imported: Bool
        do {
            imported = try store.importLegacy(durable)
        } catch {
            // Unlike an undecodable blob, this is worth retrying: the data is fine, only the write
            // failed. Leave the live key in place so the next launch tries again.
            print("Legacy conversation import failed; will retry at the next launch: \(error)")
            return .importFailed
        }
        // Only after the transaction committed: park the blob and stop reading it.
        defaults.set(data, forKey: legacyKey)
        defaults.removeObject(forKey: key)
        return imported ? .imported(durable.count) : .alreadyImported
    }
}
