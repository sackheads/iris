import Foundation

/// The dollars a paid bake-off run may spend (#783), shared by every arm that names the same file.
/// Append-only, one JSON line per event, read and written under `flock`, so arms running together
/// see one true total and a crash loses nothing already written:
///
/// - before a call, under the lock: re-read the total; refuse if the total plus this call's bound
///   would pass the cap; else append `{"arm", "reserve", "id"}`;
/// - after it: append `{"arm", "settle": id, "dollars", "tokens_…"}`, which replaces the reserve.
///
/// The total is every settled call's dollars plus every reserve not yet settled, so a call in
/// flight in another process already counts. A reserve left by a crash keeps counting, which errs
/// toward stopping. A ledger that exists but can't be read or parsed stops the run: it never reads
/// as $0. Without a file the same rules hold in memory, for one arm.
final class SpendLedger: @unchecked Sendable {
    enum LedgerError: Error, Equatable, LocalizedError {
        case unreadable(String)
        case corrupt(line: Int)
        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "the spend ledger can't be read: \(why)"
            case .corrupt(let line): return "the spend ledger is damaged at line \(line); fix or remove it before spending more"
            }
        }
    }

    let arm: String
    let cap: Double
    private let path: String?
    private let lock = NSLock()
    private var memory = Data()

    init(path: String?, arm: String, cap: Double) throws {
        self.path = path.map { ($0 as NSString).expandingTildeInPath }
        self.arm = arm
        self.cap = cap
        _ = try total()   // a damaged or unreadable ledger stops the run before its first call
    }

    /// Settled dollars plus unsettled reserves.
    func total() throws -> Double { try locked { try Self.total(of: $0) } }

    /// Reserves `bound` for one call, or nil when it would pass the cap.
    func reserve(_ bound: Double) throws -> UUID? {
        try locked { data in
            guard try Self.total(of: data) + bound <= cap else { return nil }
            let id = UUID()
            try append(["arm": arm, "reserve": bound, "id": id.uuidString])
            return id
        }
    }

    func settle(_ id: UUID, dollars: Double, tokens: (input: Int, output: Int, thought: Int)) throws {
        try locked { _ in
            try append(["arm": arm, "settle": id.uuidString, "dollars": dollars,
                        "tokens_in": tokens.input, "tokens_out": tokens.output, "tokens_thought": tokens.thought])
        }
    }

    static func total(of data: Data) throws -> Double {
        var reserved: [String: Double] = [:], dollars = 0.0
        for (n, line) in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { throw LedgerError.corrupt(line: n + 1) }
            if let id = row["id"] as? String, let amount = (row["reserve"] as? NSNumber)?.doubleValue {
                reserved[id] = amount
            } else if let id = row["settle"] as? String, let paid = (row["dollars"] as? NSNumber)?.doubleValue {
                reserved[id] = nil
                dollars += paid
            } else {
                throw LedgerError.corrupt(line: n + 1)
            }
        }
        return dollars + reserved.values.reduce(0, +)
    }

    // MARK: - The file

    private var fd: Int32 = -1

    /// Runs `body` on the ledger's whole content with the in-process lock and, for a file, an
    /// exclusive `flock` held throughout.
    private func locked<T>(_ body: (Data) throws -> T) throws -> T {
        try lock.withLock {
            guard let path else { return try body(memory) }
            let fd = open(path, O_RDWR | O_CREAT | O_APPEND, 0o644)
            guard fd >= 0 else { throw LedgerError.unreadable("\(path): \(String(cString: strerror(errno)))") }
            defer { close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { throw LedgerError.unreadable("\(path): can't lock it") }
            defer { flock(fd, LOCK_UN) }
            self.fd = fd
            defer { self.fd = -1 }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
            guard lseek(fd, 0, SEEK_SET) == 0 else { throw LedgerError.unreadable("\(path): can't seek") }
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0 { throw LedgerError.unreadable("\(path): \(String(cString: strerror(errno)))") }
                if n == 0 { break }
                data.append(buffer, count: n)
            }
            return try body(data)
        }
    }

    /// Appends one line; called only inside `locked`.
    private func append(_ row: [String: Any]) throws {
        let line = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data("\n".utf8)
        guard path != nil else { memory.append(line); return }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
        guard written == line.count else { throw LedgerError.unreadable("write failed: \(String(cString: strerror(errno)))") }
    }
}
