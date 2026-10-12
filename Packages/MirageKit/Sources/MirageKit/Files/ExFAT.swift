import Foundation

/// An exFAT partition image (the Watch S5 firmware formats nv, data and
/// userlog on its eMMC with exFAT). Reads and writes in place; the device
/// must be shut down while it is open.
public final class ExFATVolume: GuestFileSystem, @unchecked Sendable {
    private struct Record {
        var name: String
        var attributes: UInt16
        var firstCluster: UInt32
        var dataLength: UInt64
        var validLength: UInt64
        var noFatChain: Bool
        var created: UInt32
        var modified: UInt32
        var modifiedOffset: UInt8 = 0x80
        /// The entry set's place in its directory: first entry and count.
        var index: Int
        var count: Int

        var isDirectory: Bool { attributes & 0x10 != 0 }
    }

    /// A directory's entry stream and where its own record lives.
    private struct Directory {
        var clusters: [UInt32]
        var noFatChain: Bool
        var record: Record?
        var parent: [String]

        var isRoot: Bool { record == nil }
    }

    private let region: ImageRegion
    private let clusterSize: Int
    private let fatOffset: UInt64
    private let heapOffset: UInt64
    private let clusterCount: UInt32
    private let rootCluster: UInt32
    private var bitmap: [UInt8] = []
    private var bitmapClusters: [UInt32] = []
    private var upcase: [UInt16] = []
    private let lock = NSLock()

    public let isReadOnly: Bool

    public init(url: URL, offset: UInt64, size: UInt64, writable: Bool) throws {
        region = try ImageRegion(url: url, offset: offset, size: size, writable: writable)
        isReadOnly = !writable
        let boot = try region.read(0, 512)
        guard boot.subdata(in: 3..<11) == Data("EXFAT   ".utf8) else {
            throw MirageError.invalid("The partition is not exFAT (the device formats it on its first boot)")
        }
        let sector = 1 << Int(boot[108])
        clusterSize = sector << Int(boot[109])
        fatOffset = UInt64(boot.le32(80)) * UInt64(sector)
        heapOffset = UInt64(boot.le32(88)) * UInt64(sector)
        clusterCount = boot.le32(92)
        rootCluster = boot.le32(96)
        try loadMetadata()
    }

