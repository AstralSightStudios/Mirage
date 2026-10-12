import Foundation

/// The whole file tree of a running device, through its NSH console.
///
/// Listings come from `ls -l`. Downloads use `cat`: the console only adds a
/// carriage return before every line feed (ONLCR), which is undone. The
/// console's input side echoes and edits lines, so uploads are `printf`
/// command lines: printable runs as quoted strings, every other byte as a
/// `\xNN` argument (one byte per argument is all NSH's printf takes).
@MainActor
public final class ShellFileSystem: GuestFileSystem {
    private let session: DeviceSession
    private let unstatable: Set<String>
    private var prompt: Data?
    private var queue: Task<Void, Never> = Task {}

    public nonisolated var isReadOnly: Bool { false }

    /// Lines NSH accepts: CONFIG_NSH_LINELEN and argument count limits of
    /// the firmware builds.
    private static let maxLine = 160
    private static let maxArgs = 20

    /// `unstatable`: directories listed by name only (see
    /// DeviceFiles.unstatableDirectories).
    public init(session: DeviceSession, unstatable: Set<String> = []) {
        self.session = session
        self.unstatable = unstatable
    }

    /// Checks that the console answers (some firmwares have none).
    public func connect() async throws {
        _ = try await serialized { try await self.learnPrompt() }
    }

    // MARK: Console exchange

