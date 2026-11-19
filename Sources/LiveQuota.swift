import Darwin
import Foundation

enum LiveQuota {
    static func read(_ provider: Provider) async -> [Quota]? {
        switch provider {
        case .codex: return await Task.detached(priority: .utility) { codex() }.value
        case .claude: return await Task.detached(priority: .utility) { claude() }.value
        case .antigravity: return await antigravity()
        }
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let environment = ProcessInfo.processInfo.environment

    private static func executable(_ name: String, fallback: [String] = []) -> URL? {
        let paths = ["\(home.path)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (paths.map { "\($0)/\(name)" } + fallback)
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    private static func codex() -> [Quota]? {
        let desktop = "/Applications/ChatGPT.app/Contents/Resources/codex-cli"
        guard let binary = executable("codex", fallback: [
            "\(desktop)/CodexCLI.app/Contents/MacOS/codex",
            "\(desktop)/codex-path/codex"
        ]) else { return nil }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = binary
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer {
            try? input.fileHandleForWriting.close()
            stop(process)
        }
        let writer = input.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        let deadline = Date.now.addingTimeInterval(12)
        var buffer = Data()
        func send(_ message: String) -> Bool {
            do {
                try writer.write(contentsOf: Data((message + "\n").utf8))
                return true
            } catch { return false }
        }
        func result(_ id: Int) -> [String: Any]? {
            let fd = output.fileHandleForReading.fileDescriptor
            while Date.now < deadline {
                while let end = buffer.firstIndex(of: 10) {
                    let packet = buffer[..<end]
                    buffer.removeSubrange(...end)
                    if let json = try? JSONSerialization.jsonObject(with: packet) as? [String: Any],
                       json["id"] as? Int == id {
                        return json["result"] as? [String: Any]
                    }
                }
                guard let bytes = readChunk(fd), buffer.count < 1_000_000 else { return nil }
                buffer.append(bytes)
            }
            return nil
        }
        guard send(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"pulse","version":"2.0.0"}}}"#),
              result(1) != nil, send(#"{"method":"initialized"}"#),
              send(#"{"id":2,"method":"account/rateLimits/read"}"#),
              let sample = result(2) else { return nil }
        let buckets = sample["rateLimitsByLimitId"] as? [String: [String: Any]]
        return windows(buckets?["codex"] ?? sample["rateLimits"] as? [String: Any])
    }

    private static func windows(_ limits: [String: Any]?) -> [Quota] {
        ["primary", "secondary"].compactMap { key in
            guard let bucket = limits?[key] as? [String: Any],
                  let percent = bucket["usedPercent"] as? Double,
                  percent.isFinite, (0...100).contains(percent) else { return nil }
            let reset = (bucket["resetsAt"] as? Double).map {
                iso(Date(timeIntervalSince1970: $0))
            }
            return Quota(label: key, usedPercent: percent,
                         windowMinutes: bucket["windowDurationMins"] as? Int, resetsAt: reset)
        }
    }

    private static func claude() -> [Quota]? {
        guard let binary = executable("claude"), let directory = claudeWorkspace() else { return nil }
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 100, ws_col: 140, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return nil }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        defer { close(master) }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--strict-mcp-config", "--allowed-tools", "", "--setting-sources", "",
                             "--settings", #"{"disableAllHooks":true,"remoteControlAtStartup":false}"#]
        process.currentDirectoryURL = directory
        process.environment = environment.merging(["TERM": "xterm-256color", "LANG": "en_US.UTF-8"]) { _, new in new }
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        do { try process.run() } catch { return nil }
        try? terminal.close()
        defer {
            writeTerminal("\u{03}\u{03}", fd: master)
            stop(process)
        }
        var buffer = Data()
        var sent = false
        var trusted = false
        var firstReading: Date?
        var measured: [Quota] = []
        var readyAfter = Date.now.addingTimeInterval(3)
        let deadline = Date.now.addingTimeInterval(25)
        while Date.now < deadline {
            guard let chunk = readChunk(master), buffer.count < 1_000_000 else { break }
            buffer.append(chunk)
            if sent {
                let values = claudeWindows(terminalText(buffer))
                if !values.isEmpty { measured = values }
                if values.count == 2 { return values }
                if !values.isEmpty && firstReading == nil { firstReading = .now }
                // Plans may expose only one window. Give the panel time to finish rendering.
                if let firstReading, Date.now.timeIntervalSince(firstReading) > 2 { return measured }
            } else {
                let screen = terminalText(buffer)
                if screen.contains("quicksafetycheck") {
                    // This is a private directory created by Pulse, never the user's project.
                    guard !trusted, Date.now >= readyAfter,
                          directory.path == process.currentDirectoryURL?.path else { continue }
                    guard screen.contains("yes,itrustthisfolder"), screen.contains("❯no,exit") else { continue }
                    writeTerminal("\u{1b}[B", fd: master)
                    Thread.sleep(forTimeInterval: 0.5)
                    writeTerminal("\r", fd: master)
                    trusted = true
                    readyAfter = Date.now.addingTimeInterval(2)
                    buffer.removeAll()
                } else if Date.now >= readyAfter, screen.contains("❯"), (trusted || screen.contains("claudecode")),
                          !screen.contains("selectloginmethod"), !screen.contains("logintoclaude") {
                    writeTerminal("/usage", fd: master)
                    Thread.sleep(forTimeInterval: 0.3)
                    writeTerminal("\r", fd: master)
                    sent = true
                    buffer.removeAll()
                }
            }
        }
        return measured.isEmpty ? nil : measured
    }

    private static func claudeWorkspace() -> URL? {
        let directory = home.appendingPathComponent("Library/Application Support/Pulse/ClaudeQuota", isDirectory: true)
        let files = FileManager.default
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            let type = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let path = directory.resolvingSymlinksInPath()
            guard type.isDirectory == true, type.isSymbolicLink != true, path.path == directory.path,
                  try files.contentsOfDirectory(atPath: directory.path).isEmpty else { return nil }
            return directory
        } catch { return nil }
    }

    private static func terminalText(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .lowercased()
    }

    private static func claudeWindows(_ screen: String) -> [Quota] {
        [("currentsession", 300), ("currentweek(allmodels)", 10080)].compactMap { title, minutes in
            let escaped = NSRegularExpression.escapedPattern(for: title)
            let pattern = escaped + #"(?:(?!current(?:session|week)).){0,260}?(\d{1,3}(?:\.\d+)?)%used"#
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.matches(in: screen, range: NSRange(screen.startIndex..., in: screen)).last,
                  let amount = Range(match.range(at: 1), in: screen),
                  let percent = Double(screen[amount]), (0...100).contains(percent) else { return nil }
            let textAfter = Range(match.range, in: screen).map { String(screen[$0.upperBound...].prefix(190)) } ?? ""
            return Quota(label: title, usedPercent: percent, windowMinutes: minutes, resetsAt: claudeReset(textAfter))
        }
    }

    private static func claudeReset(_ text: String) -> String? {
        let regex = try? NSRegularExpression(pattern: #"^resets(?:([a-z]{3})(\d{1,2})at)?(\d{1,2})(?::(\d{2}))?(am|pm)\(([a-z_]+/[a-z_+-]+)\)"#)
        guard let match = regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ offset: Int) -> String? { Range(match.range(at: offset), in: text).map { String(text[$0]) } }
        guard let hour = group(3).flatMap(Int.init), (1...12).contains(hour) else { return nil }
        let zone = group(6).flatMap { id in
            TimeZone.knownTimeZoneIdentifiers.first { $0.lowercased() == id }.flatMap(TimeZone.init(identifier:))
        } ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var parts = calendar.dateComponents([.year, .month, .day], from: .now)
        if let name = group(1), let day = group(2).flatMap(Int.init),
           let month = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: name) {
            parts.month = month + 1
            parts.day = day
        }
        parts.hour = hour % 12 + (group(5) == "pm" ? 12 : 0)
        parts.minute = group(4).flatMap(Int.init) ?? 0
        guard let date = calendar.date(from: parts) else { return nil }
        if date > .now { return iso(date) }
        return calendar.date(byAdding: group(1) == nil ? .day : .year, value: 1, to: date).map(iso)
    }

