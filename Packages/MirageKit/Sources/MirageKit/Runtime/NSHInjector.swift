import Foundation

/// Starts the firmware's built-in NuttX shell on the console UART, the way
/// qemu-miwear's `emu/nsh.py inject` does (this is a port of it).
///
/// The production firmware has no interactive shell: its init task runs
/// /etc/init.d/rcS through NSH and exits. Like a debug probe, the injector
/// attaches to the gdbstub of a machine started paused, lets it boot, and
/// right after nx_bringup has spawned the init task it calls the firmware's
/// own task_spawn() once more with the same attributes to start the "sh"
/// builtin, which inherits the boot console. No firmware byte is changed;
/// everything is located in the image.
public enum NSHInjector {
    public struct Plan: Codable, Sendable {
        public let shMain: UInt32
        public let shName: UInt32
        public let call: UInt32
        public let spawn: UInt32
    }

    /// Locates the "sh" builtin and nx_bringup's task_spawn call.
    public static func plan(firmware url: URL) throws -> Plan {
        let img = try FirmwareLayout(url: url)
        let (main, name) = try builtin(img, "sh")
        let (call, spawn) = try bringupSpawn(img)
        return Plan(shMain: main, shName: name, call: call, spawn: spawn)
    }

    /// Runs the injection over the gdbstub at `path`; returns the
    /// shell's task ID.
    public static func inject(plan: Plan, gdbSocket path: String, timeout: TimeInterval = 300) async throws -> Int {
        try await inject(plan: plan, gdb: .unix(path), timeout: timeout)
    }

    public static func inject(plan: Plan, gdb endpoint: QEMUEndpoint, timeout: TimeInterval = 300) async throws -> Int {
        let sock = try await StreamSocket.connect(endpoint, timeout: 15)
        return try await runBlocking {
            let g = GDBRemote(socket: sock)
            defer { sock.close() }
            let deadline = Date().addingTimeInterval(timeout)
            let ret = plan.call &+ 4
            _ = try g.send("?")
            try g.runTo(plan.call, deadline: deadline)
            let attr = try g.reg(3)
            try g.runTo(ret, deadline: deadline)
            var saved: [(Int, UInt32)] = []
            for n in Array(0..<16) + [25] { saved.append((n, try g.reg(n))) }
            let sp = saved.first { $0.0 == 13 }!.1
            try g.setReg(0, plan.shName)
            try g.setReg(1, plan.shMain)
            try g.setReg(2, 0)
            try g.setReg(3, attr)
            try g.setReg(14, ret | 1)
            try g.setReg(15, plan.spawn & ~1)
            try g.runTo(ret, sp: sp, deadline: deadline)
            let pid = try g.reg(0)
            for (n, v) in saved { try g.setReg(n, v) }
            _ = try? g.sendNoReply("D")
            guard pid < 0x8000_0000 else {
                throw MirageError.process("task_spawn failed (\(Int32(bitPattern: pid)))")
            }
            return Int(pid)
        }
    }

    // MARK: Image analysis (as emu/nsh.py)

    static func builtin(_ img: FirmwareLayout, _ name: String) throws -> (UInt32, UInt32) {
        var tops = Set<UInt8>([UInt8(img.xip >> 24)])
        for cp in img.copies {
            tops.insert(UInt8((cp.vma &- 0x20000000) >> 24))
        }
        let want = Array(name.utf8)
        // NuttX g_builtins entries: {name, priority, stack size, main};
        // runs of at least eight in a row
        let tables: [(Int, Int)] = img.bytes.withUnsafeBufferPointer { d in
            func isEntry(_ s: Int) -> Bool {
                s + 16 <= d.count && d[s + 5] == 0 && d[s + 6] == 0 && d[s + 7] == 0
                    && d[s + 10] <= 0x0F && d[s + 11] == 0 && tops.contains(d[s + 15])
            }
            var out: [(Int, Int)] = []
            var s = 0
            while s + 16 * 8 <= d.count {
                if !tops.contains(d[s + 15]) || d[s + 11] != 0 {
                    s += 1
                    continue
                }
                var n = 0
                while isEntry(s + n * 16) { n += 1 }
                if n < 8 {
                    s += 1
                    continue
                }
                out.append((s, s + n * 16))
                s += n * 16
            }
            return out
        }
        for (s, end) in tables {
            var off = s + ((4 - s % 4) % 4)
            var ents: [(UInt32, UInt32)] = []
            while off + 16 <= end {
                let nm = img.u32(at: off), main = img.u32(at: off + 12)
                if main & 1 == 1 { ents.append((nm, main)) }
                off += 16
            }
            let aliases = img.aliases
            var usable = true
            if !ents.isEmpty && ents.allSatisfy({ img.offset(of: $0.0) == nil }) {
                if let base = rodataAlias(img, ents.map(\.0)) {
                    img.aliases = aliases + [base]
                } else {
                    usable = false
                }
            }
            if usable {
                for (nm, main) in ents where img.cString(at: nm) == want {
                    return (main, nm)   // keeps the alias for bringupSpawn
                }
            }
            img.aliases = aliases
        }
        throw MirageError.notFound("NSH: builtin \"\(name)\" not found in the firmware")
    }

