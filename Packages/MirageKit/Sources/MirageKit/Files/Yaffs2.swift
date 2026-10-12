import Foundation

/// A yaffs2 partition in a page-major SPI NAND image (2048-byte pages with
/// inband tags, 64 pages per block, OOB unused), as the band firmware mounts
/// /data and /system. Reads by scanning every chunk the way yaffs2 does at
/// mount; writes append chunks to erased blocks with new sequence numbers,
/// so the firmware sees the change on its next mount.
public final class YaffsVolume: GuestFileSystem, @unchecked Sendable {
    public struct Layout: Sendable {
        public var pageSize = 2048
        public var oobSize = 64
        public var pagesPerBlock = 64
        public var firstPage: Int
        public var pages: Int

        public init(firstPage: Int, pages: Int) {
            self.firstPage = firstPage
            self.pages = pages
        }

        init(spec: NANDSpec, firstPage: Int, pages: Int) {
            pageSize = spec.pageSize
            oobSize = spec.oobSize
            pagesPerBlock = spec.pagesPerBlock
            self.firstPage = firstPage
            self.pages = pages
        }

        var blocks: Int { pages / pagesPerBlock }
        var dataBytes: Int { pageSize - 16 }
        var stride: UInt64 { UInt64(pageSize + oobSize) }
    }

    private struct Object {
        var id: UInt32
        var type: UInt32
        var parent: UInt32
        var name: String
        var size: UInt64
        var mode: UInt32
        var mtime: UInt32
        var equiv: UInt32
        var alias: String
        var key: UInt64
    }

    private struct Chunk {
        var page: Int
        var bytes: Int
        var key: UInt64
    }

    private static let typeFile: UInt32 = 1, typeSymlink: UInt32 = 2, typeDir: UInt32 = 3, typeHardlink: UInt32 = 4
    private static let root: UInt32 = 1, unlinked: UInt32 = 3, deleted: UInt32 = 4
    private static let headerFlag: UInt32 = 0x8000_0000, shrinkFlag: UInt32 = 0x4000_0000

    private let url: URL
    private let layout: Layout
    private let handle: FileHandle
    private var objects: [UInt32: Object] = [:]
    private var chunks: [UInt32: [UInt32: Chunk]] = [:]
    private var blockSeq: [UInt32]
    private var maxSeq: UInt32 = 0x1000
    private var maxObject: UInt32 = 256
    private var current: (block: Int, next: Int)?
    private var checkpointCleared = false
    private let lock = NSLock()

    public let isReadOnly: Bool

    public init(url: URL, layout: Layout, writable: Bool) throws {
        self.url = url
        self.layout = layout
        isReadOnly = !writable
        handle = writable ? try FileHandle(forUpdating: url) : try FileHandle(forReadingFrom: url)
        blockSeq = Array(repeating: 0, count: layout.blocks)
        try scan()
    }

    deinit { try? handle.close() }

    // MARK: Scan

    private func pageOffset(_ page: Int) -> UInt64 {
        UInt64(layout.firstPage + page) * layout.stride
    }

    private func scan() throws {
        let ppb = layout.pagesPerBlock
        for b in 0..<layout.blocks {
            try handle.seek(toOffset: pageOffset(b * ppb) + UInt64(layout.dataBytes))
            guard let first = try handle.read(upToCount: 16), first.count == 16 else { continue }
            let seq0 = first.le32(0)
            if seq0 == 0xFFFF_FFFF { continue }
            blockSeq[b] = seq0
            guard seq0 >= 0x1000 && seq0 < 0xEFFF_FF00 else { continue }   // checkpoint or foreign data
            maxSeq = max(maxSeq, seq0)
            try handle.seek(toOffset: pageOffset(b * ppb))
            guard let block = try handle.read(upToCount: ppb * Int(layout.stride)) else { continue }
            for p in 0..<ppb {
                let o = p * Int(layout.stride)
                guard o + layout.pageSize <= block.count else { break }
                let t = o + layout.dataBytes
                let seq = block.le32(t)
                if seq == 0xFFFF_FFFF { break }
                let objField = block.le32(t + 4), chunkField = block.le32(t + 8), nBytes = Int(block.le32(t + 12))
                let key = UInt64(seq) << 8 | UInt64(p)
                let page = b * ppb + p
                if chunkField & Self.headerFlag != 0 || chunkField == 0 {
                    let id = chunkField & Self.headerFlag != 0 ? objField & 0x0FFF_FFFF : objField
                    guard id != 0 else { continue }
                    if let old = objects[id], old.key > key { continue }
                    let h = block.subdata(in: o..<(o + layout.dataBytes))
                    objects[id] = header(h, id: id, key: key)
                    maxObject = max(maxObject, id)
                } else if nBytes <= layout.dataBytes {
                    let id = objField
                    if let old = chunks[id]?[chunkField], old.key > key { continue }
                    chunks[id, default: [:]][chunkField] = Chunk(page: page, bytes: nBytes, key: key)
                    maxObject = max(maxObject, id)
                }
            }
        }
    }

