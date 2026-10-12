import Foundation

/// One entry of a directory listing on a device.
public struct GuestEntry: Identifiable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?
    /// "drwxr-xr-x"-style permissions, when the file system keeps them.
    public var mode: String?

    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool, size: Int64, modified: Date? = nil, mode: String? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.mode = mode
    }
}

/// A file system on a device: a partition image while it is shut down, or
/// the live tree through its shell while it runs. Paths are absolute within
/// the volume ("/" is its root).
public protocol GuestFileSystem: AnyObject, Sendable {
    var isReadOnly: Bool { get }
    func list(_ path: String) async throws -> [GuestEntry]
    func read(_ path: String, progress: (@Sendable (Double) -> Void)?) async throws -> Data
    func write(_ path: String, data: Data, progress: (@Sendable (Double) -> Void)?) async throws
    func createDirectory(_ path: String) async throws
    /// Removes a file, or a directory with everything in it.
    func remove(_ path: String) async throws
    func rename(_ path: String, to newPath: String) async throws
}

public extension GuestFileSystem {
    func read(_ path: String) async throws -> Data { try await read(path, progress: nil) }
    func write(_ path: String, data: Data) async throws { try await write(path, data: data, progress: nil) }
}

public enum GuestPath {
    public static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
    }

    public static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    public static func parent(_ path: String) -> String {
        let parts = components(path)
        return parts.count <= 1 ? "/" : "/" + parts.dropLast().joined(separator: "/")
    }

    public static func name(_ path: String) -> String {
        components(path).last ?? "/"
    }
}

/// Random access to a byte range of an image file.
final class ImageRegion: @unchecked Sendable {
    let handle: FileHandle
    let base: UInt64
    let size: UInt64
    let writable: Bool

    init(url: URL, offset: UInt64 = 0, size: UInt64? = nil, writable: Bool) throws {
        handle = writable ? try FileHandle(forUpdating: url) : try FileHandle(forReadingFrom: url)
        base = offset
        if let size {
            self.size = size
        } else {
            self.size = try handle.seekToEnd() - offset
        }
        self.writable = writable
    }

    deinit { try? handle.close() }

    func read(_ offset: UInt64, _ count: Int) throws -> Data {
        guard offset + UInt64(count) <= size else { throw MirageError.io("read past the end of the partition") }
        try handle.seek(toOffset: base + offset)
        let d = try handle.read(upToCount: count) ?? Data()
        return d.count == count ? d : d + Data(repeating: 0, count: count - d.count)
    }

    func write(_ offset: UInt64, _ data: Data) throws {
        guard writable else { throw MirageError.invalid("The volume is read-only") }
        guard offset + UInt64(data.count) <= size else { throw MirageError.io("write past the end of the partition") }
        try handle.seek(toOffset: base + offset)
        try handle.write(contentsOf: data)
    }

    func synchronize() {
        try? handle.synchronize()
    }
}

extension Data {
    func le16(_ o: Int) -> UInt16 { UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8 }
    func le32(_ o: Int) -> UInt32 { UInt32(le16(o)) | UInt32(le16(o + 2)) << 16 }
    func le64(_ o: Int) -> UInt64 { UInt64(le32(o)) | UInt64(le32(o + 4)) << 32 }
    func be32(_ o: Int) -> UInt32 {
        UInt32(self[startIndex + o]) << 24 | UInt32(self[startIndex + o + 1]) << 16
            | UInt32(self[startIndex + o + 2]) << 8 | UInt32(self[startIndex + o + 3])
    }

    mutating func putLE16(_ v: UInt16, at o: Int) {
        self[startIndex + o] = UInt8(v & 0xFF)
        self[startIndex + o + 1] = UInt8(v >> 8)
    }

    mutating func putLE32(_ v: UInt32, at o: Int) {
        putLE16(UInt16(v & 0xFFFF), at: o)
        putLE16(UInt16(v >> 16), at: o + 2)
    }

    mutating func putLE64(_ v: UInt64, at o: Int) {
        putLE32(UInt32(v & 0xFFFF_FFFF), at: o)
        putLE32(UInt32(v >> 32), at: o + 4)
    }
}
