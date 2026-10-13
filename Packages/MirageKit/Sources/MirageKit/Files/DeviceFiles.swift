import Foundation

/// A file system of a shut-down device: a partition of one of its storage
/// images.
public struct DeviceVolume: Identifiable, Hashable, Sendable {
    public enum Format: String, Sendable {
        case exfat = "exFAT", yaffs2 = "yaffs2", romfs = "romfs"
    }

    public var id: String { name }
    /// Partition name.
    public var name: String
    /// Where the firmware mounts it.
    public var mountPoint: String?
    public var format: Format
    public var size: Int64
    public var writable: Bool
    /// A romfs partition whose image can be swapped for another.
    public var replaceable: Bool

    var image: URL
    var offset: UInt64
    var nandPages: Range<Int>?

    public var title: String { mountPoint ?? name }
}

public enum DeviceFiles {
    /// Directories whose entries cannot be stat'ed on a running device:
    /// rpmsgfs mounts of cores the emulator does not run (Watch S5's audio
    /// DSP at /mnt/audio) never answer.
    public static func unstatableDirectories(profile: DeviceProfile) -> Set<String> {
        (profile.storage.emmc != nil || profile.chip == "best1502p") ? ["/mnt"] : []
    }

    public static func volumes(of device: VirtualDevice, profile: DeviceProfile, library: MirageLibrary) -> [DeviceVolume] {
        let paths = library.paths(for: device)
        var out: [DeviceVolume] = []
        if let emmc = profile.storage.emmc, let parts = try? ImageBuilder.readGPT(paths.emmc) {
            let mounts = ["data": "/data", "nv": "/nv", "userlog": "/log", "app": "/resource/app",
                          "health": "/resource/health", "misc": "/resource/misc", "system": "/resource/system",
                          "vendor": "/vendor", "font": "/font", "i18n": "/i18n", "quickapp": "/quickapp",
                          "watchface": "/watchface", "cp_image": "/cp_image", "audio_image": "/audio_image"]
            for p in parts {
                let isBlank = emmc.blank.contains { $0.name == p.name }
                let format: DeviceVolume.Format
                if isBlank {
                    guard ExFATVolume.isExFAT(url: paths.emmc, offset: UInt64(p.offset)) else { continue }
                    format = .exfat
                } else {
                    guard isRomFS(url: paths.emmc, offset: UInt64(p.offset)) else { continue }
                    format = .romfs
                }
                out.append(DeviceVolume(name: p.name, mountPoint: mounts[p.name], format: format, size: Int64(p.size),
                                        writable: isBlank, replaceable: !isBlank,
                                        image: paths.emmc, offset: UInt64(p.offset)))
            }
        }
        if let nand = profile.storage.nand, FileManager.default.fileExists(atPath: paths.nand.path) {
            let pageBytes = Int64(nand.pageSize)
            if let system = nand.systemPages {
                out.append(DeviceVolume(name: "nand_system", mountPoint: "/system", format: .yaffs2,
                                        size: Int64(system) * pageBytes, writable: true, replaceable: false,
                                        image: paths.nand, offset: 0, nandPages: 0..<system))
            } else if nand.resourcePages > 0 {
                let offset = UInt64(nand.resourceFirstPage * (nand.pageSize + nand.oobSize))
                out.append(DeviceVolume(name: "resource", mountPoint: "/resource", format: .romfs,
                                        size: Int64(nand.resourcePages) * pageBytes, writable: false, replaceable: true,
                                        image: paths.nand, offset: offset,
                                        nandPages: nand.resourceFirstPage..<(nand.resourceFirstPage + nand.resourcePages)))
            }
            let first = nand.dataFirstPage
            out.append(DeviceVolume(name: "nand_data", mountPoint: "/data", format: .yaffs2,
                                    size: Int64(nand.dataPageCount) * pageBytes, writable: true, replaceable: false,
                                    image: paths.nand, offset: 0, nandPages: first..<(first + nand.dataPageCount)))
        }
        return out.sorted { ($0.writable ? 0 : 1, $0.title) < ($1.writable ? 0 : 1, $1.title) }
    }

    static func isRomFS(url: URL, offset: UInt64) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: offset)) != nil, let d = try? fh.read(upToCount: 8) else { return false }
        return RomFSVolume.isRomFS(d)
    }

    public static func open(_ v: DeviceVolume, profile: DeviceProfile) throws -> GuestFileSystem {
        switch v.format {
        case .exfat:
            return try ExFATVolume(url: v.image, offset: v.offset, size: UInt64(v.size), writable: v.writable)
        case .yaffs2:
            guard let nand = profile.storage.nand, let pages = v.nandPages else { throw MirageError.invalid("No NAND layout") }
            return try YaffsVolume(url: v.image, layout: .init(spec: nand, firstPage: pages.lowerBound, pages: pages.count),
                                   writable: v.writable)
        case .romfs:
            if let pages = v.nandPages, let nand = profile.storage.nand {
                return try RomFSVolume(data: readNAND(v.image, spec: nand, pages: pages))
            }
            return try RomFSVolume(url: v.image, offset: v.offset, size: UInt64(v.size))
        }
    }

    /// The data bytes of a page range (the image interleaves OOB areas).
    static func readNAND(_ url: URL, spec: NANDSpec, pages: Range<Int>) throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let stride = spec.pageSize + spec.oobSize
        try fh.seek(toOffset: UInt64(pages.lowerBound * stride))
        var out = Data(capacity: pages.count * spec.pageSize)
        var remaining = pages.count
        var romfsSize: Int?
        while remaining > 0 {
            let n = min(remaining, 4096)
            guard let d = try fh.read(upToCount: n * stride) else { break }
            for p in 0..<(d.count / stride) {
                out.append(d.subdata(in: (p * stride)..<(p * stride + spec.pageSize)))
            }
            remaining -= n
            if romfsSize == nil, out.count >= 16, RomFSVolume.isRomFS(out) { romfsSize = Int(out.be32(8)) }
            if let romfsSize, out.count >= romfsSize { return out.prefix(romfsSize) }
        }
        return out
    }

    /// Writes a romfs image over a romfs partition.
    public static func replaceImage(_ v: DeviceVolume, with source: URL, profile: DeviceProfile) throws {
        guard v.replaceable else { throw MirageError.invalid("\(v.title) cannot be replaced") }
        let data = try Data(contentsOf: source, options: .alwaysMapped)
        guard RomFSVolume.isRomFS(data) else { throw MirageError.invalid("\(source.lastPathComponent) is not a romfs image") }
        guard Int64(data.count) <= v.size else {
            throw MirageError.invalid("\(source.lastPathComponent) (\(data.count) bytes) does not fit \(v.title) (\(v.size) bytes)")
        }
        let fh = try FileHandle(forUpdating: v.image)
        defer { try? fh.close() }
        if let pages = v.nandPages, let nand = profile.storage.nand {
            let stride = nand.pageSize + nand.oobSize
            var page = pages.lowerBound
            var offset = 0
            var batch = Data()
            while offset < data.count {
                var p = Data(repeating: 0xFF, count: stride)
                let end = min(data.count, offset + nand.pageSize)
                p.replaceSubrange(0..<(end - offset), with: data.subdata(in: offset..<end))
                batch.append(p)
                offset = end
                page += 1
                if batch.count >= 1 << 22 || offset >= data.count {
                    try fh.seek(toOffset: UInt64((page - batch.count / stride) * stride))
                    try fh.write(contentsOf: batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
        } else {
            try fh.seek(toOffset: v.offset)
            try fh.write(contentsOf: data)
        }
        try fh.synchronize()
    }
}
