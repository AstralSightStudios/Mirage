import Darwin
import Foundation

/// A blocking stream socket (unix or TCP) with a few conveniences.
public final class StreamSocket: @unchecked Sendable {
    public private(set) var fd: Int32
    private let writeLock = NSLock()

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    public static func connect(unix path: String) throws -> StreamSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MirageError.io("socket: \(String(cString: strerror(errno)))") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw MirageError.io("Socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        guard r == 0 else {
            let e = errno
            Darwin.close(fd)
            throw MirageError.io("connect \(path): \(String(cString: strerror(e)))")
        }
        return StreamSocket(fd: fd)
    }

    public static func connect(host: String = "127.0.0.1", port: Int) throws -> StreamSocket {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MirageError.io("socket: \(String(cString: strerror(errno)))") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &addr.sin_addr)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else {
            let e = errno
            Darwin.close(fd)
            throw MirageError.io("connect \(host):\(port): \(String(cString: strerror(e)))")
        }
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        return StreamSocket(fd: fd)
    }

    /// Retries until the peer listens (QEMU creates its sockets a moment
    /// after it starts).
    public static func connect(unix path: String, timeout: TimeInterval) async throws -> StreamSocket {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                return try connect(unix: path)
            } catch {
                if Date() > deadline { throw error }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Read timeout in seconds; 0 blocks forever.
    public func setReadTimeout(_ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public func close() {
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
    }

    public func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw MirageError.io("write: \(String(cString: strerror(errno)))")
                }
                off += n
            }
        }
    }

    /// Up to `max` bytes; empty at end of stream.
    public func read(max: Int = 65536) throws -> Data {
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            let n = Darwin.read(fd, &buf, max)
            if n < 0 {
                if errno == EINTR { continue }
                throw MirageError.io("read: \(String(cString: strerror(errno)))")
            }
            return Data(buf.prefix(n))
        }
    }

    /// Exactly `count` bytes.
    public func readExactly(_ count: Int) throws -> Data {
        var out = Data(count: count)
        var off = 0
        try out.withUnsafeMutableBytes { buf in
            while off < count {
                let n = Darwin.read(fd, buf.baseAddress! + off, count - off)
                if n == 0 { throw MirageError.io("Connection closed") }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw MirageError.io("read: \(String(cString: strerror(errno)))")
                }
                off += n
            }
        }
        return out
    }
}

/// Free TCP port on the loopback interface.
public func freeLoopbackPort() -> Int? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard r == 0 else { return nil }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    return Int(UInt16(bigEndian: addr.sin_port))
}

public func isLoopbackPortFree(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0
}