    /// Base of a run-time copy of the image holding the strings at `names`
    /// (q63 copies .rodata to PSRAM and its tables point there).
    static func rodataAlias(_ img: FirmwareLayout, _ names: [UInt32]) -> UInt32? {
        let ptrs = Array(Set(names)).sorted()
        guard !ptrs.isEmpty else { return nil }
        var run = [ptrs[0]], best: [UInt32] = []
        for (a, b) in zip(ptrs, ptrs.dropFirst()) {
            run = b - a < 64 ? run + [b] : [b]
            if run.count > best.count { best = run }
        }
        guard best.count >= 3 else { return nil }
        let gaps = zip(best, best.dropFirst()).map { Int($1 - $0) }
        let span = gaps.reduce(0, +)
        let hits: Set<UInt32> = img.printableRuns.withUnsafeBufferPointer { runs in
            img.bytes.withUnsafeBufferPointer { d in
                func nameAt(_ p: Int) -> Bool {
                    guard p >= 0 && p < d.count else { return false }
                    let r = Int(runs[p])
                    return r >= 1 && r <= 64 && p + r < d.count && d[p + r] == 0
                }
                var hits = Set<UInt32>()
                let g0 = gaps[0]
                var s = 0
                while s + span < d.count {
                    // printable run of exactly gap-1 bytes, then NUL, for each gap
                    if Int(runs[s]) != g0 - 1 || d[s + g0 - 1] != 0 {
                        s += 1
                        continue
                    }
                    var p = s + g0, ok = true
                    for g in gaps.dropFirst() {
                        if Int(runs[p]) != g - 1 || d[p + g - 1] != 0 {
                            ok = false
                            break
                        }
                        p += g
                    }
                    if ok && runs[p] > 0 {
                        let base = Int(best[0]) - s
                        if ptrs.allSatisfy({ nameAt(Int($0) - base) }) {
                            hits.insert(UInt32(truncatingIfNeeded: base))
                        }
                    }
                    s += 1
                }
                return hits
            }
        }
        return hits.count == 1 ? hits.first : nil
    }

    static func blTarget(_ img: FirmwareLayout, _ at: UInt32) -> UInt32? {
        guard let h1 = img.u16(addr: at), let h2 = img.u16(addr: at + 2) else { return nil }
        guard h1 & 0xF800 == 0xF000, h2 & 0xD000 == 0xD000 else { return nil }
        let s = Int32((h1 >> 10) & 1)
        let i1 = ~((Int32(h2 >> 13) & 1) ^ s) & 1
        let i2 = ~((Int32(h2 >> 11) & 1) ^ s) & 1
        var imm = (s << 24) | (i1 << 23) | (i2 << 22) | (Int32(h1 & 0x3FF) << 12) | (Int32(h2 & 0x7FF) << 1)
        if s != 0 { imm -= 1 << 25 }
        return UInt32(bitPattern: Int32(bitPattern: at &+ 4) &+ imm)
    }