    private static func antigravity() async -> [Quota]? {
        let addresses = await Task.detached(priority: .utility) { antigravityAddresses() }.value
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0,
                                            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config, delegate: LocalOnlyHTTP(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for (port, token) in addresses {
            guard let url = URL(string: "http://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try? JSONDecoder().decode(AntigravitySummary.self, from: data) else { continue }
            let windows = body.response.groups.flatMap(\.buckets).compactMap { bucket -> Quota? in
                guard bucket.bucketId.hasPrefix("gemini-"), let fraction = bucket.remainingFraction,
                      (0...1).contains(fraction) else { return nil }
                let duration: Int? = switch bucket.window.lowercased() {
                case "session", "5h", "five_hour": 300
                case "weekly", "week", "7d": 10080
                default: nil
                }
                return Quota(label: bucket.bucketId, usedPercent: (1 - fraction) * 100,
                             windowMinutes: duration, resetsAt: bucket.resetTime)
            }
            if !windows.isEmpty { return windows }
        }
        return nil
    }

    private static func antigravityAddresses() -> [(Int, String)] {
        let executable = "Antigravity.app/Contents/Resources/bin/language_server"
        let installed = ["/Applications/\(executable)", "\(home.path)/Applications/\(executable)"]
        let listing = capture("/bin/ps", ["-axo", "pid=,comm="]) ?? ""
        return listing.split(separator: "\n").flatMap { row -> [(Int, String)] in
            let fields = row.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int(fields[0]), installed.contains(String(fields[1])),
                  let args = capture("/bin/ps", ["-ww", "-p", String(pid), "-o", "command="]),
                  let tokenRange = args.range(of: #"(?<=--csrf_token[= ])[A-Za-z0-9_-]+"#, options: .regularExpression),
                  let sockets = capture("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]) else { return [] }
            let token = String(args[tokenRange])
            return sockets.split(separator: "\n").compactMap { line in
                guard line.hasPrefix("n127.0.0.1:") || line.hasPrefix("n[::1]:") || line.hasPrefix("n*:"),
                      let port = line.split(separator: ":").last.flatMap({ Int($0) }),
                      (1...65535).contains(port) else { return nil }
                return (port, token)
            }
        }
    }

    private static func capture(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer { stop(process) }
        let start = Date.now
        var data = Data()
        while Date.now.timeIntervalSince(start) < 3, data.count < 1_000_000 {
            guard let bytes = readChunk(output.fileHandleForReading.fileDescriptor) else { return String(decoding: data, as: UTF8.self) }
            data.append(bytes)
        }
        return nil
    }

    private static func readChunk(_ fd: Int32) -> Data? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 120)
        if ready == 0 { return Data() }
        guard ready > 0 else { return errno == EINTR ? Data() : nil }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        return count > 0 ? Data(bytes.prefix(count)) : nil
    }

    private static func writeTerminal(_ value: String, fd: Int32) {
        let bytes = Data(value.utf8)
        bytes.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    private static func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
        for _ in 0..<6 where process.isRunning { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

private struct AntigravitySummary: Decodable {
    struct Response: Decodable {
        struct Group: Decodable {
            let buckets: [Bucket]
        }
        let groups: [Group]
    }
    struct Bucket: Decodable {
        let bucketId: String
        let window: String
        let remainingFraction: Double?
        let resetTime: String?
    }
    let response: Response
}

private final class LocalOnlyHTTP: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
