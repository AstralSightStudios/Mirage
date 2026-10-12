import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

#if os(Windows)
typealias NativeSocket = SOCKET
private let invalidSocket = INVALID_SOCKET
#else
typealias NativeSocket = Int32
private let invalidSocket: Int32 = -1
#endif

/// The last socket error as text.
private func socketError() -> String {
    #if os(Windows)
    return "WSA error \(WSAGetLastError())"
    #else
    return String(cString: strerror(errno))
    #endif
}

private func socketInterrupted() -> Bool {
    #if os(Windows)
    return WSAGetLastError() == WSAEINTR
    #else
    return errno == EINTR
    #endif
}

#if os(Windows)
/// WinSock needs WSAStartup once per process.
private let winsockReady: Bool = {
    var data = WSADATA()
    return WSAStartup(0x0202, &data) == 0
}()
#endif

private func closeNative(_ s: NativeSocket) {
    #if os(Windows)
    closesocket(s)
    #elseif canImport(Darwin)
    Darwin.close(s)
    #else
    Glibc.close(s)
    #endif
}

private func tcpSocket() -> NativeSocket {
    #if os(Windows)
    _ = winsockReady
    return socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
    #elseif canImport(Darwin)
    return socket(AF_INET, SOCK_STREAM, 0)
    #else
    return socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
}

/// IPv4 loopback address with `port` (0 = any).
private func loopbackAddress(port: Int) -> sockaddr_in {
    var addr = sockaddr_in()
    #if os(Windows)
    addr.sin_family = ADDRESS_FAMILY(AF_INET)
    addr.sin_port = USHORT(UInt16(port).bigEndian)
    addr.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
    #else
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
    #endif
    return addr
}

private func withSockaddr<R>(_ addr: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>, Int32) -> R) -> R {
    let len = Int32(MemoryLayout<sockaddr_in>.size)
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, len) }
    }
}

/// Where a QEMU socket listens: a unix socket (macOS, Linux) or a loopback
/// TCP port (Windows).
public enum QEMUEndpoint: Codable, Hashable, Sendable {
    case unix(String)
    case tcp(Int)

    /// Stored as "unix:PATH" or "tcp:PORT".
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        if s.hasPrefix("unix:") {
            self = .unix(String(s.dropFirst(5)))
        } else if s.hasPrefix("tcp:"), let port = Int(s.dropFirst(4)) {
            self = .tcp(port)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad endpoint \(s)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .unix(let path): try c.encode("unix:\(path)")
        case .tcp(let port): try c.encode("tcp:\(port)")
        }
    }

    /// `-qmp` / `-gdb` value for a listening server.
    var serverOption: String {
        switch self {
        case .unix(let path): return "unix:\(path),server=on,wait=off"
        case .tcp(let port): return "tcp:127.0.0.1:\(port),server=on,wait=off"
        }
    }

    /// The address part of `-chardev socket,...`.
    var chardevAddress: String {
        switch self {
        case .unix(let path): return "path=\(path)"
        case .tcp(let port): return "host=127.0.0.1,port=\(port)"
        }
    }

    /// `-vnc` value (a TCP endpoint is a VNC display: port 5900 + n).
    var vncOption: String {
        switch self {
        case .unix(let path): return "unix:\(path)"
        case .tcp(let port): return "127.0.0.1:\(port - 5900)"
        }
    }
}

/// The QEMU sockets of one boot.
public struct DeviceEndpoints: Codable, Hashable, Sendable {
    public var qmp: QEMUEndpoint
    /// Second QMP monitor for tools (miragectl) while Mirage holds the first.
    public var qmpAux: QEMUEndpoint
    public var vnc: QEMUEndpoint
    public var console: QEMUEndpoint
    public var gdb: QEMUEndpoint

