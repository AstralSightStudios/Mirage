/// Minimal terminal input parser: UTF-8 text, legacy and kitty keyboard
/// sequences and SGR mouse reports (in cells, or pixels with mode 1016).
/// Keys the panel has no use for parse to nothing.
enum Key: Equatable {
    case char(Character)
    case home
    case pageUp
    case pageDown
}

struct Mods: Equatable {
    var shift = false
    var alt = false
    var ctrl = false
}

extension Mods {
    /// Decodes the `1 + bitmask` modifier parameter of CSI sequences.
    init(param p: Int) {
        let bits = max(p - 1, 0)
        self.init(shift: bits & 1 != 0, alt: bits & 2 != 0, ctrl: bits & 4 != 0)
    }
}

enum MouseButton: Equatable {
    case left, middle, right
}

enum MouseKind: Equatable {
    case press(MouseButton)
    case release(MouseButton)
    case drag(MouseButton)
    /// Horizontal and vertical steps (right and up are positive)
    case scroll(dx: Int, dy: Int)
}

enum InputEvent: Equatable {
    case key(Key, Mods)
    case mouse(MouseKind, x: Int, y: Int)
}

struct InputParser {
    private var buffer: [UInt8] = []

    mutating func feed(_ bytes: [UInt8]) -> [InputEvent] {
        buffer += bytes
        return parse(eof: false)
    }

    /// Called when no more input arrived for a while: whatever is pending is
    /// complete (e.g. a lone ESC is the Escape key).
    mutating func flush() -> [InputEvent] {
        parse(eof: true)
    }

    private mutating func parse(eof: Bool) -> [InputEvent] {
        var events: [InputEvent] = []
        var i = 0
        while i < buffer.count, let (n, event) = Self.token(buffer, i, eof: eof) {
            i += n
            if let event { events.append(event) }
        }
        buffer.removeFirst(i)
        if eof { buffer.removeAll() }
        return events
    }

    /// Parses the token at `s`: its length and event. Nil if more bytes are needed.
    private static func token(_ b: [UInt8], _ s: Int, eof: Bool) -> (Int, InputEvent?)? {
        guard b[s] == 0x1B else { return plain(b, s, eof: eof) }
        guard s + 1 < b.count else { return eof ? (1, nil) : nil }
        switch b[s + 1] {
        case UInt8(ascii: "["):
            return csi(b, s, eof: eof)
        case UInt8(ascii: "O"):
            guard s + 2 < b.count else { return eof ? (b.count - s, nil) : nil }
            return (3, b[s + 2] == UInt8(ascii: "H") ? .key(.home, Mods()) : nil)
        case UInt8(ascii: "_"), UInt8(ascii: "]"), UInt8(ascii: "P"):
            return skipString(b, s, eof: eof)
        default:
            // Legacy Alt+key
            guard let (n, event) = plain(b, s + 1, eof: eof) else { return nil }
            if case .key(let k, var m)? = event {
                m.alt = true
                return (n + 1, .key(k, m))
            }
            return (n + 1, event)
        }
    }

    private static func plain(_ b: [UInt8], _ s: Int, eof: Bool) -> (Int, InputEvent?)? {
        let c = b[s]
        switch c {
        case 0x01...0x1A where c != 0x09 && c != 0x0A && c != 0x0D:
            return (1, .key(.char(Character(Unicode.Scalar(c + 0x60))), Mods(ctrl: true)))
        case 0x00...0x7F:
            return (1, c >= 0x20 && c != 0x7F ? .key(.char(Character(Unicode.Scalar(c))), Mods()) : nil)
        default:
            let len: Int
            switch c {
            case 0xC0...0xDF: len = 2
            case 0xE0...0xEF: len = 3
            case 0xF0...0xF7: len = 4
            default: return (1, nil)
            }
            guard s + len <= b.count else { return eof ? (b.count - s, nil) : nil }
            let ch = String(validating: b[s..<s + len], as: UTF8.self)?.first
            return (len, ch.map { .key(.char($0), Mods()) })
        }
    }

    private static func csi(_ b: [UInt8], _ s: Int, eof: Bool) -> (Int, InputEvent?)? {
        guard let end = b[(s + 2)...].firstIndex(where: { (0x40...0x7E).contains($0) }) else {
            return eof ? (b.count - s, nil) : nil
        }
        let params = String(decoding: b[(s + 2)..<end], as: UTF8.self)
        let n = end + 1 - s
        if params.hasPrefix("<") {
            return (n, sgrMouse(params.dropFirst(), final: b[end]))
        }

        // Parameters are `;`-separated, each with optional `:` sub-parameters
        let fields = params.split(separator: ";", omittingEmptySubsequences: false)
        func field(_ i: Int) -> Int? {
            guard i < fields.count, let f = fields[i].split(separator: ":").first else { return nil }
            return Int(f)
        }
        let mods = Mods(param: field(1) ?? 1)
        let key: Key?
        switch b[end] {
        case UInt8(ascii: "u"):
            // Private use area: keypad, media and modifier keys
            key = field(0).flatMap { (57344...63743).contains($0) ? nil : UInt32(exactly: $0).flatMap(Unicode.Scalar.init) }
                .map { .char(Character($0)) }
        case UInt8(ascii: "~"):
            switch field(0) {
            case 1, 7: key = .home
            case 5: key = .pageUp
            case 6: key = .pageDown
            default: key = nil
            }
        case UInt8(ascii: "H"):
            key = .home
        default:
            key = nil
        }
        return (n, key.map { .key($0, mods) })
    }

    private static func sgrMouse(_ params: Substring, final: UInt8) -> InputEvent? {
        let v = params.split(separator: ";").map { Int($0) }
        guard v.count == 3, let cb = v[0], let x = v[1], let y = v[2] else { return nil }
        // Coordinates are 1-based
        let (px, py) = (max(x - 1, 0), max(y - 1, 0))
        if cb & 64 != 0 {
            let (dx, dy): (Int, Int)
            switch cb & 3 {
            case 0: (dx, dy) = (0, 1)
            case 1: (dx, dy) = (0, -1)
            case 2: (dx, dy) = (-1, 0)
            default: (dx, dy) = (1, 0)
            }
            return .mouse(.scroll(dx: dx, dy: dy), x: px, y: py)
        }
        guard cb & 128 == 0 else { return nil }  // extra buttons
        let button: MouseButton
        switch cb & 3 {
        case 0: button = .left
        case 1: button = .middle
        case 2: button = .right
        default: return nil  // motion without a button
        }
        let kind: MouseKind = final == UInt8(ascii: "m") ? .release(button)
            : cb & 32 != 0 ? .drag(button) : .press(button)
        return .mouse(kind, x: px, y: py)
    }

    /// Skips APC/OSC/DCS strings (e.g. kitty graphics replies).
    private static func skipString(_ b: [UInt8], _ s: Int, eof: Bool) -> (Int, InputEvent?)? {
        var i = s + 2
        while i < b.count {
            if b[i] == 0x07 { return (i + 1 - s, nil) }
            if b[i] == 0x1B && i + 1 < b.count && b[i + 1] == UInt8(ascii: "\\") { return (i + 2 - s, nil) }
            i += 1
        }
        return eof ? (b.count - s, nil) : nil
    }
}
