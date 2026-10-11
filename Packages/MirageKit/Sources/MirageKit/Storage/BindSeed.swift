import Foundation

/// Bond state for bands whose factory record has no field for the persist.*
/// keys (Band 9 / Band 10). The firmware keeps them in /data/persist.db (an
/// UnQLite file) and /data/misc/bt/miwear_record.db, so both are written into
/// the data partition at provisioning from templates taken from a bound band.
/// The template's keys are replaced in place by this device's own values.
enum BindSeed {
    private struct Key {
        let name: String
        let template: String
        let value: (BindInfo) -> String
    }

    private static let keys: [Key] = [
        Key(name: "persist.miwear_token_key", template: "d8c3ac9607212d61610745828d0b564b") { $0.authKey.lowercased() },
        Key(name: "persist.miwear_user_id", template: "10000001") { $0.userID },
        Key(name: "persist.miwear_beacon_key", template: "8d3f350abe295942e35ea1b13ea06f72") { $0.beaconKey.lowercased() },
        Key(name: "persist.miwear_ir_key", template: "d461619c47c561f3c40e494a1b79f4fc") { $0.irKey.lowercased() },
        Key(name: "persist.miwear_seqnum", template: "1") { $0.seqnum },
    ]

    /// Writes the bond databases into the data partition, which starts at
    /// `spec.systemPages` (Band 9 / Band 10 layout) and is still erased.
    static func apply(to nandURL: URL, spec: NANDSpec, binding: BindInfo) throws {
        guard binding.bound, let dataFirst = spec.systemPages else { return }
        let persist = try persistDatabase(for: binding)
        let record = try recordDatabase(for: binding)
        let objects: [Object] = [
            .directory(oid: 258, parent: 1, name: "misc"),
            .directory(oid: 259, parent: 258, name: "bt"),
            .file(oid: 257, parent: 1, name: "persist.db", data: persist),
            .file(oid: 260, parent: 259, name: "miwear_record.db", data: record),
        ]
        let pages = yaffsPages(objects)
        let pageBytes = spec.pageSize + spec.oobSize
        let capacity = spec.blocks * spec.pagesPerBlock - dataFirst
        guard pages.count <= capacity else {
            throw MirageError.invalid("bond databases do not fit the data partition")
        }
        let handle = try FileHandle(forUpdating: nandURL)
        defer { try? handle.close() }
        for (index, page) in pages.enumerated() {
            var image = Data(repeating: 0xFF, count: pageBytes)
            image.replaceSubrange(0..<page.payload.count, with: page.payload)
            let tag = le32([page.seq, page.obj, page.chunk, page.bytes])
            image.replaceSubrange(spec.pageSize - 16..<spec.pageSize, with: tag)
            try handle.seek(toOffset: UInt64((dataFirst + index) * pageBytes))
            try handle.write(contentsOf: image)
        }
    }

    private static func persistDatabase(for binding: BindInfo) throws -> Data {
        var data = try template("persist.db")
        for key in keys {
            let value = key.value(binding)
            guard value.utf8.count == key.template.utf8.count else {
                throw MirageError.invalid("\(key.name) must be \(key.template.utf8.count) characters")
            }
            let old = frame(key.name, key.template)
            let new = frame(key.name, value)
            guard let range = data.range(of: old) else {
                throw MirageError.invalid("the bond template has no \(key.name)")
            }
            data.replaceSubrange(range, with: new)
        }
        return data
    }

    /// The record database keeps the same keys as raw 16-byte values after
    /// their names (the user id is packed BCD and stays as the template has it).
    private static func recordDatabase(for binding: BindInfo) throws -> Data {
        var data = try template("miwear_record.db")
        let raw: [(template: String, value: String)] = [
            ("d8c3ac9607212d61610745828d0b564b", binding.authKey),
            ("8d3f350abe295942e35ea1b13ea06f72", binding.beaconKey),
            ("d461619c47c561f3c40e494a1b79f4fc", binding.irKey),
        ]
        for (old, new) in raw {
            let oldBytes = try hexBytes(old)
            let newBytes = try hexBytes(new)
            guard oldBytes.count == newBytes.count, let range = data.range(of: Data(oldBytes)) else {
                throw MirageError.invalid("the record template does not carry the bond key \(old.prefix(8))")
            }
            data.replaceSubrange(range, with: Data(newBytes))
        }
        return data
    }