    private func serialized<T>(_ op: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = queue
        let task = Task { @MainActor () async throws -> T in
            await previous.value
            return try await op()
        }
        queue = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Sends `text` and collects console output until `marker` shows up.
    private func exchange(_ text: String, until marker: Data, timeout: TimeInterval,
                          onData: ((Int) -> Void)? = nil) async throws -> Data {
        guard session.consoleConnected else { throw MirageError.process("The console is not connected") }
        var buffer = Data()
        var finished = false
        var lastData = Date()
        var continuation: CheckedContinuation<Void, Error>?
        let token = session.observeConsole(replay: false) { data in
            let searchFrom = max(0, buffer.count - marker.count)
            buffer.append(data)
            lastData = Date()
            onData?(buffer.count)
            if !finished, buffer.range(of: marker, in: searchFrom..<buffer.count) != nil {
                finished = true
                continuation?.resume()
                continuation = nil
            }
        }
        defer { session.removeObserver(token) }
        session.sendConsole(Data(text.utf8))
        let watchdog = Task { @MainActor in
            while !finished && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !finished && Date().timeIntervalSince(lastData) > timeout {
                    finished = true
                    continuation?.resume(throwing: MirageError.process("The device's shell did not answer"))
                    continuation = nil
                }
            }
        }
        defer { watchdog.cancel() }
        if !finished {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if finished { c.resume() } else { continuation = c }
            }
        }
        if buffer.range(of: marker) == nil { throw MirageError.process("The device's shell did not answer") }
        return buffer
    }

    private func learnPrompt() async throws -> Data {
        if let prompt { return prompt }
        let nonce = Self.nonce()
        let marker = Data("\r\n\(nonce)\r\n".utf8)
        _ = try await exchange("echo \(nonce)\r", until: marker, timeout: 10)
        try await Task.sleep(nanoseconds: 150_000_000)
        let history = session.consoleHistory.data
        guard let r = history.range(of: marker, options: .backwards) else { throw MirageError.process("The device's shell did not answer") }
        let tail = String(decoding: history[r.upperBound...], as: UTF8.self)
        let pattern = try NSRegularExpression(pattern: "^[A-Za-z0-9_.-]{1,16}> (\\x1b\\[K)?")
        guard let m = pattern.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
              let range = Range(m.range, in: tail) else {
            throw MirageError.process("The device's shell prompt was not recognized")
        }
        let p = Data(tail[range].utf8)
        prompt = p
        return p
    }

    /// Runs one command line; returns its raw output.
    private func command(_ line: String, timeout: TimeInterval = 15, onData: ((Int) -> Void)? = nil) async throws -> Data {
        let prompt = try await learnPrompt()
        let nonce = Self.nonce()
        let marker = Data("\r\n\(nonce)\r\n".utf8)
        let raw = try await exchange("\(line)\recho \(nonce)\r", until: marker, timeout: timeout, onData: onData)
        let echo = Data("\(line)\r\n".utf8)
        let start = raw.range(of: echo)?.upperBound ?? raw.startIndex
        guard let next = raw.range(of: Data("echo \(nonce)\r\n".utf8), in: start..<raw.endIndex) else {
            throw MirageError.process("Unexpected console output")
        }
        var end = next.lowerBound
        if raw[start..<end].suffix(prompt.count) == prompt { end -= prompt.count }
        return raw.subdata(in: start..<end)
    }

    /// Syslog lines some firmwares print on the console (Band 9 Pro).
    private static let logLine = try! NSRegularExpression(pattern: "(?m)^.*\\[\\d\\d/\\d\\d \\d\\d:\\d\\d:\\d\\d\\] \\[.*\\n?")

    private func text(_ line: String) async throws -> String {
        let out = try await command(line)
        var s = String(decoding: out, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        s = Self.logLine.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        if let err = s.split(separator: "\n").first(where: { $0.hasPrefix("nsh: ") }) {
            throw MirageError.process(String(err.dropFirst(5)))
        }
        return s
    }

    private static func nonce() -> String {
        "mirage" + String(UInt64.random(in: 0..<UInt64.max), radix: 36)
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s {
            if c == "\"" || c == "\\" || c == "$" || c == "`" { out.append("\\") }
            out.append(c)
        }
        return out + "\""
    }

    // MARK: Listing

    private static let lsLine = try! NSRegularExpression(pattern: "^\\s*([-dlcbps][-rwxsStT]{9})\\s+(\\d+)\\s+(.+)$")

    private func entries(_ path: String) async throws -> [GuestEntry] {
        if unstatable.contains(path) {
            let out = try await text("ls \(Self.quote(path))")
            return out.split(separator: "\n").dropFirst().compactMap { line in
                var name = line.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                let isDir = name.hasSuffix("/")
                if isDir { name.removeLast() }
                return GuestEntry(name: name, path: GuestPath.join(path, name), isDirectory: isDir, size: 0)
            }
        }
        let out = try await text("ls -l \(Self.quote(path))")
        var result: [GuestEntry] = []
        for line in out.split(separator: "\n") {
            let s = String(line)
            guard let m = Self.lsLine.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let modeR = Range(m.range(at: 1), in: s), let sizeR = Range(m.range(at: 2), in: s),
                  let nameR = Range(m.range(at: 3), in: s) else { continue }
            var name = String(s[nameR])
            let mode = String(s[modeR])
            let isDir = mode.hasPrefix("d") || name.hasSuffix("/")
            if name.hasSuffix("/") { name.removeLast() }
            result.append(GuestEntry(name: GuestPath.name(name), path: name.hasPrefix("/") ? name : GuestPath.join(path, name),
                                     isDirectory: isDir, size: Int64(s[sizeR]) ?? 0, mode: mode))
        }
        return result
    }

    public func list(_ path: String) async throws -> [GuestEntry] {
        try await serialized {
            try await self.entries(path).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: Files

    public func read(_ path: String, progress: (@Sendable (Double) -> Void)?) async throws -> Data {
        try await serialized {
            let info = try await self.entries(path).first
            if let info, info.path != path { throw MirageError.invalid("\(path) is a directory") }
            let size = Int(info?.size ?? 0)
            let raw = try await self.command("cat \(Self.quote(path))", timeout: 20) { got in
                if size > 0 { progress?(min(1, Double(got) / Double(size))) }
            }
            var data = Data(capacity: raw.count)
            var i = raw.startIndex
            while i < raw.endIndex {
                let b = raw[i]
                if b == 0x0D, raw.index(after: i) < raw.endIndex, raw[raw.index(after: i)] == 0x0A {
                    i = raw.index(after: i)
                    continue
                }
                data.append(b)
                i = raw.index(after: i)
            }
            if size > 0 && data.count != size {
                let s = String(decoding: data.prefix(120), as: UTF8.self)
                if s.hasPrefix("nsh: ") { throw MirageError.process(String(s.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)) }
                throw MirageError.io("Read \(data.count) of \(size) bytes from \(path); console output was interleaved")
            }
            return data
        }
    }

    /// Bytes NSH's parser may act on even inside double quotes (a quoted
    /// token ending in ">" is taken for a redirection).
    private static let metacharacters: Set<UInt8> = Set("\"\\$`<>|&;#'".utf8)

    /// printf argument lists, each fitting one NSH command line.
    static func printfLines(_ data: Data, target: String) -> [String] {
        let quotedTarget = quote(target)
        var lines: [String] = []
        var args: [String] = []
        var length = 0
        var run = ""
        func flushRun() {
            guard !run.isEmpty else { return }
            args.append("\"" + run + "\"")
            length += run.count + 3
            run = ""
        }
        func flushLine() {
            flushRun()
            guard !args.isEmpty else { return }
            let redirect = lines.isEmpty ? ">" : ">>"
            lines.append("printf " + args.joined(separator: " ") + " \(redirect) " + quotedTarget)
            args = []
            length = 0
        }
        let budget = maxLine - quotedTarget.count - 12
        for b in data {
            let safe = b >= 0x20 && b < 0x7F && !Self.metacharacters.contains(b)
            if safe {
                if length + run.count + 3 >= budget || args.count + 1 >= maxArgs { flushLine() }
                run.append(Character(UnicodeScalar(b)))
            } else {
                flushRun()
                if length + 7 >= budget || args.count + 1 >= maxArgs { flushLine() }
                args.append(String(format: "\\\\x%02x", b))
                length += 7
            }
        }
        flushLine()
        return lines
    }

    public func write(_ path: String, data: Data, progress: (@Sendable (Double) -> Void)?) async throws {
        try await serialized {
            if data.isEmpty {
                _ = try await self.text("echo -n \"\" > \(Self.quote(path))")
                return
            }
            let lines = Self.printfLines(data, target: path)
            for (i, line) in lines.enumerated() {
                _ = try await self.text(line)
                progress?(Double(i + 1) / Double(lines.count))
            }
        }
    }

    public func createDirectory(_ path: String) async throws {
        try await serialized { _ = try await self.text("mkdir \(Self.quote(path))") }
    }

    private func removeTree(_ path: String, isDirectory: Bool) async throws {
        if isDirectory {
            for e in try await entries(path) {
                try await removeTree(e.path, isDirectory: e.isDirectory)
            }
            _ = try await text("rmdir \(Self.quote(path))")
        } else {
            _ = try await text("rm \(Self.quote(path))")
        }
    }

    public func remove(_ path: String) async throws {
        try await serialized {
            let parent = try await self.entries(GuestPath.parent(path))
            let isDir = parent.first { $0.name == GuestPath.name(path) }?.isDirectory ?? false
            try await self.removeTree(path, isDirectory: isDir)
        }
    }

    public func rename(_ path: String, to newPath: String) async throws {
        try await serialized { _ = try await self.text("mv \(Self.quote(path)) \(Self.quote(newPath))") }
    }
}
