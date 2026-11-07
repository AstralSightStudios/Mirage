import CTerminal
import Foundation
import MirageKit

/// The terminal for `view`: raw mode on the alternate screen with mouse
/// reporting, and what it can draw. `leave()` restores it.
final class Terminal: @unchecked Sendable {
    enum Graphics {
        /// Kitty graphics protocol, pixels in POSIX shared memory
        case kittySharedMemory
        /// Kitty graphics protocol, pixels inline as base64
        case kittyDirect
        /// Upper and lower half blocks in 24-bit colour, two pixels per cell
        case halfBlocks
    }

    struct Size: Equatable {
        var columns: Int
        var rows: Int
        var cellWidth: Int
        var cellHeight: Int
    }

    let graphics: Graphics
    /// Mouse reports are in pixels (mode 1016) rather than cells.
    let pixelMouse: Bool
    let input: InputQueue
    /// Cell size the terminal answered, for when the window size has no pixels.
    private let probedCell: (width: Int, height: Int)?

    private init(graphics: Graphics, pixelMouse: Bool, input: InputQueue, probedCell: (width: Int, height: Int)?) {
        self.graphics = graphics
        self.pixelMouse = pixelMouse
        self.input = input
        self.probedCell = probedCell
    }

    static func enter(halfBlocks: Bool) throws -> Terminal {
        guard mirage_term_raw_enter() == 0 else { throw MirageError.invalid("view needs a terminal") }
        let input = InputQueue()
        let reply = probe(input, shm: !halfBlocks)
        let cell = reply.cell
        let graphics: Graphics = halfBlocks ? .halfBlocks
            : reply.kittySharedMemory ? .kittySharedMemory
            : reply.kittyDirect ? .kittyDirect : .halfBlocks
        let size = currentSize(probed: cell)
        // Pixel reports are only useful with the real cell size
        let pixelMouse = reply.pixelMouse && size.known
        let t = Terminal(graphics: graphics, pixelMouse: pixelMouse, input: input, probedCell: cell)
        var setup = "\u{1B}[?1049h\u{1B}[?25l"           // alternate screen, hide cursor
        setup += "\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1006h" // mouse: buttons + drag, SGR
        if pixelMouse { setup += "\u{1B}[?1016h" }        // ... in pixels
        setup += "\u{1B}[>1u"                             // kitty keyboard: disambiguate escape codes
        setup += "\u{1B}[22;0t"                           // save title
        t.write(setup)
        return t
    }

    func leave() {
        var s = ""
        if graphics != .halfBlocks { s += "\u{1B}_Ga=d,d=A,q=2\u{1B}\\" }
        s += "\u{1B}[<u\u{1B}[?1016l\u{1B}[?1006l\u{1B}[?1002l\u{1B}[?1000l"
        s += "\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l\u{1B}[23;0t"
        write(s)
        mirage_term_raw_leave()
    }

    func setTitle(_ title: String) {
        write("\u{1B}]2;\(title)\u{07}")
    }

    func write(_ s: String) {
        var s = s
        s.withUTF8 { _ = mirage_term_write($0.baseAddress, $0.count) }
    }

    func write(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { _ = mirage_term_write($0.baseAddress, $0.count) }
    }

    var size: Size { Self.currentSize(probed: probedCell).size }

    private static func currentSize(probed: (width: Int, height: Int)?) -> (size: Size, known: Bool) {
        var cols: UInt32 = 0, rows: UInt32 = 0, w: UInt32 = 0, h: UInt32 = 0
        if mirage_term_size(&cols, &rows, &w, &h) != 0 { (cols, rows) = (80, 24) }
        let c = max(Int(cols), 1), r = max(Int(rows), 1)
        if w >= cols, h >= rows, w > 0, h > 0 {
            return (Size(columns: c, rows: r, cellWidth: Int(w) / c, cellHeight: Int(h) / r), true)
        }
        // Assume a common cell size if the terminal reports no pixels
        let cell = probed ?? (8, 16)
        return (Size(columns: c, rows: r, cellWidth: cell.width, cellHeight: cell.height), probed != nil)
    }

    // MARK: Probe

    private struct Reply {
        var kittyDirect = false
        var kittySharedMemory = false
        var pixelMouse = false
        var cell: (width: Int, height: Int)?
    }

    /// Asks for kitty graphics (inline and shared memory), SGR-Pixels mouse
    /// support and the cell size. A trailing primary device attributes query
    /// tells when the terminal has answered everything it is going to answer.
    private static func probe(_ input: InputQueue, shm: Bool) -> Reply {
        let shmName = "/mirage.\(ProcessInfo.processInfo.processIdentifier).probe"
        let shmOK = shm && mirage_shm_write(shmName, [0, 0, 0], 3) == 0
        var q = "\u{1B}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1B}\\"
        if shmOK {
            q += "\u{1B}_Gi=32,s=1,v=1,a=q,t=s,f=24,S=3;\(Data(shmName.utf8).base64EncodedString())\u{1B}\\"
        }
        q += "\u{1B}[?1016$p\u{1B}[16t\u{1B}[c"
        var s = q
        s.withUTF8 { _ = mirage_term_write($0.baseAddress, $0.count) }

        var bytes: [UInt8] = []
        let deadline = Date().addingTimeInterval(2)
        while !isDeviceAttributesEnd(bytes), deadline.timeIntervalSinceNow > 0,
              let chunk = input.take(timeout: deadline.timeIntervalSinceNow) {
            bytes += chunk
        }
        if shmOK { mirage_shm_unlink(shmName) }

        let text = String(decoding: bytes, as: UTF8.self)
        var r = Reply()
        r.kittyDirect = text.contains("\u{1B}_Gi=31;OK")
        r.kittySharedMemory = text.contains("\u{1B}_Gi=32;OK")
        // DECRPM: 1 set, 2 reset; 0 unknown, 4 permanently reset
        r.pixelMouse = text.contains("\u{1B}[?1016;1$y") || text.contains("\u{1B}[?1016;2$y")
        if let start = text.range(of: "\u{1B}[6;"), let end = text[start.upperBound...].firstIndex(of: "t") {
            let parts = text[start.upperBound..<end].split(separator: ";").compactMap { Int($0) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 { r.cell = (parts[1], parts[0]) }
        }
        return r
    }

    /// ESC [ ? ... c
    private static func isDeviceAttributesEnd(_ b: [UInt8]) -> Bool {
        guard b.count >= 4 else { return false }
        for i in stride(from: b.count - 3, through: 0, by: -1) where b[i] == 0x1B && b[i + 1] == 0x5B && b[i + 2] == 0x3F {
            return b[(i + 3)...].contains(UInt8(ascii: "c"))
        }
        return false
    }
}

/// Stdin, read on its own thread so that waiting for input can time out the
/// same way on every platform.
final class InputQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [UInt8] = []
    private var closed = false

    init() {
        let t = Thread { [self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buf.withUnsafeMutableBytes { mirage_term_read($0.baseAddress, $0.count) }
                condition.lock()
                if n > 0 { pending += buf.prefix(n) } else { closed = true }
                condition.broadcast()
                condition.unlock()
                if n <= 0 { return }
            }
        }
        t.name = "stdin"
        t.start()
    }

    /// The bytes read so far, empty if none came within `timeout`, nil once
    /// stdin has ended.
    func take(timeout: TimeInterval) -> [UInt8]? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while pending.isEmpty && !closed {
            if !condition.wait(until: deadline) { break }
        }
        if pending.isEmpty { return closed ? nil : [] }
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}