    private static func hexBytes(_ hex: String) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard next > index, let byte = UInt8(hex[index..<next], radix: 16) else {
                throw MirageError.invalid("bond key is not hex: \(hex)")
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func frame(_ name: String, _ value: String) -> Data {
        Data(name.utf8) + Data([0]) + Data(value.utf8) + Data([0])
    }

    private static func template(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "BindTemplate") else {
            throw MirageError.notFound("bind template \(name)")
        }
        return try Data(contentsOf: url)
    }

    private enum Object {
        case directory(oid: UInt32, parent: UInt32, name: String)
        case file(oid: UInt32, parent: UInt32, name: String, data: Data)
    }

    private struct Chunk {
        let payload: Data
        let obj: UInt32
        let chunk: UInt32
        let bytes: UInt32
        var seq: UInt32 = 0
    }

    /// yaffs2 objects with inband tags, as mknand.py writes /system: a header
    /// chunk per object (its tag carries the parent), then the data chunks.
    private static func yaffsPages(_ objects: [Object]) -> [Chunk] {
        var chunks: [Chunk] = []
        for object in objects {
            switch object {
            case let .directory(oid, parent, name):
                let header = yaffsHeader(type: 3, parent: parent, name: name, size: 0xFFFF_FFFF, mode: 0o755)
                chunks.append(Chunk(payload: header, obj: oid | 3 << 28, chunk: 0x8000_0000 | parent, bytes: 0))
            case let .file(oid, parent, name, data):
                let header = yaffsHeader(type: 1, parent: parent, name: name, size: UInt32(data.count), mode: 0o644)
                chunks.append(Chunk(payload: header, obj: oid | 1 << 28, chunk: 0x8000_0000 | parent, bytes: UInt32(data.count)))
                var offset = 0
                var index: UInt32 = 1
                while offset < data.count {
                    let end = min(offset + 2032, data.count)
                    chunks.append(Chunk(payload: data.subdata(in: offset..<end), obj: oid, chunk: index, bytes: UInt32(end - offset)))
                    offset = end
                    index += 1
                }
            }
        }
        for index in chunks.indices {
            chunks[index].seq = 0x1001 + UInt32(index / 64)
        }
        return chunks
    }

    private static func yaffsHeader(type: UInt32, parent: UInt32, name: String, size: UInt32, mode: UInt32) -> Data {
        let time: UInt32 = 946_684_800
        var header = [UInt8](repeating: 0xFF, count: 2032)
        func put(_ value: UInt32, at offset: Int) {
            for byte in 0..<4 { header[offset + byte] = UInt8((value >> (8 * UInt32(byte))) & 0xFF) }
        }
        put(type, at: 0)
        put(parent, at: 4)
        let raw = Array(name.utf8.prefix(255))
        for (index, byte) in raw.enumerated() { header[10 + index] = byte }
        header[10 + raw.count] = 0
        put(mode, at: 268)
        put(0, at: 272)
        put(0, at: 276)
        put(time, at: 280)
        put(time, at: 284)
        put(time, at: 288)
        put(size, at: 292)
        put(0xFFFF_FFFF, at: 296)
        put(0, at: 460)
        put(time, at: 464)
        put(0, at: 468)
        put(time, at: 472)
        put(0, at: 476)
        put(time, at: 480)
        put(0, at: 484)
        put(0, at: 488)
        put(0, at: 496)
        put(0, at: 504)
        put(0, at: 508)
        return Data(header)
    }

    private static func le32(_ values: [UInt32]) -> Data {
        var data = Data()
        for value in values {
            for byte in 0..<4 { data.append(UInt8((value >> (8 * UInt32(byte))) & 0xFF)) }
        }
        return data
    }
}
