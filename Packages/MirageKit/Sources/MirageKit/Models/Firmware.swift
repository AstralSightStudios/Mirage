import Foundation

/// An unpacked official full OTA package (ota.sh, META-INF, vela_*.bin) in
/// the firmware library.
public struct Firmware: Codable, Identifiable, Hashable, Sendable {
    /// Package base name, e.g. `miwear.watch.q63_v4.101.020_full_4eabac72`.
    public var id: String
    /// Product, e.g. `miwear.watch.q63`.
    public var product: String
    public var version: String
    public var chip: String?
    public var buildDate: String?
    public var customerVersion: String?
    public var importedAt: Date
    public var source: Source
    /// vela_*.bin images in the package, name → bytes.
    public var images: [String: Int64]
    public var releaseNotes: String?

    public enum Source: Codable, Hashable, Sendable {
        case imported(path: String)
        case archive(tag: String, asset: String)
    }

    public var model: String { ProductCatalog.model(of: product) }
    public var marketingName: String { ProductCatalog.name(of: product) }
    public var totalSize: Int64 { images.values.reduce(0, +) }

    public var sourceTitle: String {
        switch source {
        case .imported(let path): return "Imported from \(URL(fileURLWithPath: path).lastPathComponent)"
        case .archive(let tag, _): return "MiWear Firmware Archives (\(tag))"
        }
    }
}

/// Product codes and marketing names (from the archive's release notes,
/// which greet the user with the product name).
public enum ProductCatalog {
    public static let names: [String: String] = [
        "miwear.watch.m66": "Xiaomi Smart Band 8",
        "miwear.watch.m66dsn": "Xiaomi Smart Band 8",
        "miwear.watch.m66nfc": "Xiaomi Smart Band 8 NFC",
        "miwear.watch.n66cn": "Xiaomi Smart Band 9",
        "miwear.watch.n66gl": "Xiaomi Smart Band 9 (Global)",
        "miwear.watch.n66nfc": "Xiaomi Smart Band 9 NFC",
        "miwear.watch.n66tc": "Xiaomi Smart Band 9 Ceramic",
        "miwear.watch.n67cn": "Xiaomi Smart Band 9 Pro",
        "miwear.watch.n69cn": "Redmi Band 3",
        "miwear.watch.o63": "Xiaomi Watch S4 41mm",
        "miwear.watch.o65": "REDMI Watch 5",
        "miwear.watch.o65m": "REDMI Watch 5 eSIM",
        "miwear.watch.o66cn": "Xiaomi Smart Band 10",
        "miwear.watch.o66lj": "Xiaomi Smart Band 10",
        "miwear.watch.o66nfc": "Xiaomi Smart Band 10 NFC",
        "miwear.watch.o66tc": "Xiaomi Smart Band 10 Ceramic",
        "miwear.watch.p62": "Xiaomi Watch S5 46mm",
        "miwear.watch.p62lte": "Xiaomi Watch S5 eSIM 46mm",
        "miwear.watch.p65": "REDMI Watch 6",
        "miwear.watch.p67cn": "Xiaomi Smart Band 10 Pro",
        "miwear.watch.p67gln": "Xiaomi Smart Band 10 Pro NFC",
        "miwear.watch.p67tc": "Xiaomi Smart Band 10 Pro Ceramic",
        "miwear.watch.q63": "Xiaomi Watch S5",
        "miwear.watch.q65": "REDMI Watch 7",
        "miwear.watch.q65acn": "REDMI Watch 6 Active",
        "miwear.watch.q66cn": "Xiaomi Smart Band 11",
        "miwear.watch.q66nfc": "Xiaomi Smart Band 11 NFC",
        "miwear.watch.q66tc": "Xiaomi Smart Band 11 Ceramic",
        "miwear.watch.q66u": "Xiaomi Smart Band 11",
        "mijia.watch.n62": "Xiaomi Watch S3",
        "mijia.watch.n62car": "Xiaomi Watch S3 eSIM",
        "mijia.watch.n62cg": "Xiaomi Watch S3 eSIM",
        "mijia.watch.n62lte": "Xiaomi Watch S3 eSIM",
        "mijia.watch.n62s": "Xiaomi Watch S4 Sport",
        "mijia.watch.o62": "Xiaomi Watch S4",
        "mijia.watch.o62lte": "Xiaomi Watch S4 eSIM",
        "mijia.watch.o62m": "Xiaomi Watch S4 eSIM",
        "lchz.watch.m67": "Xiaomi Smart Band 8 Pro",
        "lchz.watch.m67ys": "Xiaomi Smart Band 8 Pro Genshin Impact Edition",
        "lchz.watch.n65": "Redmi Watch 4",
    ]