    private func header(_ h: Data, id: UInt32, key: UInt64) -> Object {
        let nameBytes = h.subdata(in: 10..<266)
        let name = String(decoding: nameBytes.prefix(while: { $0 != 0 && $0 != 0xFF }), as: UTF8.self)
        let aliasBytes = h.subdata(in: 300..<460)
        var size = UInt64(h.le32(292))
        let high = h.le32(496)
        if high != 0xFFFF_FFFF { size |= UInt64(high) << 32 }
        return Object(id: id, type: h.le32(0), parent: h.le32(4), name: name, size: size,
                      mode: h.le32(268), mtime: h.le32(284), equiv: h.le32(296),
                      alias: String(decoding: aliasBytes.prefix(while: { $0 != 0 && $0 != 0xFF }), as: UTF8.self),
                      key: key)
    }

    // MARK: Tree

    private func isLive(_ o: Object) -> Bool {
        var p = o.parent
        var hops = 0
        while p != Self.root {
            guard p != Self.unlinked, p != Self.deleted, let parent = objects[p], parent.type == Self.typeDir, hops < 64 else { return false }
            p = parent.parent
            hops += 1
        }
        return o.id != Self.root && o.type != 0
    }

    private func children(of dir: UInt32) -> [Object] {
        objects.values.filter { $0.parent == dir && $0.id != Self.root && isLive($0) }.sorted { $0.name < $1.name }
    }

    private func lookup(_ path: String) throws -> Object {
        var id = Self.root
        var o = objects[Self.root] ?? Object(id: Self.root, type: Self.typeDir, parent: 0, name: "", size: 0, mode: 0o777,
                                             mtime: 0, equiv: 0, alias: "", key: 0)
        for part in GuestPath.components(path) {
            guard o.type == Self.typeDir, let next = children(of: id).first(where: { $0.name == part }) else {
                throw MirageError.notFound("\(path) does not exist")
            }
            o = next
            id = next.id
        }
        return o
    }

    private func modeString(_ o: Object) -> String {
        let t = o.type == Self.typeDir ? "d" : o.type == Self.typeSymlink ? "l" : "-"
        let bits = "rwxrwxrwx"
        return t + String(bits.enumerated().map { i, c in o.mode & (1 << (8 - i)) != 0 ? c : "-" })
    }

    private func contents(_ o: Object) throws -> Data {
        var o = o
        if o.type == Self.typeHardlink, let target = objects[o.equiv] { o = target }
        if o.type == Self.typeSymlink { return Data(o.alias.utf8) }
        let size = Int(o.size)
        var out = Data(count: size)
        guard let map = chunks[o.id] else { return out }
        for (index, c) in map where index >= 1 {
            let start = Int(index - 1) * layout.dataBytes
            guard start < size else { continue }
            let n = min(c.bytes, size - start)
            try handle.seek(toOffset: pageOffset(c.page))
            if let d = try handle.read(upToCount: n) {
                out.replaceSubrange(start..<(start + d.count), with: d)
            }
        }
        return out
    }

    // MARK: Writing

    private func eraseBlock(_ b: Int) throws {
        let blank = Data(repeating: 0xFF, count: layout.pagesPerBlock * Int(layout.stride))
        try handle.seek(toOffset: pageOffset(b * layout.pagesPerBlock))
        try handle.write(contentsOf: blank)
        blockSeq[b] = 0
    }