    /// (BL address, task_spawn) of nx_bringup's init task creation: the
    /// literal load of the "nsh_main" task name followed by a BL.
    static func bringupSpawn(_ img: FirmwareLayout) throws -> (UInt32, UInt32) {
        let d = img.bytes
        let needle = Array("nsh_main\0".utf8)
        var sites = Set<UInt32>()
        for i in img.find(needle) {
            for base in img.aliases {
                let v = base &+ UInt32(i)
                let lit = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
                for j in img.find(lit) where j % 4 == 0 {
                    sites.insert(img.runAddr(of: j))
                }
            }
        }
        var found = Set<[UInt32]>()
        for lit in sites {
            var pc = (lit &- 1020) & ~1
            while pc < lit {
                defer { pc += 2 }
                guard img.offset(of: pc) != nil else { continue }
                guard let h = img.u16(addr: pc), h & 0xFF00 == 0x4800,
                      ((pc + 4) & ~3) + UInt32(h & 0xFF) * 4 == lit else { continue }
                var at = pc + 2
                while at < pc + 24 {
                    if let t = blTarget(img, at) {
                        found.insert([at, t])
                        break
                    }
                    at += 2
                }
            }
        }
        _ = d
        guard found.count == 1, let f = found.first else {
            throw MirageError.notFound("NSH: nx_bringup's task_spawn call not found (\(found.count) candidates)")
        }
        return (f[0], f[1])
    }
}

/// Firmware image layout, parsed as hw/misc/bes_image.c does.
final class FirmwareLayout {
    struct CopySection {
        let start: Int
        let end: Int
        let vma: UInt32
    }

    let bytes: [UInt8]
    let xip: UInt32
    var aliases: [UInt32]
    var copies: [CopySection] = []
    /// Length of the printable run starting at each byte (capped at 255).
    lazy var printableRuns: [UInt8] = {
        var r = [UInt8](repeating: 0, count: bytes.count + 1)
        bytes.withUnsafeBufferPointer { b in
            r.withUnsafeMutableBufferPointer { r in
                var i = b.count - 1
                while i >= 0 {
                    let c = b[i]
                    r[i] = (c >= 0x21 && c <= 0x7E) ? (r[i + 1] == 255 ? 255 : r[i + 1] + 1) : 0
                    i -= 1
                }
            }
        }
        return r
    }()

    init(url: URL) throws {
        bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count > 0x80 else { throw MirageError.invalid("\(url.lastPathComponent) is too small") }
        let mapped = UInt32(bytes[0x64]) | UInt32(bytes[0x65]) << 8 | UInt32(bytes[0x66]) << 16 | UInt32(bytes[0x67]) << 24
        xip = (mapped & ~1) &- 0x14
        var cfg: [String: UInt32] = [:]
        let data = Data(bytes)
        for key in ["FLASH_BASE", "FLASH_NC_BASE", "OTA_CODE_OFFSET"] {
            guard let r = data.range(of: Data((key + "=").utf8)) else {
                throw MirageError.invalid("\(key) missing from the boot info")
            }
            var end = r.upperBound
            while end < data.count, data[end] != 0x0A, data[end] != 0 { end += 1 }
            let s = String(decoding: data[r.upperBound..<end], as: UTF8.self)
            cfg[key] = s.hasPrefix("0x") ? UInt32(s.dropFirst(2), radix: 16) : UInt32(s)
        }
        let ota = cfg["OTA_CODE_OFFSET"] ?? 0
        let cached = (cfg["FLASH_BASE"] ?? 0) &+ ota
        aliases = [xip, cached, (cfg["FLASH_NC_BASE"] ?? 0) &+ ota]
        for o in stride(from: 0, to: min(0x4000, bytes.count - 12), by: 4) {
            let lma = u32(at: o), vma = u32(at: o + 4), end = u32(at: o + 8)
            if vma == 0x3C000000 && cached <= lma && lma < end && end <= cached &+ UInt32(bytes.count) {
                copies.append(CopySection(start: Int(lma &- cached), end: Int(end &- cached), vma: vma))
            }
        }
        for cp in copies {
            aliases.append(cp.vma &- UInt32(cp.start))
            aliases.append(cp.vma &- 0x20000000 &- UInt32(cp.start))
        }
    }

    func runAddr(of off: Int) -> UInt32 {
        for cp in copies {
            if cp.start <= off && off < cp.end {
                return cp.vma &- 0x20000000 &+ UInt32(off - cp.start)
            }
        }
        return xip &+ UInt32(off)
    }

    func u32(at off: Int) -> UInt32 {
        UInt32(bytes[off]) | UInt32(bytes[off + 1]) << 8 | UInt32(bytes[off + 2]) << 16 | UInt32(bytes[off + 3]) << 24
    }

