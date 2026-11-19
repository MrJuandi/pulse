import Foundation
import SQLite3

private struct UsageRecord {
    let time: Date
    let model: String
    let tokens: Int
}

actor LocalHistory {
    static let shared = LocalHistory()

    private struct FileVersion: Equatable {
        let size: Int
        let modified: Date
        let walSize: Int?
        let walModified: Date?

        init?(_ url: URL) {
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
            guard let values = try? url.resourceValues(forKeys: keys),
                  let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
            self.size = size
            self.modified = modified
            let wal = try? URL(fileURLWithPath: url.path + "-wal").resourceValues(forKeys: keys)
            walSize = wal?.fileSize
            walModified = wal?.contentModificationDate
        }
    }

    private let files = FileManager.default
    private let iso = ISO8601DateFormatter()
    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private var cache: [Provider: [URL: (FileVersion, [String: UsageRecord])]] = [:]

    func read(_ provider: Provider) -> [Day]? {
        let roots = roots(for: provider)
        guard roots.contains(where: { files.fileExists(atPath: $0.path) }) else { return nil }
        let cutoff = Calendar.current.date(byAdding: .day, value: -89,
                                           to: Calendar.current.startOfDay(for: .now)) ?? .now
        let paths = roots.flatMap { url in
            provider == .antigravity
                ? (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                : (files.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                    options: [.skipsHiddenFiles])?.allObjects as? [URL]) ?? []
        }
        var updated: [URL: (FileVersion, [String: UsageRecord])] = [:]
        var distinct: [String: UsageRecord] = [:]
        var failed = false
        for path in Set(paths).sorted(by: { $0.path < $1.path }) {
            guard path.pathExtension == (provider == .antigravity ? "db" : "jsonl"),
                  provider != .codex || path.lastPathComponent.hasPrefix("rollout-"),
                  provider != .antigravity || UUID(uuidString: path.deletingPathExtension().lastPathComponent) != nil,
                  let version = FileVersion(path), version.modified >= cutoff else { continue }
            let records: [String: UsageRecord]?
            if let entry = cache[provider]?[path], entry.0 == version {
                records = entry.1
            } else {
                switch provider {
                case .codex: records = readCodex(path)
                case .claude: records = readClaude(path)
                case .antigravity: records = readAntigravity(path)
                }
            }
            guard let records else { failed = true; continue }
            updated[path] = (version, records)
            for (key, item) in records where item.time >= cutoff {
                if distinct[key].map({ $0.tokens > item.tokens }) != true {
                    distinct[key] = item
                }
            }
        }
        cache[provider] = updated
        if failed && distinct.isEmpty { return nil }
        var grouped: [String: [String: Int]] = [:]
        for item in distinct.values {
            grouped[dateFormat.string(from: item.time), default: [:]][item.model, default: 0] += item.tokens
        }
        return grouped.keys.sorted().map { date in
            let breakdown = grouped[date, default: [:]]
            return Day(date: date, totalTokens: breakdown.values.reduce(0, +),
                       modelBreakdowns: breakdown.keys.sorted().map {
                Model(modelName: $0, totalTokens: breakdown[$0])
            })
        }
    }

    private func roots(for provider: Provider) -> [URL] {
        let home = files.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        func directory(_ key: String, or fallback: String) -> URL {
            if let value = env[key], value.hasPrefix("/") { return URL(fileURLWithPath: value) }
            return home.appendingPathComponent(fallback)
        }
        switch provider {
        case .codex:
            let codex = directory("CODEX_HOME", or: ".codex")
            return ["sessions", "archived_sessions"].map { codex.appendingPathComponent($0) }
        case .claude:
            return [directory("CLAUDE_CONFIG_DIR", or: ".claude").appendingPathComponent("projects")]
        case .antigravity:
            let gemini = directory("GEMINI_CLI_HOME", or: ".gemini")
            return ["antigravity", "antigravity-cli", "antigravity-ide", "antigravity-acp"].flatMap {
                let root = gemini.appendingPathComponent($0)
                return [root.appendingPathComponent("conversations"), root]
            }
        }
    }

    private func timestamp(_ raw: Any?) -> Date? {
        guard let raw = raw as? String else { return nil }
        return isoFractional.date(from: raw) ?? iso.date(from: raw)
    }

    private func count(_ data: [String: Any], _ key: String) -> Int {
        guard let value = data[key] as? Int, (0...100_000_000_000).contains(value) else { return 0 }
        return value
    }

    private func readLines(_ path: URL, containing markers: [String], consume: ([String: Any]) -> Void) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: path) else { return false }
        defer { try? file.close() }
        let needles = markers.map { Data($0.utf8) }
        var pending = Data()
        do {
            while let chunk = try file.read(upToCount: 256 * 1024), !chunk.isEmpty {
                pending.append(chunk)
                var cursor = pending.startIndex
                while let newline = pending[cursor...].firstIndex(of: 10) {
                    let line = pending[cursor..<newline]
                    if needles.contains(where: { line.range(of: $0) != nil }),
                       let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        consume(row)
                    }
                    cursor = newline + 1
                }
                pending.removeSubrange(pending.startIndex..<cursor)
                if pending.count > 64 * 1024 * 1024 { return false }
            }
            if !pending.isEmpty, let row = try? JSONSerialization.jsonObject(with: pending) as? [String: Any] {
                consume(row)
            }
            return true
        } catch {
            return false
        }
    }

    private func readCodex(_ path: URL) -> [String: UsageRecord]? {
        var model = "Unknown model"
        var previous = 0
        var entries: [String: UsageRecord] = [:]
        let read = readLines(path, containing: ["\"turn_context\"", "\"session_meta\"", "\"token_count\""]) { row in
            guard let type = row["type"] as? String, let payload = row["payload"] as? [String: Any] else { return }
            if ["turn_context", "session_meta"].contains(type), let active = payload["model"] as? String {
                model = active
            }
            guard type == "event_msg", payload["type"] as? String == "token_count",
                  let date = timestamp(row["timestamp"]),
                  let metrics = payload["info"] as? [String: Any],
                  let last = metrics["last_token_usage"] as? [String: Any] else { return }
            let total = count(metrics["total_token_usage"] as? [String: Any] ?? [:], "total_tokens")
            if total > 0 && previous == total { return }
            if total > 0 { previous = total }
            var tokens = count(last, "total_tokens")
            if tokens == 0 {
                tokens = count(last, "input_tokens") + count(last, "output_tokens")
                if metrics["last_usage_includes_reasoning"] as? Bool == false {
                    tokens += count(last, "reasoning_output_tokens")
                }
            }
            guard tokens > 0 else { return }
            let fingerprint = "\(date.timeIntervalSince1970):\(total):\(tokens)"
            entries[fingerprint] = UsageRecord(time: date, model: model, tokens: tokens)
        }
        return read ? entries : nil
    }

    private func readClaude(_ path: URL) -> [String: UsageRecord]? {
        var entries: [String: UsageRecord] = [:]
        let read = readLines(path, containing: ["\"assistant\""]) { row in
            guard row["type"] as? String == "assistant",
                  let message = row["message"] as? [String: Any],
                  let id = message["id"] as? String ?? row["uuid"] as? String,
                  let usage = message["usage"] as? [String: Any],
                  let date = timestamp(row["timestamp"]) else { return }
            let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .reduce(0) { $0 + count(usage, $1) }
            guard tokens > 0, entries[id].map({ $0.tokens > tokens }) != true else { return }
            entries[id] = UsageRecord(time: date, model: message["model"] as? String ?? "Unknown model", tokens: tokens)
        }
        return read ? entries : nil
    }

    private func readAntigravity(_ url: URL) -> [String: UsageRecord]? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        if sqlite3_open_v2(url.absoluteString + "?mode=ro", &db, flags, nil) != SQLITE_OK {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        sqlite3_exec(db, "PRAGMA trusted_schema=OFF; BEGIN", nil, nil, nil)
        struct Step: Hashable {
            let root: Data
            let bot: Data
        }
        var times: [Step: UInt64] = [:]
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT metadata FROM steps WHERE metadata IS NOT NULL", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let fields = blob(statement, 0).flatMap(ProtoFields.init),
                      let root = fields.bytes[12], let bot = fields.child(9)?.bytes[7],
                      let seconds = fields.child(1)?.numbers[1] else { continue }
                let step = Step(root: root, bot: bot)
                times[step] = min(times[step] ?? seconds, seconds)
            }
        }
        sqlite3_finalize(statement)
        statement = nil
        guard sqlite3_prepare_v2(db, "SELECT idx, data FROM gen_metadata WHERE data IS NOT NULL", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        var result: [String: UsageRecord] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let fields = blob(statement, 1).flatMap(ProtoFields.init),
                  let chat = fields.child(1), let usage = chat.child(4) else { continue }
            let related = Step(root: fields.bytes[4] ?? Data(), bot: usage.bytes[7] ?? Data())
            let seconds = chat.child(9)?.child(4)?.numbers[1] ?? times[related] ?? 0
            guard (946_684_800...4_102_444_800).contains(seconds) else { continue }
            let output = usage.counter(3)
            let tokens = usage.counter(2) + usage.counter(5)
                + (output > 0 ? output : usage.counter(9) + usage.counter(10))
            guard tokens > 0 else { continue }
            let model = chat.bytes[19].flatMap { String(data: $0, encoding: .utf8) }
                ?? "Model \(usage.counter(1))"
            let id = usage.bytes[7]?.base64EncodedString() ?? String(sqlite3_column_int64(statement, 0))
            let key = "\(url.deletingPathExtension().lastPathComponent):\(id)"
            result[key] = UsageRecord(time: Date(timeIntervalSince1970: Double(seconds)),
                                      model: model, tokens: tokens)
        }
        return result
    }

    private func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        let size = Int(sqlite3_column_bytes(statement, column))
        guard size > 0, size <= 64 * 1024 * 1024, let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: size)
    }
}

