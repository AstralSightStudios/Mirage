import Foundation

/// A read-only romfs image (NuttX romfs: "-rom1fs-" header, big-endian
/// 16-byte aligned file headers {next | type, spec, size, checksum, name}).
public final class RomFSVolume: GuestFileSystem, @unchecked Sendable {
    private enum Source {
        case region(ImageRegion)
        case memory(Data)
    }

    private struct Node {
        var name: String
        var isDirectory: Bool
        var size: Int
        var dataOffset: Int
        var firstChild: Int
    }

    private let source: Source
    private let firstEntry: Int
    private let lock = NSLock()

    public var isReadOnly: Bool { true }

    /// The image at `offset` in `url` (a partition).
    public convenience init(url: URL, offset: UInt64 = 0, size: UInt64? = nil) throws {
        try self.init(source: .region(ImageRegion(url: url, offset: offset, size: size, writable: false)))
    }

    /// An image held in memory (a .bin file read from another volume).
    public convenience init(data: Data) throws {
        try self.init(source: .memory(data))
    }

    private init(source: Source) throws {
        self.source = source
        let head: Data
        switch source {
        case .region(let r): head = try r.read(0, 512)
        case .memory(let d): head = d.prefix(512)
        }
        guard head.count >= 32, head.prefix(8) == Data("-rom1fs-".utf8) else {
            throw MirageError.invalid("Not a romfs image")
        }
        let nameEnd = head[16...].firstIndex(of: 0).map { $0 - head.startIndex } ?? 16
        firstEntry = (nameEnd + 1 + 15) & ~15
    }

    public static func isRomFS(_ data: Data) -> Bool {
        data.prefix(8) == Data("-rom1fs-".utf8)
    }

    private func bytes(_ offset: Int, _ count: Int) throws -> Data {
        switch source {
        case .region(let r): return try r.read(UInt64(offset), count)
        case .memory(let d):
            guard offset + count <= d.count else { throw MirageError.io("romfs entry past the end of the image") }
            return d.subdata(in: offset..<(offset + count))
        }
    }

    private func node(at offset: Int) throws -> (Node, next: Int) {
        let h = try bytes(offset, 16 + 256)
        let next = Int(h.be32(0))
        let spec = Int(h.be32(4))
        let size = Int(h.be32(8))
        let end = h[16...].firstIndex(of: 0) ?? h.endIndex
        let name = String(decoding: h[16..<end], as: UTF8.self)
        let dataOffset = offset + ((16 + name.utf8.count + 1 + 15) & ~15)
        var type = next & 7
        var target = offset
        if type == 0 {          // hard link: spec is the target header
            target = spec
            let t = try bytes(spec, 16)
            type = Int(t.be32(0)) & 7
        }
        let isDir = type == 1
        var n = Node(name: name, isDirectory: isDir, size: isDir ? 0 : size, dataOffset: dataOffset, firstChild: isDir ? spec : 0)
        if target != offset {
            let (t, _) = try node(at: target)
            n.size = t.size
            n.dataOffset = t.dataOffset
            n.firstChild = t.firstChild
        }
        return (n, next & ~15)
    }

    private func children(of first: Int) throws -> [Node] {
        var out: [Node] = []
        var off = first
        var guardCount = 0
        while off != 0, guardCount < 100_000 {
            let (n, next) = try node(at: off)
            if n.name != "." && n.name != ".." { out.append(n) }
            off = next
            guardCount += 1
        }
        return out
    }

    private func lookup(_ path: String) throws -> Node {
        var current = Node(name: "/", isDirectory: true, size: 0, dataOffset: 0, firstChild: firstEntry)
        for part in GuestPath.components(path) {
            guard current.isDirectory, let n = try children(of: current.firstChild).first(where: { $0.name == part }) else {
                throw MirageError.notFound("\(path) does not exist")
            }
            current = n
        }
        return current
    }

    public func list(_ path: String) async throws -> [GuestEntry] {
        return try lock.withLock {
            let dir = try lookup(path)
            guard dir.isDirectory else { throw MirageError.invalid("\(path) is not a directory") }
            return try children(of: dir.firstChild).map {
                GuestEntry(name: $0.name, path: GuestPath.join(path, $0.name), isDirectory: $0.isDirectory,
                           size: Int64($0.size), mode: $0.isDirectory ? "dr-xr-xr-x" : "-r--r--r--")
            }
        }
    }

    public func read(_ path: String, progress: (@Sendable (Double) -> Void)?) async throws -> Data {
        return try lock.withLock {
            let n = try lookup(path)
            guard !n.isDirectory else { throw MirageError.invalid("\(path) is a directory") }
            return try bytes(n.dataOffset, n.size)
        }
    }

    public func write(_ path: String, data: Data, progress: (@Sendable (Double) -> Void)?) async throws {
        throw MirageError.invalid("romfs is read-only")
    }

    public func createDirectory(_ path: String) async throws {
        throw MirageError.invalid("romfs is read-only")
    }

    public func remove(_ path: String) async throws {
        throw MirageError.invalid("romfs is read-only")
    }

    public func rename(_ path: String, to newPath: String) async throws {
        throw MirageError.invalid("romfs is read-only")
    }
}