    public static func name(of product: String) -> String {
        names[product] ?? product
    }

    /// Short model code: the last component of the product.
    public static func model(of product: String) -> String {
        product.split(separator: ".").last.map(String.init) ?? product
    }

    /// Parses `<product>_v<version>_full_<hash>` (also the asset file name).
    public static func parsePackageName(_ name: String) -> (product: String, version: String, kind: String, hash: String)? {
        var base = name
        for ext in [".bin", ".zip"] where base.hasSuffix(ext) {
            base.removeLast(ext.count)
        }
        let parts = base.components(separatedBy: "_")
        guard parts.count >= 4, parts[1].hasPrefix("v") else { return nil }
        let product = parts[0]
        let version = String(parts[1].dropFirst())
        let kind = parts[2...].dropLast().joined(separator: "_")
        guard product.split(separator: ".").count == 3 else { return nil }
        return (product, version, kind, parts.last!)
    }
}

/// Facts read out of a firmware's AP image (vela_ap.bin): its boot info
/// text (CHIP=, FLASH_SIZE=, ...) and the build properties.
public struct FirmwareImageInfo: Sendable {
    public var chip: String?
    public var flashSize: Int?
    public var otaCodeOffset: Int?
    public var buildDate: String?
    public var version: String?
    public var customerVersion: String?
    public var products: [String]

    public static func read(apImage url: URL) throws -> FirmwareImageInfo {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return parse(data)
    }

    static func parse(_ data: Data) -> FirmwareImageInfo {
        func value(after key: String) -> String? {
            guard let k = key.data(using: .ascii), let r = data.range(of: k) else { return nil }
            var end = r.upperBound
            while end < data.count, end - r.upperBound < 128 {
                let b = data[end]
                if b == 0 || b == 0x0A || b == 0x0D { break }
                end += 1
            }
            return String(data: data[r.upperBound..<end], encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces)
        }
        func number(_ s: String?) -> Int? {
            guard let s else { return nil }
            if s.hasPrefix("0x") || s.hasPrefix("0X") { return Int(s.dropFirst(2), radix: 16) }
            return Int(s)
        }
        var products = Set<String>()
        for prefix in ["miwear.watch.", "mijia.watch.", "lchz.watch."] {
            let p = Data(prefix.utf8)
            var from = data.startIndex
            while let r = data.range(of: p, in: from..<data.endIndex) {
                var end = r.upperBound
                while end < data.endIndex, end - r.upperBound < 16 {
                    let b = data[end]
                    let isAlnum = (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x7A)
                    if !isAlnum { break }
                    end += 1
                }
                if end > r.upperBound, let s = String(data: data[r.lowerBound..<end], encoding: .ascii) {
                    products.insert(s)
                }
                from = r.upperBound
            }
        }
        return FirmwareImageInfo(
            chip: value(after: "CHIP="),
            flashSize: number(value(after: "FLASH_SIZE=")),
            otaCodeOffset: number(value(after: "OTA_CODE_OFFSET=")),
            buildDate: value(after: "BUILD_DATE="),
            version: value(after: "ro.build.version="),
            customerVersion: value(after: "ro.build.customer_version="),
            products: products.sorted())
    }
}