private struct ProtoFields {
    var bytes: [UInt64: Data] = [:]
    var numbers: [UInt64: UInt64] = [:]

    func child(_ key: UInt64) -> Self? { bytes[key].flatMap(Self.init) }
    func counter(_ key: UInt64) -> Int {
        let value = numbers[key, default: 0]
        return value <= 100_000_000_000 ? Int(value) : 0
    }

    init?(_ data: Data) {
        var cursor = data.startIndex
        func integer() -> UInt64? {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard cursor < data.endIndex else { return nil }
                let byte = data[cursor]
                cursor += 1
                if shift == 63 && byte > 1 { return nil }
                result |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return result }
            }
            return nil
        }
        while cursor < data.endIndex {
            guard let tag = integer(), tag >> 3 > 0 else { return nil }
            let field = tag >> 3
            switch tag & 7 {
            case 0:
                guard let value = integer() else { return nil }
                numbers[field] = value
            case 1, 5:
                let width = (tag & 7) == 1 ? 8 : 4
                guard width <= data.endIndex - cursor else { return nil }
                cursor += width
            case 2:
                guard let width = integer(), width <= UInt64(data.endIndex - cursor) else { return nil }
                let end = cursor + Int(width)
                bytes[field] = data[cursor..<end]
                cursor = end
            default: return nil
            }
        }
    }
}
