import Foundation

/// QEMU Machine Protocol client (JSON lines over a unix socket).
public final class QMPClient: @unchecked Sendable {
    private let socket: StreamSocket
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var nextID = 1
    private var closed = false
    private var eventHandler: (@Sendable (String, [String: Any]) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?

    private init(socket: StreamSocket) {
        self.socket = socket
    }

    public static func connect(path: String, timeout: TimeInterval = 10) async throws -> QMPClient {
        let s = try await StreamSocket.connect(unix: path, timeout: timeout)
        let client = QMPClient(socket: s)
        // a monitor that already has a client never greets
        s.setReadTimeout(3)
        let greeting = try client.readLineBlocking()
        s.setReadTimeout(0)
        guard let obj = try JSONSerialization.jsonObject(with: greeting) as? [String: Any], obj["QMP"] != nil else {
            throw MirageError.protocolError("Unexpected QMP greeting")
        }
        client.startReader()
        _ = try await client.execute("qmp_capabilities")
        return client
    }

    public func onEvent(_ handler: @escaping @Sendable (String, [String: Any]) -> Void) {
        lock.lock()
        eventHandler = handler
        lock.unlock()
    }

    public func onClose(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        closeHandler = handler
        lock.unlock()
    }

    private var buffer = Data()

    private func readLineBlocking() throws -> Data {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                return Data(line)
            }
            let chunk = try socket.read()
            if chunk.isEmpty { throw MirageError.io("QMP connection closed") }
            buffer.append(chunk)
        }
    }

    private func startReader() {
        let t = Thread { [weak self] in
            while let self {
                guard let line = try? self.readLineBlocking() else { break }
                self.dispatch(line)
            }
            self?.finish()
        }
        t.name = "QMP reader"
        t.start()
    }

    private func dispatch(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if let event = obj["event"] as? String {
            lock.lock()
            let h = eventHandler
            lock.unlock()
            h?(event, obj["data"] as? [String: Any] ?? [:])
            return
        }
        guard let id = obj["id"] as? Int else { return }
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        if let err = obj["error"] as? [String: Any] {
            cont?.resume(throwing: MirageError.protocolError(err["desc"] as? String ?? "QMP error"))
        } else {
            cont?.resume(returning: obj["return"] ?? [:])
        }
    }

    private func finish() {
        lock.lock()
        closed = true
        let waiting = pending
        pending.removeAll()
        let h = closeHandler
        lock.unlock()
        for c in waiting.values { c.resume(throwing: MirageError.io("QMP connection closed")) }
        h?()
    }

    @discardableResult
    public func execute(_ command: String, _ arguments: [String: Any]? = nil) async throws -> Any {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
            lock.lock()
            if closed {
                lock.unlock()
                cont.resume(throwing: MirageError.io("QMP connection closed"))
                return
            }
            let id = nextID
            nextID += 1
            pending[id] = cont
            lock.unlock()
            var msg: [String: Any] = ["execute": command, "id": id]
            if let arguments { msg["arguments"] = arguments }
            do {
                var data = try JSONSerialization.data(withJSONObject: msg)
                data.append(0x0A)
                try socket.write(data)
            } catch {
                lock.lock()
                let c = pending.removeValue(forKey: id)
                lock.unlock()
                c?.resume(throwing: error)
            }
        }
    }

    public func close() {
        socket.close()
    }

    // MARK: Conveniences

    /// Runs a human monitor (HMP) command and returns its text output.
    public func hmp(_ commandLine: String) async throws -> String {
        try await execute("human-monitor-command", ["command-line": commandLine]) as? String ?? ""
    }

    public func status() async throws -> (running: Bool, status: String) {
        let r = try await execute("query-status") as? [String: Any] ?? [:]
        return (r["running"] as? Bool ?? false, r["status"] as? String ?? "unknown")
    }

    public func key(_ qcode: String, down: Bool) async throws {
        try await execute("input-send-event", ["events": [
            ["type": "key", "data": ["down": down, "key": ["type": "qcode", "data": qcode]]],
        ]])
    }

    /// Absolute pointer event; x and y in 0...1 of the panel.
    public func touch(x: Double, y: Double, down: Bool?) async throws {
        var events: [[String: Any]] = [
            ["type": "abs", "data": ["axis": "x", "value": Int(max(0, min(1, x)) * 32767)]],
            ["type": "abs", "data": ["axis": "y", "value": Int(max(0, min(1, y)) * 32767)]],
        ]
        if let down {
            events.append(["type": "btn", "data": ["down": down, "button": "left"]])
        }
        try await execute("input-send-event", ["events": events])
    }

    public func screendump(to path: String) async throws {
        try await execute("screendump", ["filename": path, "format": "png"])
    }
}