    /// yaffs2 restores a saved checkpoint instead of scanning when one is
    /// present, which would hide everything written here; erasing it forces
    /// the scan.
    private func clearCheckpoint() throws {
        guard !checkpointCleared else { return }
        for b in 0..<layout.blocks where blockSeq[b] != 0 && blockSeq[b] < 0x1000 {
            try eraseBlock(b)
        }
        checkpointCleared = true
    }

    private func nextPage(reserve: Int) throws -> (page: Int, seq: UInt32) {
        if let c = current, c.next < layout.pagesPerBlock {
            current = (c.block, c.next + 1)
            return (c.block * layout.pagesPerBlock + c.next, blockSeq[c.block])
        }
        let erased = (0..<layout.blocks).filter { blockSeq[$0] == 0 }
        guard erased.count > reserve, let b = erased.first else {
            throw MirageError.io("The partition is full")
        }
        maxSeq += 1
        blockSeq[b] = maxSeq
        current = (b, 1)
        return (b * layout.pagesPerBlock, maxSeq)
    }

    private func append(payload: Data, obj: UInt32, chunk: UInt32, bytes: UInt32) throws -> (page: Int, key: UInt64) {
        let (page, seq) = try nextPage(reserve: 8)
        var image = Data(repeating: 0xFF, count: Int(layout.stride))
        image.replaceSubrange(0..<payload.count, with: payload)
        var tags = Data(count: 16)
        tags.putLE32(seq, at: 0)
        tags.putLE32(obj, at: 4)
        tags.putLE32(chunk, at: 8)
        tags.putLE32(bytes, at: 12)
        image.replaceSubrange(layout.dataBytes..<layout.pageSize, with: tags)
        try handle.seek(toOffset: pageOffset(page))
        try handle.write(contentsOf: image)
        return (page, UInt64(seq) << 8 | UInt64(page % layout.pagesPerBlock))
    }

    private func headerPayload(_ o: Object) -> Data {
        var h = Data(repeating: 0xFF, count: layout.dataBytes)
        let now = UInt32(Date().timeIntervalSince1970)
        h.putLE32(o.type, at: 0)
        h.putLE32(o.parent, at: 4)
        let raw = Array(o.name.utf8.prefix(255))
        h.replaceSubrange(10..<(10 + raw.count), with: raw)
        h[10 + raw.count] = 0
        h.putLE32(o.mode, at: 268)
        h.putLE32(0, at: 272)
        h.putLE32(0, at: 276)
        for off in [280, 284, 288] { h.putLE32(now, at: off) }
        let isFile = o.type == Self.typeFile
        h.putLE32(isFile ? UInt32(o.size & 0xFFFF_FFFF) : 0xFFFF_FFFF, at: 292)
        h.putLE32(o.type == Self.typeHardlink ? o.equiv : 0xFFFF_FFFF, at: 296)
        if o.type == Self.typeSymlink {
            let a = Array(o.alias.utf8.prefix(159))
            h.replaceSubrange(300..<(300 + a.count), with: a)
            h[300 + a.count] = 0
        }
        h.putLE32(0, at: 460)
        for (i, off) in [464, 468, 472, 476, 480, 484].enumerated() { h.putLE32(i % 2 == 0 ? now : 0, at: off) }
        h.putLE32(0, at: 488)
        h.putLE32(isFile ? UInt32(o.size >> 32) : 0xFFFF_FFFF, at: 496)
        h.putLE32(0, at: 504)
        h.putLE32(0, at: 508)
        return h
    }

    private func writeHeader(_ o: Object, shrink: Bool = false) throws {
        var o = o
        let chunk = Self.headerFlag | (shrink ? Self.shrinkFlag : 0) | o.parent
        let size = o.type == Self.typeFile ? UInt32(o.size & 0xFFFF_FFFF) : 0
        let (_, key) = try append(payload: headerPayload(o), obj: o.id | o.type << 28, chunk: chunk, bytes: size)
        o.key = key
        objects[o.id] = o
        maxObject = max(maxObject, o.id)
    }

    private func delete(_ o: Object) throws {
        if o.type == Self.typeDir {
            for child in children(of: o.id) { try delete(child) }
        }
        var gone = o
        gone.parent = Self.deleted
        gone.name = "deleted"
        gone.size = 0
        try writeHeader(gone, shrink: o.type == Self.typeFile)
        chunks[o.id] = nil
    }