    /// Unix sockets in the device's runtime directory.
    public static func unix(_ paths: DevicePaths) -> DeviceEndpoints {
        DeviceEndpoints(qmp: .unix(paths.qmpSocket.path),
                        qmpAux: .unix(paths.runtime.appendingPathComponent("qmp-aux.sock").path),
                        vnc: .unix(paths.vncSocket.path),
                        console: .unix(paths.consoleSocket.path),
                        gdb: .unix(paths.gdbSocket.path))
    }

    /// Free loopback ports (hosts without unix sockets).
    public static func loopback() throws -> DeviceEndpoints {
        var taken = Set<Int>()
        func port() throws -> Int {
            for _ in 0..<20 {
                if let p = freeLoopbackPort(), !taken.contains(p) { taken.insert(p); return p }
            }
            throw MirageError.io("No free loopback port")
        }
        guard let display = (0..<100).first(where: { !taken.contains(5900 + $0) && isLoopbackPortFree(5900 + $0) }) else {
            throw MirageError.io("No free VNC display on 127.0.0.1")
        }
        taken.insert(5900 + display)
        return DeviceEndpoints(qmp: .tcp(try port()), qmpAux: .tcp(try port()), vnc: .tcp(5900 + display),
                               console: .tcp(try port()), gdb: .tcp(try port()))
    }

    /// What a boot on this host uses.
    public static func forHost(_ paths: DevicePaths) throws -> DeviceEndpoints {
        #if os(Windows)
        return try loopback()
        #else
        return unix(paths)
        #endif
    }
}

/// A blocking stream socket (unix or TCP) with a few conveniences.
public final class StreamSocket: @unchecked Sendable {
    private(set) var handle: NativeSocket
    private let writeLock = NSLock()

    init(handle: NativeSocket) {
        self.handle = handle
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    deinit { close() }

    public static func connect(unix path: String) throws -> StreamSocket {
        #if os(Windows)
        throw MirageError.io("Unix sockets are not used on Windows: \(path)")
        #else
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw MirageError.io("socket: \(socketError())") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            closeNative(fd)
            throw MirageError.io("Socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.connect(fd, $0, len)
                #else
                Glibc.connect(fd, $0, len)
                #endif
            }
        }
        guard r == 0 else {
            let e = socketError()
            closeNative(fd)
            throw MirageError.io("connect \(path): \(e)")
        }
        return StreamSocket(handle: fd)
        #endif
    }