    public static func isExFAT(url: URL, offset: UInt64) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: offset + 3)) != nil, let d = try? fh.read(upToCount: 8) else { return false }
        return d == Data("EXFAT   ".utf8)
    }

    // MARK: Clusters

    private func clusterOffset(_ c: UInt32) -> UInt64 {
        heapOffset + UInt64(c - 2) * UInt64(clusterSize)
    }

    private func fat(_ c: UInt32) throws -> UInt32 {
        try region.read(fatOffset + UInt64(c) * 4, 4).le32(0)
    }

    private func setFAT(_ c: UInt32, _ value: UInt32) throws {
        var d = Data(count: 4)
        d.putLE32(value, at: 0)
        try region.write(fatOffset + UInt64(c) * 4, d)
    }

    private func chain(_ first: UInt32, noFatChain: Bool, length: UInt64?) throws -> [UInt32] {
        guard first >= 2 else { return [] }
        if noFatChain, let length {
            let n = Int((length + UInt64(clusterSize) - 1) / UInt64(clusterSize))
            return (0..<n).map { first + UInt32($0) }
        }
        var out: [UInt32] = []
        var c = first
        while c >= 2 && c < clusterCount + 2 && out.count <= Int(clusterCount) {
            out.append(c)
            c = try fat(c)
        }
        return out
    }

    private func readClusters(_ clusters: [UInt32], length: Int? = nil) throws -> Data {
        var out = Data()
        out.reserveCapacity(clusters.count * clusterSize)
        var i = 0
        while i < clusters.count {
            var run = 1
            while i + run < clusters.count && clusters[i + run] == clusters[i] + UInt32(run) { run += 1 }
            out.append(try region.read(clusterOffset(clusters[i]), run * clusterSize))
            i += run
        }
        if let length { return out.prefix(length) }
        return out
    }

    // MARK: Metadata

    private func loadMetadata() throws {
        let root = try readClusters(chain(rootCluster, noFatChain: false, length: nil))
        var upFirst: UInt32 = 0, upLen: UInt64 = 0
        for i in stride(from: 0, to: root.count, by: 32) {
            let t = root[root.startIndex + i]
            if t == 0 { break }
            if t == 0x81 && root[root.startIndex + i + 1] & 1 == 0 {
                bitmapClusters = try chain(root.le32(i + 20), noFatChain: false, length: root.le64(i + 24))
                bitmap = Array(try readClusters(bitmapClusters, length: Int(root.le64(i + 24))))
            } else if t == 0x82 {
                upFirst = root.le32(i + 20)
                upLen = root.le64(i + 24)
            }
        }
        guard !bitmapClusters.isEmpty else { throw MirageError.invalid("exFAT has no allocation bitmap") }
        upcase = (0...0xFFFF).map { UInt16($0) }
        if upFirst >= 2 {
            let raw = try readClusters(chain(upFirst, noFatChain: false, length: upLen), length: Int(upLen))
            var ch = 0
            var i = 0
            while i + 1 < raw.count && ch <= 0xFFFF {
                let v = raw.le16(i)
                i += 2
                if v == 0xFFFF, i + 1 < raw.count {
                    ch += Int(raw.le16(i))
                    i += 2
                } else {
                    upcase[ch] = v
                    ch += 1
                }
            }
        } else {
            for c in 0x61...0x7A { upcase[c] = UInt16(c - 32) }
        }
    }

    private func isFree(_ c: UInt32) -> Bool {
        let i = Int(c - 2)
        return bitmap[i / 8] & (1 << (i % 8)) == 0
    }

    private func mark(_ clusters: [UInt32], used: Bool) throws {
        var dirty = Set<Int>()
        for c in clusters {
            let i = Int(c - 2)
            if used { bitmap[i / 8] |= 1 << (i % 8) } else { bitmap[i / 8] &= ~(1 << (i % 8)) }
            dirty.insert(i / 8 / clusterSize)
        }
        for page in dirty {
            let start = page * clusterSize
            let end = min(bitmap.count, start + clusterSize)
            try region.write(clusterOffset(bitmapClusters[page]), Data(bitmap[start..<end]))
        }
    }

    /// `count` clusters, contiguous when possible (then no FAT chain is needed).
    private func allocate(_ count: Int, after hint: UInt32? = nil) throws -> (clusters: [UInt32], contiguous: Bool) {
        guard count > 0 else { return ([], true) }
        let total = Int(clusterCount)
        if let hint, hint >= 2, Int(hint) - 2 + count <= total, (0..<count).allSatisfy({ isFree(hint + UInt32($0)) }) {
            return ((0..<count).map { hint + UInt32($0) }, true)
        }
        var runStart = -1, run = 0
        for i in 0..<total {
            if bitmap[i / 8] & (1 << (i % 8)) == 0 {
                if run == 0 { runStart = i }
                run += 1
                if run == count { return ((0..<count).map { UInt32(runStart + $0 + 2) }, true) }
            } else {
                run = 0
            }
        }
        var picked: [UInt32] = []
        for i in 0..<total where bitmap[i / 8] & (1 << (i % 8)) == 0 {
            picked.append(UInt32(i + 2))
            if picked.count == count { return (picked, false) }
        }
        throw MirageError.io("The partition is full")
    }

    private func writeChain(_ clusters: [UInt32]) throws {
        for (i, c) in clusters.enumerated() {
            try setFAT(c, i + 1 < clusters.count ? clusters[i + 1] : 0xFFFF_FFFF)
        }
    }

    private func free(_ r: Record) throws {
        let clusters = try chain(r.firstCluster, noFatChain: r.noFatChain, length: r.dataLength)
        try mark(clusters, used: false)
        if !r.noFatChain { for c in clusters { try setFAT(c, 0) } }
    }

    // MARK: Directories

    private func entries(of dir: Directory) throws -> Data {
        try readClusters(dir.clusters)
    }

    private func records(in dir: Directory) throws -> [Record] {
        let d = try entries(of: dir)
        var out: [Record] = []
        var i = 0
        let n = d.count / 32
        while i < n {
            let o = i * 32
            let type = d[d.startIndex + o]
            if type == 0 { break }
            guard type == 0x85 else { i += 1; continue }
            let secondary = Int(d[d.startIndex + o + 1])
            guard secondary >= 2, i + secondary < n, d[d.startIndex + o + 32] == 0xC0 else { i += 1; continue }
            let s = o + 32
            let nameLength = Int(d[d.startIndex + s + 3])
            var units: [UInt16] = []
            for k in 2...secondary {
                let e = o + k * 32
                guard d[d.startIndex + e] == 0xC1 else { break }
                for c in 0..<15 where units.count < nameLength { units.append(d.le16(e + 2 + c * 2)) }
            }
            out.append(Record(name: String(decoding: units, as: UTF16.self),
                              attributes: d.le16(o + 4),
                              firstCluster: d.le32(s + 20),
                              dataLength: d.le64(s + 24),
                              validLength: d.le64(s + 8),
                              noFatChain: d[d.startIndex + s + 1] & 2 != 0,
                              created: d.le32(o + 8),
                              modified: d.le32(o + 12),
                              modifiedOffset: d[d.startIndex + o + 23],
                              index: i, count: secondary + 1))
            i += secondary + 1
        }
        return out
    }

    private var rootDirectory: Directory {
        get throws { Directory(clusters: try chain(rootCluster, noFatChain: false, length: nil), noFatChain: false, record: nil, parent: []) }
    }

    private func upper(_ s: String) -> [UInt16] {
        s.utf16.map { upcase[Int($0)] }
    }

    private func find(_ name: String, in dir: Directory) throws -> Record? {
        let key = upper(name)
        return try records(in: dir).first { upper($0.name) == key }
    }

    private func directory(_ parts: [String]) throws -> Directory {
        var dir = try rootDirectory
        var path: [String] = []
        for part in parts {
            guard let r = try find(part, in: dir) else { throw MirageError.notFound("/\((path + [part]).joined(separator: "/")) does not exist") }
            guard r.isDirectory else { throw MirageError.invalid("\(part) is not a directory") }
            dir = Directory(clusters: try chain(r.firstCluster, noFatChain: r.noFatChain, length: r.dataLength),
                            noFatChain: r.noFatChain, record: r, parent: path)
            path.append(part)
        }
        return dir
    }

    private func locate(_ path: String) throws -> (Directory, Record) {
        let parts = GuestPath.components(path)
        guard let last = parts.last else { throw MirageError.invalid("The root has no entry") }
        let dir = try directory(Array(parts.dropLast()))
        guard let r = try find(last, in: dir) else { throw MirageError.notFound("\(path) does not exist") }
        return (dir, r)
    }

    private func entryOffset(_ dir: Directory, _ index: Int) -> UInt64 {
        let byte = index * 32
        return clusterOffset(dir.clusters[byte / clusterSize]) + UInt64(byte % clusterSize)
    }

    private func writeEntries(_ dir: Directory, at index: Int, _ set: Data) throws {
        for k in 0..<(set.count / 32) {
            try region.write(entryOffset(dir, index + k), set.subdata(in: (k * 32)..<(k * 32 + 32)))
        }
    }

    private func checksum(_ set: inout Data) {
        var sum: UInt16 = 0
        for i in 0..<set.count where i != 2 && i != 3 {
            sum = (sum & 1 != 0 ? 0x8000 : 0) &+ (sum >> 1) &+ UInt16(set[set.startIndex + i])
        }
        set.putLE16(sum, at: 2)
    }

    private func entrySet(_ r: Record) -> Data {
        let units = Array(r.name.utf16)
        let nameEntries = (units.count + 14) / 15
        var set = Data(count: 32 * (2 + nameEntries))
        set[0] = 0x85
        set[1] = UInt8(1 + nameEntries)
        set.putLE16(r.attributes, at: 4)
        set.putLE32(r.created, at: 8)
        set.putLE32(r.modified, at: 12)
        set.putLE32(r.modified, at: 16)
        set[22] = 0x80
        set[23] = 0x80
        set[24] = 0x80
        set[32] = 0xC0
        set[33] = 0x01 | (r.noFatChain ? 0x02 : 0)
        set[35] = UInt8(units.count)
        var hash: UInt16 = 0
        for u in upper(r.name) {
            for b in [UInt8(u & 0xFF), UInt8(u >> 8)] {
                hash = (hash & 1 != 0 ? 0x8000 : 0) &+ (hash >> 1) &+ UInt16(b)
            }
        }
        set.putLE16(hash, at: 36)
        set.putLE64(r.validLength, at: 40)
        set.putLE32(r.firstCluster, at: 52)
        set.putLE64(r.dataLength, at: 56)
        for k in 0..<nameEntries {
            let e = 64 + k * 32
            set[e] = 0xC1
            for c in 0..<15 where k * 15 + c < units.count {
                set.putLE16(units[k * 15 + c], at: e + 2 + c * 2)
            }
        }
        checksum(&set)
        return set
    }

    /// Writes a directory's grown size into its own entry set.
    private func updateDirectoryRecord(_ dir: Directory, clusters: [UInt32], noFatChain: Bool) throws {
        guard var r = dir.record else { return }
        let parent = try directory(dir.parent)
        r.dataLength = UInt64(clusters.count * clusterSize)
        r.validLength = r.dataLength
        r.noFatChain = noFatChain
        try writeEntries(parent, at: r.index, entrySet(r))
    }

    /// Room for `count` entries, growing the directory when it is full.
    private func freeSlot(_ count: Int, in dir: inout Directory) throws -> Int {
        while true {
            let d = try entries(of: dir)
            let n = d.count / 32
            var run = 0
            for i in 0..<n {
                if d[d.startIndex + i * 32] & 0x80 == 0 {
                    run += 1
                    if run == count { return i - count + 1 }
                } else {
                    run = 0
                }
            }
            let last = dir.clusters.last!
            let (new, contiguous) = try allocate(1, after: last + 1)
            let c = new[0]
            try mark(new, used: true)
            try region.write(clusterOffset(c), Data(count: clusterSize))
            if dir.noFatChain && !(contiguous && c == last + 1) {
                try writeChain(dir.clusters)
                dir.noFatChain = false
            }
            if !dir.noFatChain {
                try setFAT(last, c)
                try setFAT(c, 0xFFFF_FFFF)
            }
            dir.clusters.append(c)
            try updateDirectoryRecord(dir, clusters: dir.clusters, noFatChain: dir.noFatChain)
        }
    }

    private func insert(_ r: Record, into dir: inout Directory) throws {
        let set = entrySet(r)
        let at = try freeSlot(set.count / 32, in: &dir)
        try writeEntries(dir, at: at, set)
    }

    private func unlink(_ r: Record, in dir: Directory) throws {
        for k in 0..<r.count {
            let off = entryOffset(dir, r.index + k)
            var e = try region.read(off, 1)
            e[e.startIndex] &= 0x7F
            try region.write(off, e)
        }
    }

    private func removeTree(_ r: Record, in dir: Directory, path: [String]) throws {
        if r.isDirectory {
            let sub = Directory(clusters: try chain(r.firstCluster, noFatChain: r.noFatChain, length: r.dataLength),
                                noFatChain: r.noFatChain, record: r, parent: path)
            for child in try records(in: sub) {
                try removeTree(child, in: sub, path: path + [r.name])
            }
        }
        try free(r)
        try unlink(r, in: dir)
    }

    private static func timestamp(_ date: Date = Date()) -> UInt32 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = UInt32(max(0, (c.year ?? 1980) - 1980))
        return year << 25 | UInt32(c.month ?? 1) << 21 | UInt32(c.day ?? 1) << 16
            | UInt32(c.hour ?? 0) << 11 | UInt32(c.minute ?? 0) << 5 | UInt32((c.second ?? 0) / 2)
    }

    /// exFAT times are local; the offset byte (bit 7 = valid, signed
    /// 15-minute steps) says from which zone, else the host's is assumed.
    private static func date(_ t: UInt32, offset: UInt8) -> Date? {
        guard t != 0 else { return nil }
        var c = DateComponents()
        c.year = Int(t >> 25) + 1980
        c.month = Int(t >> 21 & 0xF)
        c.day = Int(t >> 16 & 0x1F)
        c.hour = Int(t >> 11 & 0x1F)
        c.minute = Int(t >> 5 & 0x3F)
        c.second = Int(t & 0x1F) * 2
        var cal = Calendar(identifier: .gregorian)
        if offset & 0x80 != 0 {
            let steps = Int(Int8(bitPattern: (offset & 0x7F) << 1) >> 1)
            cal.timeZone = TimeZone(secondsFromGMT: steps * 15 * 60) ?? .gmt
        } else {
            cal.timeZone = .current
        }
        return cal.date(from: c)
    }

    // MARK: GuestFileSystem

    public func list(_ path: String) async throws -> [GuestEntry] {
        return try lock.withLock {
            let dir = try directory(GuestPath.components(path))
            return try records(in: dir).map {
                GuestEntry(name: $0.name, path: GuestPath.join(path, $0.name), isDirectory: $0.isDirectory,
                           size: $0.isDirectory ? 0 : Int64($0.validLength), modified: Self.date($0.modified, offset: $0.modifiedOffset),
                           mode: $0.isDirectory ? "drwxrwxrwx" : "-rwxrwxrwx")
            }
        }
    }

    public func read(_ path: String, progress: (@Sendable (Double) -> Void)?) async throws -> Data {
        return try lock.withLock {
            let (_, r) = try locate(path)
            guard !r.isDirectory else { throw MirageError.invalid("\(path) is a directory") }
            let clusters = try chain(r.firstCluster, noFatChain: r.noFatChain, length: r.dataLength)
            return try readClusters(clusters, length: Int(r.validLength))
        }
    }

    public func write(_ path: String, data: Data, progress: (@Sendable (Double) -> Void)?) async throws {
        try lock.withLock {
            guard !isReadOnly else { throw MirageError.invalid("The volume is read-only") }
            let parts = GuestPath.components(path)
            guard let name = parts.last else { throw MirageError.invalid("No file name") }
            var dir = try directory(Array(parts.dropLast()))
            var created = Self.timestamp()
            if let old = try find(name, in: dir) {
                guard !old.isDirectory else { throw MirageError.invalid("\(path) is a directory") }
                created = old.created
                try free(old)
                try unlink(old, in: dir)
            }
            let count = (data.count + clusterSize - 1) / clusterSize
            let (clusters, contiguous) = try allocate(count)
            try mark(clusters, used: true)
            if !contiguous { try writeChain(clusters) }
            var padded = data
            if padded.count % clusterSize != 0 { padded.append(Data(count: clusterSize - padded.count % clusterSize)) }
            for (i, c) in clusters.enumerated() {
                try region.write(clusterOffset(c), padded.subdata(in: (i * clusterSize)..<((i + 1) * clusterSize)))
                progress?(Double(i + 1) / Double(clusters.count))
            }
            let r = Record(name: name, attributes: 0x20, firstCluster: clusters.first ?? 0,
                           dataLength: UInt64(data.count), validLength: UInt64(data.count),
                           noFatChain: contiguous && !clusters.isEmpty, created: created, modified: Self.timestamp(),
                           index: 0, count: 0)
            try insert(r, into: &dir)
            region.synchronize()
        }
    }

    public func createDirectory(_ path: String) async throws {
        try lock.withLock {
            guard !isReadOnly else { throw MirageError.invalid("The volume is read-only") }
            let parts = GuestPath.components(path)
            guard let name = parts.last else { return }
            var dir = try directory(Array(parts.dropLast()))
            if try find(name, in: dir) != nil { throw MirageError.invalid("\(path) already exists") }
            let (clusters, _) = try allocate(1)
            try mark(clusters, used: true)
            try region.write(clusterOffset(clusters[0]), Data(count: clusterSize))
            let now = Self.timestamp()
            let r = Record(name: name, attributes: 0x10, firstCluster: clusters[0],
                           dataLength: UInt64(clusterSize), validLength: UInt64(clusterSize),
                           noFatChain: true, created: now, modified: now, index: 0, count: 0)
            try insert(r, into: &dir)
            region.synchronize()
        }
    }

    public func remove(_ path: String) async throws {
        try lock.withLock {
            guard !isReadOnly else { throw MirageError.invalid("The volume is read-only") }
            let (dir, r) = try locate(path)
            try removeTree(r, in: dir, path: Array(GuestPath.components(path).dropLast()))
            region.synchronize()
        }
    }

    public func rename(_ path: String, to newPath: String) async throws {
        try lock.withLock {
            guard !isReadOnly else { throw MirageError.invalid("The volume is read-only") }
            let (from, r) = try locate(path)
            let parts = GuestPath.components(newPath)
            guard let name = parts.last else { throw MirageError.invalid("No target name") }
            var target = try directory(Array(parts.dropLast()))
            if let existing = try find(name, in: target), existing.index != r.index || from.clusters != target.clusters {
                throw MirageError.invalid("\(newPath) already exists")
            }
            try unlink(r, in: from)
            var moved = r
            moved.name = name
            moved.modified = Self.timestamp()
            target = try directory(Array(parts.dropLast()))
            try insert(moved, into: &target)
            region.synchronize()
        }
    }
}