    private func parentAndName(_ path: String) throws -> (Object, String) {
        let parts = GuestPath.components(path)
        guard let name = parts.last else { throw MirageError.invalid("No name") }
        let parent = try lookup("/" + parts.dropLast().joined(separator: "/"))
        guard parent.type == Self.typeDir else { throw MirageError.invalid("\(GuestPath.parent(path)) is not a directory") }
        return (parent, name)
    }

    // MARK: GuestFileSystem

    public func list(_ path: String) async throws -> [GuestEntry] {
        return try lock.withLock {
            let dir = try lookup(path)
            guard dir.type == Self.typeDir else { throw MirageError.invalid("\(path) is not a directory") }
            return children(of: dir.id).map { o in
                var size = o.size
                if o.type == Self.typeHardlink, let t = objects[o.equiv] { size = t.size }
                return GuestEntry(name: o.name, path: GuestPath.join(path, o.name), isDirectory: o.type == Self.typeDir,
                                  size: o.type == Self.typeDir ? 0 : Int64(size),
                                  modified: o.mtime == 0 || o.mtime == 0xFFFF_FFFF ? nil : Date(timeIntervalSince1970: TimeInterval(o.mtime)),
                                  mode: modeString(o))
            }
        }
    }

    public func read(_ path: String, progress: (@Sendable (Double) -> Void)?) async throws -> Data {
        return try lock.withLock {
            let o = try lookup(path)
            guard o.type != Self.typeDir else { throw MirageError.invalid("\(path) is a directory") }
            return try contents(o)
        }
    }

    public func write(_ path: String, data: Data, progress: (@Sendable (Double) -> Void)?) async throws {
        try lock.withLock {
            guard !isReadOnly else { throw MirageError.invalid("The volume is read-only") }
            try clearCheckpoint()
            let (parent, name) = try parentAndName(path)
            let old = children(of: parent.id).first { $0.name == name }
            if let old, old.type == Self.typeDir { throw MirageError.invalid("\(path) is a directory") }
            let id = maxObject + 1
            maxObject = id
            var map: [UInt32: Chunk] = [:]
            let n = (data.count + layout.dataBytes - 1) / layout.dataBytes
            for i in 0..<n {
                let part = data.subdata(in: (i * layout.dataBytes)..<min(data.count, (i + 1) * layout.dataBytes))
                let (page, key) = try append(payload: part, obj: id, chunk: UInt32(i + 1), bytes: UInt32(part.count))
                map[UInt32(i + 1)] = Chunk(page: page, bytes: part.count, key: key)
                progress?(Double(i + 1) / Double(n + 1))
            }
            chunks[id] = map
            try writeHeader(Object(id: id, type: Self.typeFile, parent: parent.id, name: name, size: UInt64(data.count),
                                   mode: old?.mode ?? 0o644, mtime: 0, equiv: 0, alias: "", key: 0))
            if let old { try delete(old) }
            try handle.synchronize()
        }
    }

    public func createDirectory(_ path: String) async throws {
        try lock.withLock {
            guard !isReadOnly else { throw MirageError.invalid("The volume is read-only") }
            try clearCheckpoint()
            let (parent, name) = try parentAndName(path)
            guard !children(of: parent.id).contains(where: { $0.name == name }) else { throw MirageError.invalid("\(path) already exists") }
            maxObject += 1
            try writeHeader(Object(id: maxObject, type: Self.typeDir, parent: parent.id, name: name, size: 0,
                                   mode: 0o777, mtime: 0, equiv: 0, alias: "", key: 0))
            try handle.synchronize()
        }
    }

    public func remove(_ path: String) async throws {
        try lock.withLock {
            guard !isReadOnly else { throw MirageError.invalid("The volume is read-only") }
            try clearCheckpoint()
            try delete(try lookup(path))
            try handle.synchronize()
        }
    }

    public func rename(_ path: String, to newPath: String) async throws {
        try lock.withLock {
            guard !isReadOnly else { throw MirageError.invalid("The volume is read-only") }
            try clearCheckpoint()
            var o = try lookup(path)
            let (parent, name) = try parentAndName(newPath)
            if let existing = children(of: parent.id).first(where: { $0.name == name }), existing.id != o.id {
                throw MirageError.invalid("\(newPath) already exists")
            }
            o.parent = parent.id
            o.name = name
            try writeHeader(o)
            try handle.synchronize()
        }
    }
}