    public static func connect(host: String = "127.0.0.1", port: Int) throws -> StreamSocket {
        let fd = tcpSocket()
        guard fd != invalidSocket else { throw MirageError.io("socket: \(socketError())") }
        var addr = sockaddr_in()
        #if os(Windows)
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        addr.sin_port = USHORT(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &addr.sin_addr)
        #else
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &addr.sin_addr)
        #endif
        let r = withSockaddr(&addr) { ptr, len in
            #if os(Windows)
            WinSDK.connect(fd, ptr, len)
            #elseif canImport(Darwin)
            Darwin.connect(fd, ptr, socklen_t(len))
            #else
            Glibc.connect(fd, ptr, socklen_t(len))
            #endif
        }
        guard r == 0 else {
            let e = socketError()
            closeNative(fd)
            throw MirageError.io("connect \(host):\(port): \(e)")
        }
        var on: Int32 = 1
        #if os(Windows)
        setsockopt(fd, IPPROTO_TCP.rawValue, TCP_NODELAY, withUnsafePointer(to: &on) {
            $0.withMemoryRebound(to: CChar.self, capacity: 4) { $0 }
        }, 4)
        #elseif canImport(Darwin)
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        #else
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return StreamSocket(handle: fd)
    }

    public static func connect(_ endpoint: QEMUEndpoint) throws -> StreamSocket {
        switch endpoint {
        case .unix(let path): return try connect(unix: path)
        case .tcp(let port): return try connect(port: port)
        }
    }

    /// Retries until the peer listens (QEMU creates its sockets a moment
    /// after it starts).
    public static func connect(_ endpoint: QEMUEndpoint, timeout: TimeInterval) async throws -> StreamSocket {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                return try connect(endpoint)
            } catch {
                if Date() > deadline { throw error }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    public static func connect(unix path: String, timeout: TimeInterval) async throws -> StreamSocket {
        try await connect(.unix(path), timeout: timeout)
    }

    /// Read timeout in seconds; 0 blocks forever.
    public func setReadTimeout(_ seconds: TimeInterval) {
        #if os(Windows)
        var ms = DWORD(seconds * 1000)
        withUnsafePointer(to: &ms) {
            $0.withMemoryRebound(to: CChar.self, capacity: 4) {
                _ = setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, $0, Int32(MemoryLayout<DWORD>.size))
            }
        }
        #elseif canImport(Darwin)
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #else
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int((seconds - floor(seconds)) * 1_000_000))
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #endif
    }

    public func close() {
        if handle != invalidSocket {
            #if os(Windows)
            shutdown(handle, SD_BOTH)
            #elseif canImport(Darwin)
            Darwin.shutdown(handle, SHUT_RDWR)
            #else
            Glibc.shutdown(handle, Int32(SHUT_RDWR))
            #endif
            closeNative(handle)
            handle = invalidSocket
        }
    }

    private func sendSome(_ p: UnsafeRawPointer, _ n: Int) -> Int {
        #if os(Windows)
        return Int(send(handle, p.assumingMemoryBound(to: CChar.self), Int32(min(n, Int(Int32.max))), 0))
        #elseif canImport(Darwin)
        return Darwin.write(handle, p, n)
        #else
        return Glibc.send(handle, p, n, Int32(MSG_NOSIGNAL))
        #endif
    }

    private func receiveSome(_ p: UnsafeMutableRawPointer, _ n: Int) -> Int {
        #if os(Windows)
        return Int(recv(handle, p.assumingMemoryBound(to: CChar.self), Int32(min(n, Int(Int32.max))), 0))
        #elseif canImport(Darwin)
        return Darwin.read(handle, p, n)
        #else
        return Glibc.read(handle, p, n)
        #endif
    }

    public func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = sendSome(buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if socketInterrupted() { continue }
                    throw MirageError.io("write: \(socketError())")
                }
                off += n
            }
        }
    }

    /// Up to `max` bytes; empty at end of stream.
    public func read(max: Int = 65536) throws -> Data {
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            let n = buf.withUnsafeMutableBytes { receiveSome($0.baseAddress!, max) }
            if n < 0 {
                if socketInterrupted() { continue }
                throw MirageError.io("read: \(socketError())")
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
                let n = receiveSome(buf.baseAddress! + off, count - off)
                if n == 0 { throw MirageError.io("Connection closed") }
                if n < 0 {
                    if socketInterrupted() { continue }
                    throw MirageError.io("read: \(socketError())")
                }
                off += n
            }
        }
        return out
    }
}

/// Binds a loopback TCP socket to `port` (0 = any) and returns the bound
/// port, or nil if the bind fails.
private func bindLoopback(port: Int) -> Int? {
    let fd = tcpSocket()
    guard fd != invalidSocket else { return nil }
    defer { closeNative(fd) }
    var addr = loopbackAddress(port: port)
    let r = withSockaddr(&addr) { ptr, len in
        #if os(Windows)
        bind(fd, ptr, len)
        #else
        bind(fd, ptr, socklen_t(len))
        #endif
    }
    guard r == 0 else { return nil }
    #if os(Windows)
    var len = Int32(MemoryLayout<sockaddr_in>.size)
    #else
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    #endif
    _ = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    return Int(UInt16(bigEndian: addr.sin_port))
}

/// Free TCP port on the loopback interface.
public func freeLoopbackPort() -> Int? {
    bindLoopback(port: 0)
}

public func isLoopbackPortFree(_ port: Int) -> Bool {
    bindLoopback(port: port) != nil
}
