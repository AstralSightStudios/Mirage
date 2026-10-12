import Foundation

/// One-step import of an official full OTA package: a `.zip` / `.bin`
/// archive (as published, a ZIP), or an already unpacked directory.
public struct FirmwareImporter: Sendable {
    public let library: MirageLibrary

    public init(library: MirageLibrary) {
        self.library = library
    }

    public enum Origin: Sendable {
        case local
        case archive(tag: String, asset: String, notes: String?)
    }

    /// Files of a package that are worth keeping: the vela images, the
    /// update scripts, and the package's main_res files. Band 9 and Band 10
    /// build their /system partition from main_res (ota.json names them).
    static func keptNames(in root: URL) -> Set<String> {
        var names: Set<String> = ["ota.json", "ota.sh", "META-INF"]
        let manifest = root.appendingPathComponent("ota.json")
        if let data = try? Data(contentsOf: manifest),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sections = json["sections"] as? [[String: Any]] {
            for sec in sections where sec["section_type"] as? String == "main_res" {
                if let name = sec["location_path"] as? String { names.insert(name) }
            }
        }
        if let all = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for name in all where name.hasPrefix("vela_") && name.hasSuffix(".bin") { names.insert(name) }
        }
        return names
    }

    @discardableResult
    public func importPackage(at source: URL, origin: Origin = .local, replace: Bool = false,
                              progress: ImageBuilder.Progress? = nil) async throws -> Firmware {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw MirageError.notFound("\(source.path) does not exist")
        }
        let staging = library.firmwaresDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let packageRoot: URL
        if isDir.boolValue {
            let root = try Self.findPackageRoot(in: source)
            progress?(0, "Copying firmware images")
            let kept = Self.keptNames(in: root)
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { kept.contains($0) }
            for (i, name) in names.enumerated() {
                try Task.checkCancellation()
                // APFS clones the files when source and library share a volume
                try FileManager.default.copyItem(at: root.appendingPathComponent(name), to: staging.appendingPathComponent(name))
                progress?(Double(i + 1) / Double(names.count), "Copying \(name)")
            }
            packageRoot = staging
        } else {
            try await Self.unzip(source, into: staging, progress: progress)
            packageRoot = try Self.findPackageRoot(in: staging)
        }

        let ap = packageRoot.appendingPathComponent("vela_ap.bin")
        let info = try FirmwareImageInfo.read(apImage: ap)
        let base = isDir.boolValue ? try Self.findPackageRoot(in: source).lastPathComponent
                                   : source.deletingPathExtension().lastPathComponent
        let parsed = ProductCatalog.parsePackageName(base)
        guard let product = parsed?.product ?? (info.products.count == 1 ? info.products.first : nil) else {
            throw MirageError.invalid("Cannot tell which product this firmware is for (name the package <product>_v<version>_full_<hash>)")
        }
        let version = info.version ?? parsed?.version ?? "unknown"
        let id = parsed != nil ? base : "\(product)_v\(version)_full_imported"

        let dest = library.firmwareDirectory(id)
        if FileManager.default.fileExists(atPath: dest.path) {
            guard replace else { throw MirageError.invalid("\(id) is already in the library") }
            try FileManager.default.removeItem(at: dest)
        }
        var images: [String: Int64] = [:]
        let kept = Self.keptNames(in: packageRoot)
        for name in try FileManager.default.contentsOfDirectory(atPath: packageRoot.path) {
            guard kept.contains(name) else {
                try? FileManager.default.removeItem(at: packageRoot.appendingPathComponent(name))
                continue
            }
            if name.hasSuffix(".bin"),
               let size = try FileManager.default.attributesOfItem(atPath: packageRoot.appendingPathComponent(name).path)[.size] as? Int64 {
                images[name] = size
            }
        }
        try FileManager.default.moveItem(at: packageRoot, to: dest)

        let fwSource: Firmware.Source
        var notes: String?
        switch origin {
        case .local:
            fwSource = .imported(path: source.path)
        case .archive(let tag, let asset, let n):
            fwSource = .archive(tag: tag, asset: asset)
            notes = n
        }
        let fw = Firmware(id: id, product: product, version: version, chip: info.chip,
                          buildDate: info.buildDate, customerVersion: info.customerVersion,
                          importedAt: Date(), source: fwSource, images: images, releaseNotes: notes)
        try library.saveFirmware(fw)
        progress?(1, "Imported \(id)")
        return fw
    }

    /// The directory holding vela_ap.bin: `dir` itself or a single child.
    static func findPackageRoot(in dir: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("vela_ap.bin").path) { return dir }
        let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let hits = children.filter { fm.fileExists(atPath: $0.appendingPathComponent("vela_ap.bin").path) }
        guard hits.count == 1 else {
            throw MirageError.invalid("No firmware package here (expected vela_ap.bin)")
        }
        return hits[0]
    }

    /// Unpacks with unzip (ditto rejects the archive's streamed entries;
    /// Windows has bsdtar instead); progress from the unpacked bytes against
    /// the sizes in the archive's central directory.
    static func unzip(_ archive: URL, into dir: URL, progress: ImageBuilder.Progress?) async throws {
        let total = (try? ZipDirectory.uncompressedSize(of: archive)) ?? 0
        guard total > 0 else {
            throw MirageError.invalid("\(archive.lastPathComponent) is not a ZIP firmware package")
        }
        let p = Process()
        #if os(Windows)
        let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        p.executableURL = URL(fileURLWithPath: system).appendingPathComponent("System32/tar.exe")
        p.arguments = ["-x", "-f", archive.path, "-C", dir.path]
        #else
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-q", "-o", archive.path, "-d", dir.path]
        #endif
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        progress?(0, "Unpacking \(archive.lastPathComponent)")
        while p.isRunning {
            if Task.isCancelled {
                p.terminate()
                throw CancellationError()
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let done = Self.directorySize(dir)
            progress?(min(0.99, Double(done) / Double(total)), "Unpacking \(archive.lastPathComponent)")
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw MirageError.process("unzip failed: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static func directorySize(_ dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var n: Int64 = 0
        for case let url as URL in e {
            n += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return n
    }
}

/// Just enough of the ZIP format to sum an archive's uncompressed sizes.
enum ZipDirectory {
    static func uncompressedSize(of url: URL) throws -> Int64 {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let size = try fh.seekToEnd()
        let tailLen = min(size, 65_557)
        try fh.seek(toOffset: size - tailLen)
        guard let tail = try fh.read(upToCount: Int(tailLen)) else { return 0 }
        guard let eocd = lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: tail) else { return 0 }
        var cdOffset = UInt64(tail.u32(eocd + 16))
        var cdSize = UInt64(tail.u32(eocd + 12))
        if cdOffset == 0xFFFF_FFFF || cdSize == 0xFFFF_FFFF,
           let loc = lastIndex(of: [0x50, 0x4B, 0x06, 0x07], in: tail) {
            let z64 = tail.u64(loc + 8)
            try fh.seek(toOffset: z64)
            if let rec = try fh.read(upToCount: 56), rec.count == 56 {
                cdSize = rec.u64(40)
                cdOffset = rec.u64(48)
            }
        }
        try fh.seek(toOffset: cdOffset)
        guard let cd = try fh.read(upToCount: Int(cdSize)) else { return 0 }
        var off = 0
        var total: Int64 = 0
        while off + 46 <= cd.count, cd.u32(off) == 0x0201_4B50 {
            var usize = UInt64(cd.u32(off + 24))
            let nameLen = Int(cd.u16(off + 28)), extraLen = Int(cd.u16(off + 30)), commentLen = Int(cd.u16(off + 32))
            if usize == 0xFFFF_FFFF {
                var e = off + 46 + nameLen
                let end = e + extraLen
                while e + 4 <= end {
                    let id = cd.u16(e), len = Int(cd.u16(e + 2))
                    if id == 1, len >= 8 { usize = cd.u64(e + 4) }
                    e += 4 + len
                }
            }
            total += Int64(usize)
            off += 46 + nameLen + extraLen + commentLen
        }
        return total
    }

    static func lastIndex(of sig: [UInt8], in data: Data) -> Int? {
        guard data.count >= sig.count else { return nil }
        var i = data.count - sig.count
        while i >= 0 {
            if data[i] == sig[0] && data[i + 1] == sig[1] && data[i + 2] == sig[2] && data[i + 3] == sig[3] {
                return i
            }
            i -= 1
        }
        return nil
    }
}
