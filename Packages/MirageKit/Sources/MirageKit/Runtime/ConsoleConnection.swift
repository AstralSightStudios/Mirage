import Foundation

/// The console UART's socket: boot log out, NSH input in.
public final class ConsoleConnection: @unchecked Sendable {
    private let socket: StreamSocket
    private var dataHandler: (@Sendable (Data) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?
    private let lock = NSLock()

    private init(socket: StreamSocket) {
        self.socket = socket
    }

    public static func connect(path: String, timeout: TimeInterval = 10) async throws -> ConsoleConnection {
        try await connect(.unix(path), timeout: timeout)
    }

    public static func connect(_ endpoint: QEMUEndpoint, timeout: TimeInterval = 10) async throws -> ConsoleConnection {
        let s = try await StreamSocket.connect(endpoint, timeout: timeout)
        return ConsoleConnection(socket: s)
    }

    public func start(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        lock.lock()
        dataHandler = onData
        closeHandler = onClose
        lock.unlock()
        let t = Thread { [self] in
            while true {
                guard let d = try? socket.read(), !d.isEmpty else { break }
                lock.lock()
                let h = dataHandler
                lock.unlock()
                h?(d)
            }
            lock.lock()
            let c = closeHandler
            lock.unlock()
            c?()
        }
        t.name = "Console reader"
        t.start()
    }

    public func send(_ data: Data) {
        try? socket.write(data)
    }

    public func send(_ text: String) {
        send(Data(text.utf8))
    }

    public func close() {
        socket.close()
    }
}

/// Bounded byte history (console scrollback for late subscribers).
public struct ByteRing: Sendable {
    public let capacity: Int
    public private(set) var data = Data()

    public init(capacity: Int) {
        self.capacity = capacity
    }

    public mutating func append(_ d: Data) {
        data.append(d)
        if data.count > capacity {
            data = Data(data.suffix(capacity * 3 / 4))
        }
    }

    public mutating func clear() {
        data = Data()
    }
}