    func offset(of addr: UInt32) -> Int? {
        for cp in copies {
            for base in [cp.vma, cp.vma &- 0x20000000] {
                if base <= addr && addr < base &+ UInt32(cp.end - cp.start) {
                    return Int(addr - base) + cp.start
                }
            }
        }
        for base in aliases where base <= addr && UInt64(addr) < UInt64(base) + UInt64(bytes.count) {
            return Int(addr - base)
        }
        return nil
    }

    func u16(addr: UInt32) -> UInt16? {
        guard let o = offset(of: addr), o + 2 <= bytes.count else { return nil }
        return UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8
    }

    func cString(at addr: UInt32) -> [UInt8]? {
        guard let o = offset(of: addr) else { return nil }
        var e = o
        while e < bytes.count, bytes[e] != 0 { e += 1 }
        return Array(bytes[o..<e])
    }

    func find(_ needle: [UInt8]) -> [Int] {
        guard !needle.isEmpty, needle.count <= bytes.count else { return [] }
        // memmem 是 GNU/POSIX 扩展，Windows 上没有；这里用纯 Swift 数组扫描实现等价查找
        var out: [Int] = []
        var from = 0
        let lastStart = bytes.count - needle.count
        scan: while from <= lastStart {
            for j in 0..<needle.count where bytes[from + j] != needle[j] {
                from += 1
                continue scan
            }
            out.append(from)
            from += 1
        }
        return out
    }
}

#if os(Windows)
/// The MSVC C runtime has no memmem.
private func memmem(_ big: UnsafeRawPointer, _ bigLen: Int,
                    _ little: UnsafeRawPointer, _ littleLen: Int) -> UnsafeMutableRawPointer? {
    guard littleLen > 0, bigLen >= littleLen else { return nil }
    let b = big.assumingMemoryBound(to: UInt8.self)
    let l = little.assumingMemoryBound(to: UInt8.self)
    var i = 0
    while i <= bigLen - littleLen {
        if b[i] == l[0] {
            var j = 1
            while j < littleLen && b[i + j] == l[j] { j += 1 }
            if j == littleLen { return UnsafeMutableRawPointer(mutating: big + i) }
        }
        i += 1
    }
    return nil
}
#endif

/// Minimal GDB remote serial protocol client.
final class GDBRemote {
    let socket: StreamSocket
    var buffer = Data()

    init(socket: StreamSocket) {
        self.socket = socket
    }

    private func packet(_ cmd: String) -> Data {
        let body = Data(cmd.utf8)
        let sum = body.reduce(0) { ($0 + Int($1)) & 0xFF }
        return Data("$\(cmd)#\(String(format: "%02x", sum))".utf8)
    }

    func sendNoReply(_ cmd: String) throws {
        try socket.write(packet(cmd))
    }

    func send(_ cmd: String) throws -> String {
        try socket.write(packet(cmd))
        return try readPacket()
    }

    func readPacket() throws -> String {
        while true {
            if let i = buffer.firstIndex(of: UInt8(ascii: "$")),
               let j = buffer[(i + 1)...].firstIndex(of: UInt8(ascii: "#")),
               buffer.endIndex >= j + 3 {
                let pkt = buffer[(i + 1)..<j]
                buffer = Data(buffer[(j + 3)...])
                try socket.write(Data("+".utf8))
                return String(decoding: pkt, as: UTF8.self)
            }
            let d = try socket.read()
            if d.isEmpty { throw MirageError.io("gdbstub closed the connection") }
            buffer.append(d)
        }
    }

    func reg(_ n: Int) throws -> UInt32 {
        let hex = try send("p\(String(n, radix: 16))")
        guard hex.count >= 8, let v = UInt32(hex.prefix(8), radix: 16) else {
            throw MirageError.protocolError("gdbstub: bad register reply \(hex)")
        }
        return v.byteSwapped
    }

    func setReg(_ n: Int, _ v: UInt32) throws {
        _ = try send("P\(String(n, radix: 16))=\(String(format: "%08x", v.byteSwapped))")
    }

    func runTo(_ addr: UInt32, sp: UInt32? = nil, deadline: Date) throws {
        _ = try send("Z0,\(String(addr, radix: 16)),2")
        while true {
            guard Date() < deadline else { throw MirageError.process("NSH: the firmware did not reach nx_bringup in time") }
            _ = try send("c")
            if try reg(15) == addr {
                if let sp, try reg(13) != sp { continue }
                break
            }
        }
        _ = try send("z0,\(String(addr, radix: 16)),2")
    }
}
