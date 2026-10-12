import Foundation

/// A small RFB 3.8 client for QEMU's VNC server on a unix socket: raw
/// frames in BGRA, desktop resizes, absolute pointer and key events. The
/// emulator's panel is QEMU's graphic console, so this is how its screen
/// shows up inside Mirage.
public final class VNCClient: @unchecked Sendable {
    public struct Frame: @unchecked Sendable {
        public let width: Int
        public let height: Int
        /// 32-bit pixels, B,G,R,X in memory (little-endian 0x00RRGGBB).
        public let pixels: Data
        public let sequence: Int
    }

    private let socket: StreamSocket
    private let lock = NSLock()
    private var width = 0
    private var height = 0
    private var fb: [UInt8] = []
    private var sequence = 0
    private var frameHandler: (@Sendable (Frame) -> Void)?
    private var closeHandler: (@Sendable (Error?) -> Void)?
    private var buttons: UInt8 = 0
    private var lastPointer: (Int, Int) = (0, 0)
    public private(set) var name = ""

    private init(socket: StreamSocket) {
        self.socket = socket
    }

    public var size: (width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (width, height)
    }

    public static func connect(path: String, timeout: TimeInterval = 15) async throws -> VNCClient {
        try await connect(.unix(path), timeout: timeout)
    }

    public static func connect(_ endpoint: QEMUEndpoint, timeout: TimeInterval = 15) async throws -> VNCClient {
        let s = try await StreamSocket.connect(endpoint, timeout: timeout)
        let c = VNCClient(socket: s)
        try await runBlocking { try c.handshake() }
        return c
    }

    public func onFrame(_ handler: @escaping @Sendable (Frame) -> Void) {
        lock.lock()
        frameHandler = handler
        lock.unlock()
    }

    public func onClose(_ handler: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        closeHandler = handler
        lock.unlock()
    }

    private func handshake() throws {
        let version = try socket.readExactly(12)
        guard version.starts(with: Data("RFB 003.".utf8)) else {
            throw MirageError.protocolError("Not a VNC server")
        }
        try socket.write(Data("RFB 003.008\n".utf8))
        let n = Int(try socket.readExactly(1)[0])
        if n == 0 {
            let len = Int(try socket.readExactly(4).beU32(0))
            let reason = String(decoding: try socket.readExactly(len), as: UTF8.self)
            throw MirageError.protocolError("VNC refused: \(reason)")
        }
        let types = try socket.readExactly(n)
        guard types.contains(1) else { throw MirageError.protocolError("VNC server wants authentication") }
        try socket.write(Data([1]))
        guard try socket.readExactly(4).beU32(0) == 0 else { throw MirageError.protocolError("VNC security handshake failed") }
        try socket.write(Data([1]))  // shared
        let initMsg = try socket.readExactly(24)
        let w = Int(initMsg.beU16(0)), h = Int(initMsg.beU16(2))
        let nameLen = Int(initMsg.beU32(20))
        name = String(decoding: try socket.readExactly(nameLen), as: UTF8.self)
        resize(w, h)

        // 32 bpp, depth 24, little endian, true colour, R<<16 G<<8 B
        var pf = Data([0, 0, 0, 0, 32, 24, 0, 1])
        pf.append(be16(255)); pf.append(be16(255)); pf.append(be16(255))
        pf.append(contentsOf: [16, 8, 0, 0, 0, 0])
        try socket.write(pf)
        let encodings: [Int32] = [0, -223]  // Raw, DesktopSize
        var enc = Data([2, 0])
        enc.append(be16(UInt16(encodings.count)))
        for e in encodings { enc.append(be32(UInt32(bitPattern: e))) }
        try socket.write(enc)
        try requestUpdate(incremental: false)
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "VNC reader"
        t.start()
    }

    private func resize(_ w: Int, _ h: Int) {
        lock.lock()
        width = w
        height = h
        fb = [UInt8](repeating: 0, count: w * h * 4)
        lock.unlock()
    }

    private func requestUpdate(incremental: Bool) throws {
        let (w, h) = size
        var m = Data([3, incremental ? 1 : 0])
        m.append(be16(0)); m.append(be16(0))
        m.append(be16(UInt16(w))); m.append(be16(UInt16(h)))
        try socket.write(m)
    }

    private func readLoop() {
        var failure: Error?
        do {
            while true {
                let type = try socket.readExactly(1)[0]
                switch type {
                case 0:
                    try readFramebufferUpdate()
                case 1:
                    let hdr = try socket.readExactly(5)
                    _ = try socket.readExactly(Int(hdr.beU16(3)) * 6)
                case 2:
                    break
                case 3:
                    let hdr = try socket.readExactly(7)
                    _ = try socket.readExactly(Int(hdr.beU32(3)))
                default:
                    throw MirageError.protocolError("Unknown VNC message \(type)")
                }
            }
        } catch {
            failure = error
        }
        lock.lock()
        let h = closeHandler
        lock.unlock()
        h?(failure)
    }

    private func readFramebufferUpdate() throws {
        let hdr = try socket.readExactly(3)
        let count = Int(hdr.beU16(1))
        var resized = false
        for _ in 0..<count {
            let r = try socket.readExactly(12)
            let x = Int(r.beU16(0)), y = Int(r.beU16(2)), w = Int(r.beU16(4)), h = Int(r.beU16(6))
            let encoding = Int32(bitPattern: r.beU32(8))
            switch encoding {
            case 0:
                let data = try socket.readExactly(w * h * 4)
                lock.lock()
                let stride = width * 4
                data.withUnsafeBytes { src in
                    fb.withUnsafeMutableBytes { dst in
                        for row in 0..<h where y + row < height && x + w <= width {
                            memcpy(dst.baseAddress! + (y + row) * stride + x * 4,
                                   src.baseAddress! + row * w * 4, w * 4)
                        }
                    }
                }
                lock.unlock()
            case -223:
                resize(w, h)
                resized = true
            default:
                throw MirageError.protocolError("Unexpected VNC encoding \(encoding)")
            }
        }
        lock.lock()
        sequence += 1
        let frame = Frame(width: width, height: height, pixels: Data(fb), sequence: sequence)
        let handler = frameHandler
        lock.unlock()
        handler?(frame)
        try requestUpdate(incremental: !resized)
    }

    /// The current screen.
    public func snapshot() -> Frame {
        lock.lock()
        defer { lock.unlock() }
        return Frame(width: width, height: height, pixels: Data(fb), sequence: sequence)
    }

    // MARK: Input

    /// Pointer at panel pixel (x, y); `pressed` is the finger.
    public func pointer(x: Int, y: Int, pressed: Bool) {
        let (w, h) = size
        let px = max(0, min(w - 1, x)), py = max(0, min(h - 1, y))
        lock.lock()
        buttons = pressed ? 1 : 0
        lastPointer = (px, py)
        lock.unlock()
        var m = Data([5, pressed ? 1 : 0])
        m.append(be16(UInt16(px)))
        m.append(be16(UInt16(py)))
        try? socket.write(m)
    }

    /// X11 keysym press / release.
    public func key(_ keysym: UInt32, down: Bool) {
        var m = Data([4, down ? 1 : 0, 0, 0])
        m.append(be32(keysym))
        try? socket.write(m)
    }

    public func close() {
        socket.close()
    }
}

private func be16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
private func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

extension Data {
    func beU16(_ off: Int) -> UInt16 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt16.self).bigEndian }
    }

    func beU32(_ off: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self).bigEndian }
    }
}
