import CLittleFS
#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// Builds the backing images a device boots from. These are the Swift
/// versions of qemu-miwear's emu/mknor.py, emu/mksensornor.py,
/// emu/mknand.py and emu/mkemmc.py and produce the same bytes.
public enum ImageBuilder {
    public typealias Progress = @Sendable (Double, String) -> Void

    static let chunk = 4 << 20

    // MARK: - NOR

    /// An erased (0xFF) NOR image of `size` bytes.
    public static func createErasedNOR(at url: URL, size: Int) throws {
        let tmp = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tmp)
        defer { try? fh.close() }
        let block = Data(repeating: 0xFF, count: min(chunk, size))
        var left = size
        while left > 0 {
            let n = min(left, block.count)
            try fh.write(contentsOf: n == block.count ? block : block.prefix(n))
            left -= n
        }
        try fh.close()
        try replace(url, with: tmp)
    }

    /// The text of /factory.prop.
    public static func factoryProperties(identity: FactoryIdentity, binding: BindInfo) -> [FactoryIdentity.Property] {
        var props: [FactoryIdentity.Property] = [
            .init(key: "ro.factory.did", value: identity.did),
            .init(key: "ro.factory.psn", value: identity.serial),
            .init(key: "ro.factory.mac_bt", value: identity.bluetoothAddress.uppercased()),
        ]
        var seen = Set(props.map(\.key))
        for p in binding.properties + identity.extra where !seen.contains(p.key) {
            props.append(p)
            seen.insert(p.key)
        }
        return props
    }

    public static func factoryText(_ props: [FactoryIdentity.Property]) -> String {
        props.map { "\($0.key)=\($0.value)\n" }.joined()
    }

    /// The factory partition's bytes: a littlefs with /factory.prop, or the
    /// raw factory record for Band 9 / Band 10.
    public static func factoryPartition(_ part: FactoryPartition, properties: [FactoryIdentity.Property]) throws -> Data {
        if part.isRawInfo {
            return try RawInfo.partition(part, properties: properties)
        }
        let text = Data(factoryText(properties).utf8)
        var image = Data(count: part.size)
        var geo = geometry(part)
        let err: Int32 = image.withUnsafeMutableBytes { img in
            text.withUnsafeBytes { t in
                "/factory.prop".withCString { p1 in
                    "/factory.prop.bkup".withCString { p2 in
                        var files = [
                            mlfs_file(path: p1, data: t.baseAddress, size: t.count),
                            mlfs_file(path: p2, data: t.baseAddress, size: t.count),
                        ]
                        return mlfs_build(img.baseAddress, &geo, &files, files.count)
                    }
                }
            }
        }
        guard err == 0 else { throw MirageError.io("littlefs format failed (\(err))") }
        return image
    }

    /// Writes the factory partition into an existing NOR image in place.
    public static func writeFactory(into nor: URL, part: FactoryPartition, properties: [FactoryIdentity.Property]) throws {
        let data = try factoryPartition(part, properties: properties)
        let fh = try FileHandle(forUpdating: nor)
        defer { try? fh.close() }
        let size = try fh.seekToEnd()
        guard UInt64(part.offset + part.size) <= size else {
            throw MirageError.io("\(nor.lastPathComponent) is too small for the factory partition")
        }
        try fh.seek(toOffset: UInt64(part.offset))
        try fh.write(contentsOf: data)
    }

    /// Reads /factory.prop back out of a NOR image.
    public static func readFactory(from nor: URL, part: FactoryPartition) throws -> [FactoryIdentity.Property] {
        let fh = try FileHandle(forReadingFrom: nor)
        defer { try? fh.close() }
        try fh.seek(toOffset: UInt64(part.offset))
        guard let region = try fh.read(upToCount: part.size), region.count == part.size else {
            throw MirageError.io("\(nor.lastPathComponent) is too small for the factory partition")
        }
        if part.isRawInfo {
            return try RawInfo.properties(in: region)
        }
        var geo = geometry(part)
        var out = [UInt8](repeating: 0, count: 64 << 10)
        let n = region.withUnsafeBytes { img in
            mlfs_read(img.baseAddress, &geo, "/factory.prop", &out, out.count)
        }
        guard n >= 0 else {
            throw MirageError.io(n == -84 ? "No factory filesystem in \(nor.lastPathComponent)"
                                          : "littlefs read failed (\(n))")
        }
        let text = String(decoding: out.prefix(Int(n)), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { line -> FactoryIdentity.Property? in
            let kv = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { return nil }
            return FactoryIdentity.Property(key: String(kv[0]), value: String(kv[1]))
        }
    }

    static func geometry(_ part: FactoryPartition) -> mlfs_geometry {
        mlfs_geometry(block_size: UInt32(part.blockSize), block_count: UInt32(part.blockCount),
                      read_size: UInt32(part.ioSize), prog_size: UInt32(part.ioSize),
                      name_max: UInt32(part.nameMax), disk_version: part.diskVersion)
    }

    // MARK: - NAND

    /// Page-major SPI NAND image (page data, then OOB, per page; erased =
    /// 0xFF) with the resource romfs at the start of the resource partition.
    public static func buildNAND(at url: URL, spec: NANDSpec, resource: URL?, systemDir: URL? = nil,
                                 progress: Progress? = nil) throws {
        if let systemPages = spec.systemPages {
            guard let systemDir else {
                throw MirageError.invalid("The /system partition needs the firmware package's files")
            }
            try buildSystemNAND(at: url, spec: spec, systemPages: systemPages,
                                files: try Yaffs2.systemFiles(in: systemDir), progress: progress)
            return
        }
        let tmp = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmp)
        defer { try? out.close() }
        let res = try resource.map { try FileHandle(forReadingFrom: $0) }
        defer { try? res?.close() }
        let resSize = try resource.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int ?? 0 } ?? 0
        guard resSize <= spec.resourcePages * spec.pageSize else {
            throw MirageError.invalid("The resource image (\(resSize) bytes) does not fit the \(spec.resourcePages)-page resource partition")
        }
        let resPages = (resSize + spec.pageSize - 1) / spec.pageSize
        let erasedPage = Data(repeating: 0xFF, count: spec.pageSize + spec.oobSize)
        let erasedBlock = Data(repeating: 0xFF, count: (spec.pageSize + spec.oobSize) * spec.pagesPerBlock)
        let oob = Data(repeating: 0xFF, count: spec.oobSize)
        var pending = Data()
        pending.reserveCapacity(chunk + erasedBlock.count)
        for blk in 0..<spec.blocks {
            if blk % 64 == 0 {
                try Task.checkCancellation()
                progress?(Double(blk) / Double(spec.blocks), "Writing NAND")
            }
            let first = blk * spec.pagesPerBlock
            if first + spec.pagesPerBlock <= spec.resourceFirstPage || first >= spec.resourceFirstPage + resPages {
                pending.append(erasedBlock)
            } else {
                for row in first..<(first + spec.pagesPerBlock) {
                    let p = row - spec.resourceFirstPage
                    if p >= 0 && p < resPages, let res {
                        var page = try res.read(upToCount: spec.pageSize) ?? Data()
                        if page.count < spec.pageSize {
                            page.append(Data(repeating: 0xFF, count: spec.pageSize - page.count))
                        }
                        pending.append(page)
                        pending.append(oob)
                    } else {
                        pending.append(erasedPage)
                    }
                }
            }
            if pending.count >= chunk {
                try out.write(contentsOf: pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        try out.write(contentsOf: pending)
        try out.close()
        try replace(url, with: tmp)
        progress?(1, "NAND ready")
    }

    /// Writes the yaffs2 /system partition at page 0 and erases the rest of
    /// the image, the way a freshly formatted device has it.
    static func buildSystemNAND(at url: URL, spec: NANDSpec, systemPages: Int,
                                files: [Yaffs2.File], progress: Progress?) throws {
        let need = try Yaffs2.pageCount(files)
        guard need <= systemPages else {
            throw MirageError.invalid("/system needs \(need) pages, the partition has \(systemPages)")
        }
        let tmp = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmp)
        defer { try? out.close() }
        let oob = Data(repeating: 0xFF, count: spec.oobSize)
        let erasedPage = Data(repeating: 0xFF, count: spec.pageSize) + oob
        let totalPages = spec.blocks * spec.pagesPerBlock
        var pending = Data()
        pending.reserveCapacity(chunk + erasedPage.count)
        try Yaffs2.forEachPage(files) { page in
            pending.append(page)
            pending.append(oob)
            if pending.count >= chunk {
                try out.write(contentsOf: pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        for p in need..<totalPages {
            if p % 4096 == 0 {
                try Task.checkCancellation()
                progress?(Double(p) / Double(totalPages), "Writing NAND")
            }
            pending.append(erasedPage)
            if pending.count >= chunk {
                try out.write(contentsOf: pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        try out.write(contentsOf: pending)
        try out.close()
        try replace(url, with: tmp)
        progress?(1, "NAND ready")
    }

    /// Rewrites the /system partition of an existing NAND image on a firmware
    /// change. The partition is erased first so no page of the old tree is
    /// left behind; /data is not touched.
    public static func updateSystemNAND(at url: URL, spec: NANDSpec, systemDir: URL, progress: Progress? = nil) throws {
        guard let systemPages = spec.systemPages else {
            throw MirageError.invalid("This NAND layout has no yaffs /system partition")
        }
        let files = try Yaffs2.systemFiles(in: systemDir)
        let need = try Yaffs2.pageCount(files)
        guard need <= systemPages else {
            throw MirageError.invalid("/system needs \(need) pages, the partition has \(systemPages)")
        }
        let fh = try FileHandle(forUpdating: url)
        defer { try? fh.close() }
        let oob = Data(repeating: 0xFF, count: spec.oobSize)
        let erasedPage = Data(repeating: 0xFF, count: spec.pageSize) + oob
        try fh.seek(toOffset: 0)
        var pending = Data()
        try Yaffs2.forEachPage(files) { page in
            pending.append(page)
            pending.append(oob)
            if pending.count >= chunk {
                try fh.write(contentsOf: pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        for p in need..<systemPages {
            if p % 4096 == 0 {
                try Task.checkCancellation()
                progress?(Double(p) / Double(systemPages), "Updating /system")
            }
            pending.append(erasedPage)
            if pending.count >= chunk {
                try fh.write(contentsOf: pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        try fh.write(contentsOf: pending)
        progress?(1, "/system updated")
    }

    /// Rewrites only the resource partition of an existing NAND image (a
    /// firmware update), leaving /data and the other partitions alone.
    public static func updateNANDResource(at url: URL, spec: NANDSpec, resource: URL, progress: Progress? = nil) throws {
        let resSize = (try FileManager.default.attributesOfItem(atPath: resource.path)[.size] as? Int) ?? 0
        guard resSize <= spec.resourcePages * spec.pageSize else {
            throw MirageError.invalid("The resource image does not fit the resource partition")
        }
        let fh = try FileHandle(forUpdating: url)
        defer { try? fh.close() }
        let res = try FileHandle(forReadingFrom: resource)
        defer { try? res.close() }
        let stride = spec.pageSize + spec.oobSize
        try fh.seek(toOffset: UInt64(spec.resourceFirstPage * stride))
        let oob = Data(repeating: 0xFF, count: spec.oobSize)
        var pending = Data()
        for p in 0..<spec.resourcePages {
            if p % 4096 == 0 {
                try Task.checkCancellation()
                progress?(Double(p) / Double(spec.resourcePages), "Updating resource partition")
            }
            var page = try res.read(upToCount: spec.pageSize) ?? Data()
            if page.count < spec.pageSize {
                page.append(Data(repeating: 0xFF, count: spec.pageSize - page.count))
            }
            pending.append(page)
            pending.append(oob)
            if pending.count >= chunk {
                try fh.write(contentsOf: pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        try fh.write(contentsOf: pending)
        progress?(1, "Resource partition updated")
    }

    // MARK: - eMMC

    public struct GPTPartition: Sendable, Hashable {
        public var name: String
        public var offset: Int
        public var size: Int
        public var source: URL?
    }

    static let sector = 512
    static let align = 1 << 20
    static let basicData = UUID(uuidString: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7")!
    static let namespace = UUID(uuidString: "6F8A3C8E-1B70-4D2E-9A5E-0E3B7D1C1700")!

    /// Partition plan for an eMMC: every romfs image aligned to 1 MiB, then
    /// the blank partitions the firmware formats on first mount.
    public static func emmcLayout(spec: EMMCSpec, firmwareDirectory dir: URL) throws -> [GPTPartition] {
        var parts: [GPTPartition] = []
        var off = align
        for name in spec.romfs {
            let src = dir.appendingPathComponent("vela_\(name).bin")
            guard let size = try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int else {
                throw MirageError.notFound("The firmware has no vela_\(name).bin")
            }
            let n = (size + align - 1) / align * align
            parts.append(.init(name: name, offset: off, size: n, source: src))
            off += n
        }
        for b in spec.blank {
            parts.append(.init(name: b.name, offset: off, size: b.mib << 20, source: nil))
            off += b.mib << 20
        }
        let nsect = (spec.sizeGiB << 30) / sector
        guard off <= (nsect - 34) * sector else {
            throw MirageError.invalid("The partitions need \(off >> 20) MiB, more than the \(spec.sizeGiB) GiB eMMC")
        }
        return parts
    }

    /// GPT eMMC image (sparse), romfs partitions filled from the firmware.
    public static func buildEMMC(at url: URL, spec: EMMCSpec, firmwareDirectory dir: URL, progress: Progress? = nil) throws {
        let parts = try emmcLayout(spec: spec, firmwareDirectory: dir)
        let size = spec.sizeGiB << 30
        let nsect = size / sector
        let tmp = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tmp)
        defer { try? fh.close() }
        try fh.truncate(atOffset: UInt64(size))

        var table = Data()
        for p in parts {
            table.append(gptEntry(name: p.name, first: p.offset / sector, last: (p.offset + p.size) / sector - 1))
        }
        table.append(Data(count: 128 * 128 - table.count))
        let tcrc = crc32(table)
        let disk = uuid5(namespace, "disk")

        var mbr = Data(count: sector)
        let lastLBA = UInt32(min(nsect - 1, 0xFFFF_FFFF))
        mbr.replaceSubrange(446..<462, with: [0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF] + le32(1) + le32(lastLBA))
        mbr[510] = 0x55
        mbr[511] = 0xAA
        try fh.seek(toOffset: 0)
        try fh.write(contentsOf: mbr)
        try fh.write(contentsOf: gptHeader(my: 1, alt: nsect - 1, first: 34, last: nsect - 34, entries: 2, crc: tcrc, disk: disk))
        try fh.write(contentsOf: table)
        try fh.seek(toOffset: UInt64((nsect - 33) * sector))
        try fh.write(contentsOf: table)
        try fh.write(contentsOf: gptHeader(my: nsect - 1, alt: 1, first: 34, last: nsect - 34, entries: nsect - 33, crc: tcrc, disk: disk))

        try writePartitions(parts, into: fh, progress: progress)
        try fh.close()
        try replace(url, with: tmp)
        progress?(1, "eMMC ready")
    }

    /// Rewrites the romfs partitions of an existing eMMC image from another
    /// firmware when they fit the existing layout (user data survives);
    /// returns false when the layout changed and a rebuild is needed.
    public static func updateEMMC(at url: URL, spec: EMMCSpec, firmwareDirectory dir: URL, progress: Progress? = nil) throws -> Bool {
        let current = try readGPT(url)
        let wanted = try emmcLayout(spec: spec, firmwareDirectory: dir)
        var plan: [GPTPartition] = []
        for p in wanted where p.source != nil {
            guard let have = current.first(where: { $0.name == p.name }), have.size >= p.size else { return false }
            plan.append(.init(name: p.name, offset: have.offset, size: have.size, source: p.source))
        }
        let fh = try FileHandle(forUpdating: url)
        defer { try? fh.close() }
        try writePartitions(plan, into: fh, progress: progress, zeroTail: true)
        progress?(1, "Firmware partitions updated")
        return true
    }

    static func writePartitions(_ parts: [GPTPartition], into fh: FileHandle, progress: Progress?, zeroTail: Bool = false) throws {
        let total = parts.compactMap { p in p.source.map { _ in p.size } }.reduce(0, +)
        var done = 0
        for p in parts {
            guard let src = p.source else { continue }
            let s = try FileHandle(forReadingFrom: src)
            defer { try? s.close() }
            try fh.seek(toOffset: UInt64(p.offset))
            var written = 0
            while let buf = try s.read(upToCount: chunk), !buf.isEmpty {
                try Task.checkCancellation()
                try fh.write(contentsOf: buf)
                written += buf.count
                progress?(Double(done + written) / Double(max(total, 1)), "Writing \(p.name)")
            }
            if zeroTail && written < p.size {
                let zeros = Data(count: min(chunk, p.size - written))
                var left = p.size - written
                while left > 0 {
                    let n = min(left, zeros.count)
                    try fh.write(contentsOf: zeros.prefix(n))
                    left -= n
                }
            }
            done += p.size
        }
    }

    /// The partitions in an eMMC image's primary GPT.
    public static func readGPT(_ url: URL) throws -> [GPTPartition] {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: UInt64(sector))
        guard let hdr = try fh.read(upToCount: 92), hdr.count == 92, hdr.prefix(8) == Data("EFI PART".utf8) else {
            throw MirageError.io("\(url.lastPathComponent) has no GPT")
        }
        let lba = hdr.u64(72), count = Int(hdr.u32(80)), esize = Int(hdr.u32(84))
        try fh.seek(toOffset: lba * UInt64(sector))
        guard let raw = try fh.read(upToCount: count * esize) else { return [] }
        var parts: [GPTPartition] = []
        for i in 0..<count {
            let e = raw.subdata(in: (i * esize)..<min(raw.count, (i + 1) * esize))
            guard e.count >= 128 else { break }
            let first = e.u64(32), last = e.u64(40)
            guard first != 0 else { continue }
            let nameData = e.subdata(in: 56..<128)
            let name = String(data: nameData, encoding: .utf16LittleEndian)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? "?"
            parts.append(.init(name: name, offset: Int(first) * sector, size: Int(last - first + 1) * sector, source: nil))
        }
        return parts
    }

    static func gptEntry(name: String, first: Int, last: Int) -> Data {
        var e = Data()
        e.append(guidLE(basicData))
        e.append(guidLE(uuid5(namespace, name)))
        e.append(le64(UInt64(first)))
        e.append(le64(UInt64(last)))
        e.append(le64(0))
        var n = Data(name.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        n.append(Data(count: 72 - n.count))
        e.append(n)
        return e
    }

    static func gptHeader(my: Int, alt: Int, first: Int, last: Int, entries: Int, crc: UInt32, disk: UUID) -> Data {
        var h = Data("EFI PART".utf8)
        h.append(le32(0x0001_0000))
        h.append(le32(92))
        h.append(le32(0))
        h.append(le32(0))
        h.append(le64(UInt64(my)))
        h.append(le64(UInt64(alt)))
        h.append(le64(UInt64(first)))
        h.append(le64(UInt64(last)))
        h.append(guidLE(disk))
        h.append(le64(UInt64(entries)))
        h.append(le32(128))
        h.append(le32(128))
        h.append(le32(crc))
        let hcrc = crc32(h)
        h.replaceSubrange(16..<20, with: le32(hcrc))
        h.append(Data(count: sector - h.count))
        return h
    }

    /// RFC 4122 name-based UUID (SHA-1), as Python's uuid.uuid5.
    static func uuid5(_ ns: UUID, _ name: String) -> UUID {
        var input = Data(withUnsafeBytes(of: ns.uuid) { Array($0) })
        input.append(Data(name.utf8))
        var b = Array(Insecure.SHA1.hash(data: input).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Mixed-endian GUID bytes (Python's UUID.bytes_le).
    static func guidLE(_ u: UUID) -> Data {
        let b = withUnsafeBytes(of: u.uuid) { Array($0) }
        return Data([b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6]] + b[8...])
    }

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    static func replace(_ url: URL, with tmp: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}

extension Data {
    func u32(_ off: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self).littleEndian }
    }

    func u64(_ off: Int) -> UInt64 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt64.self).littleEndian }
    }

    func u16(_ off: Int) -> UInt16 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt16.self).littleEndian }
    }
}

// MARK: - Raw factory record (Band 9, Band 10)

/// The factory record the Band 9 and Band 10 firmware reads from
/// /dev/factory instead of a littlefs. Offsets are the ones its
/// CheckInfoContent and loadfactoryinfo_main functions use on the record
/// (the firmware reads 1292 bytes): magic at 0, a CRC at 4, then
/// fixed-width fields. The CRC covers bytes 12 ..< 1291 and is a reflected
/// CRC-32 with initial value 0 and no final XOR (found by matching the
/// value the firmware logs, crc32=0x5ad2ce5f, for a record it rejected).
/// Fields Mirage does not know are left empty. Binding keys have no field
/// here, so they cannot be stored.
enum RawInfo {
    static let size = 1292
    static let magic: UInt16 = 0x9A55
    static let crcOffset = 4
    static let bodyOffset = 12
    static let bodyEnd = 1291
    static let mac = (offset: 0x8A, length: 6)
    static let did = (offset: 0x92, length: 9)
    static let psn = (offset: 0x14F, length: 24)

    static func partition(_ part: FactoryPartition, properties: [FactoryIdentity.Property]) throws -> Data {
        func value(_ key: String) -> String? { properties.first { $0.key == key }?.value }
        guard let did = value("ro.factory.did"), !did.isEmpty, did.allSatisfy(\.isNumber),
              did.utf8.count <= RawInfo.did.length else {
            throw MirageError.invalid("The raw factory record holds a device ID of at most \(RawInfo.did.length) decimal digits")
        }
        guard let psn = value("ro.factory.psn"), (1...RawInfo.psn.length).contains(psn.utf8.count) else {
            throw MirageError.invalid("The raw factory record holds a serial of 1–\(RawInfo.psn.length) characters")
        }
        guard let mac = value("ro.factory.mac_bt"), FactoryIdentity.isValidAddress(mac) else {
            throw MirageError.invalid("The raw factory record needs a Bluetooth address (XX:XX:XX:XX:XX:XX)")
        }
        var record = Data(repeating: 0xFF, count: max(size, part.size))
        func put(_ bytes: [UInt8], at field: (offset: Int, length: Int)) {
            let padded = bytes + [UInt8](repeating: 0, count: field.length - bytes.count)
            record.replaceSubrange(field.offset..<(field.offset + field.length), with: padded)
        }
        put(Array(mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }), at: RawInfo.mac)
        put(Array(did.utf8), at: RawInfo.did)
        put(Array(psn.utf8), at: RawInfo.psn)
        record.replaceSubrange(0..<2, with: withUnsafeBytes(of: magic.littleEndian) { Data($0) })
        let crc = crcZeroInit(record.subdata(in: bodyOffset..<bodyEnd))
        record.replaceSubrange(crcOffset..<(crcOffset + 4), with: ImageBuilder.le32(crc))
        return record
    }

    /// Reflected CRC-32 polynomial 0xEDB88320, initial value 0, no final XOR.
    static func crcZeroInit(_ data: Data) -> UInt32 {
        var c: UInt32 = 0
        for byte in data {
            c ^= UInt32(byte)
            for _ in 0..<8 {
                c = c & 1 != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1
            }
        }
        return c
    }

    static func properties(in region: Data) throws -> [FactoryIdentity.Property] {
        let magicValue = UInt16(region[0]) | UInt16(region[1]) << 8
        guard magicValue == magic else {
            throw MirageError.io("No factory record in the partition")
        }
        func text(_ field: (offset: Int, length: Int)) -> String {
            let bytes = region.subdata(in: field.offset..<(field.offset + field.length)).prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        let macBytes = region.subdata(in: mac.offset..<(mac.offset + mac.length))
        let macText = macBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
        return [
            .init(key: "ro.factory.did", value: text(did)),
            .init(key: "ro.factory.psn", value: text(psn)),
            .init(key: "ro.factory.mac_bt", value: macText),
        ]
    }
}

// MARK: - yaffs2 /system (Band 9, Band 10)

/// The yaffs2 tree the Band 9 and Band 10 firmware mounts as /system
/// (`mount -t yaffs -o ro /dev/nand_system /system`). Each package
/// resource file becomes one file at the root, in ota.json order. Written
/// the way the firmware writes it: 2048-byte chunks with inband tags
/// (the last 16 bytes: seq, obj id, chunk id, bytes), 64 chunks per block.
/// The yaffs2 tree the Band 9, Band 10 and Band 9 Pro firmware mounts as /system
/// (`mount -t yaffs -o ro /dev/nand_system /system`). Files and directories are
/// written the way the firmware writes them: 2048-byte chunks with inband tags
/// (the last 16 bytes: seq, obj id, chunk id, bytes), 64 chunks per block.
enum Yaffs2 {
    struct File {
        var name: String
        var url: URL
        var size: Int
        var isDirectory: Bool = false
        var oid: UInt32 = 0
        var parent: UInt32 = 1

        init(name: String, url: URL, size: Int, isDirectory: Bool = false, oid: UInt32 = 0, parent: UInt32 = 1) {
            self.name = name
            self.url = url
            self.size = size
            self.isDirectory = isDirectory
            self.oid = oid
            self.parent = parent
        }
    }

    static let chunkData = 2048 - 16
    static let firstSeq: UInt32 = 0x1001
    static let firstObj: UInt32 = 257
    static let root: UInt32 = 1
    static let typeFile: UInt32 = 1
    static let typeDir: UInt32 = 3
    static let extraHeader: UInt32 = 0x8000_0000
    static let typeShift: UInt32 = 28
    static let fileMode: UInt32 = 0o644
    static let dirMode: UInt32 = 0o755
    static let time: UInt32 = 946_684_800       // 2000-01-01, the files' times
    static let chunksPerBlock = 64

    /// Files and directories for /system. If a "system" directory exists in the
    /// package (e.g. Band 9 Pro), it is traversed recursively. Otherwise, the
    /// package's main_res files are gathered from ota.json.
    static func systemFiles(in dir: URL) throws -> [File] {
        let sysDir = dir.appendingPathComponent("system")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sysDir.path, isDirectory: &isDir), isDir.boolValue {
            return try walkTree(rootURL: sysDir)
        }
        let manifest = dir.appendingPathComponent("ota.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            let data = try Data(contentsOf: manifest)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sections = json["sections"] as? [[String: Any]] else {
                throw MirageError.invalid("\(manifest.lastPathComponent) lists no sections")
            }
            var files: [File] = []
            for sec in sections where sec["section_type"] as? String == "main_res" {
                guard let name = sec["location_path"] as? String else { continue }
                let url = dir.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                files.append(File(name: name, url: url, size: size))
            }
            return files
        }
        // Fallback: flat non-firmware files in dir
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey])) ?? []
        return contents.compactMap { url in
            let name = url.lastPathComponent
            guard !name.hasPrefix("vela_") && !name.hasPrefix(".") && !name.hasSuffix(".json") else { return nil }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return File(name: name, url: url, size: size)
        }
    }

    private static func walkTree(rootURL: URL) throws -> [File] {
        var files: [File] = []
        var nextOID: UInt32 = firstObj
        var dirOIDs: [URL: UInt32] = [rootURL: root]

        func walk(dir: URL, parentOID: UInt32) throws {
            let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for item in items {
                let name = item.lastPathComponent
                guard !name.hasPrefix(".") else { continue }
                let vals = try item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if vals.isDirectory == true {
                    let oid = nextOID
                    nextOID += 1
                    dirOIDs[item] = oid
                    files.append(File(name: name, url: item, size: 0, isDirectory: true, oid: oid, parent: parentOID))
                    try walk(dir: item, parentOID: oid)
                } else {
                    let oid = nextOID
                    nextOID += 1
                    let sz = vals.fileSize ?? 0
                    files.append(File(name: name, url: item, size: sz, isDirectory: false, oid: oid, parent: parentOID))
                }
            }
        }
        try walk(dir: rootURL, parentOID: root)
        return files
    }

    /// Pages the tree occupies: one header chunk plus data chunks per file.
    static func pageCount(_ files: [File]) throws -> Int {
        files.reduce(0) { total, file in
            total + 1 + (file.isDirectory ? 0 : (file.size + chunkData - 1) / chunkData)
        }
    }

    /// Calls `emit` with each 2048-byte page (chunk data, then its tags).
    static func forEachPage(_ files: [File], _ emit: (Data) throws -> Void) throws {
        var index = 0
        func page(oid: UInt32, cid: UInt32, nbytes: UInt32, data: Data) throws {
            var out = data
            out.append(Data(repeating: 0xFF, count: chunkData - data.count))
            let seq = firstSeq + UInt32(index / chunksPerBlock)
            out.append(contentsOf: [seq, oid, cid, nbytes].flatMap { le32($0) })
            try emit(out)
            index += 1
        }
        for (i, file) in files.enumerated() {
            let oid = file.oid != 0 ? file.oid : (firstObj + UInt32(i))
            let parent = file.parent
            if file.isDirectory {
                let hdr = header(type: typeDir, parent: parent, name: file.name, size: 0xFFFF_FFFF, mode: dirMode)
                try page(oid: oid | (typeDir << typeShift), cid: extraHeader | parent,
                         nbytes: 0, data: hdr)
            } else {
                let hdr = header(type: typeFile, parent: parent, name: file.name, size: file.size, mode: fileMode)
                try page(oid: oid | (typeFile << typeShift), cid: extraHeader | parent,
                         nbytes: UInt32(truncatingIfNeeded: file.size), data: hdr)
                let handle = try FileHandle(forReadingFrom: file.url)
                defer { try? handle.close() }
                var cid: UInt32 = 1
                while let data = try handle.read(upToCount: chunkData), !data.isEmpty {
                    try page(oid: oid, cid: cid, nbytes: UInt32(data.count), data: data)
                    cid += 1
                }
            }
        }
    }

    /// The header chunk: type, parent, name, mode and times, size, and
    /// the fields the firmware expects; unused bytes are 0xFF.
    static func header(type: UInt32, parent: UInt32, name: String, size: Int, mode: UInt32) -> Data {
        var h = Data(repeating: 0xFF, count: chunkData)
        func put32(_ v: UInt32, at off: Int) { h.replaceSubrange(off..<(off + 4), with: le32(v)) }
        put32(type, at: 0)
        put32(parent, at: 4)
        let raw = Array(name.utf8.prefix(255))
        h.replaceSubrange(10..<266, with: raw + [UInt8](repeating: 0, count: 256 - raw.count))
        for (i, v) in [mode, 0, 0, time, time, time].enumerated() { put32(v, at: 268 + 4 * i) }
        put32(UInt32(truncatingIfNeeded: size), at: 292)
        put32(0xFFFF_FFFF, at: 296)
        for (i, v) in [0, time, 0, time, 0, time, 0].enumerated() { put32(UInt32(v), at: 460 + 4 * i) }
        put32(0, at: 488)
        put32(type == typeDir ? 0 : UInt32(truncatingIfNeeded: size >> 32), at: 496)
        put32(0, at: 504)
        put32(0, at: 508)
        return h
    }

    static func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
}
