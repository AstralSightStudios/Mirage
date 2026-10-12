import Foundation

/// Minimal PNG encoder for screenshots on hosts without ImageIO: 8-bit RGB,
/// no filtering, stored (uncompressed) deflate blocks.
enum PNGWriter {
    static func png(_ frame: VNCClient.Frame) -> Data? {
        let w = frame.width, h = frame.height
        guard w > 0, h > 0, frame.pixels.count >= w * h * 4 else { return nil }
        var raw = [UInt8]()
        raw.reserveCapacity(h * (w * 3 + 1))
        frame.pixels.withUnsafeBytes { (px: UnsafeRawBufferPointer) in
            for y in 0..<h {
                raw.append(0)
                var i = y * w * 4
                for _ in 0..<w {
                    // B,G,R,X in memory
                    raw.append(px[i + 2])
                    raw.append(px[i + 1])
                    raw.append(px[i])
                    i += 4
                }
            }
        }
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.appendBE(UInt32(w))
        ihdr.appendBE(UInt32(h))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0])
        chunk("IHDR", ihdr, into: &out)
        chunk("IDAT", zlibStored(raw), into: &out)
        chunk("IEND", Data(), into: &out)
        return out
    }

    private static func chunk(_ type: String, _ body: Data, into out: inout Data) {
        out.appendBE(UInt32(body.count))
        var typed = Data(type.utf8)
        typed.append(body)
        out.append(typed)
        out.appendBE(crc32(typed))
    }

    private static func zlibStored(_ bytes: [UInt8]) -> Data {
        var out = Data([0x78, 0x01])
        var off = 0
        repeat {
            let n = min(65535, bytes.count - off)
            let last: UInt8 = off + n == bytes.count ? 1 : 0
            out.append(last)
            out.append(UInt8(n & 0xFF))
            out.append(UInt8(n >> 8))
            out.append(UInt8(~n & 0xFF))
            out.append(UInt8((~n >> 8) & 0xFF))
            out.append(contentsOf: bytes[off..<off + n])
            off += n
        } while off < bytes.count
        var a: UInt32 = 1, b: UInt32 = 0
        for chunk in stride(from: 0, to: bytes.count, by: 5552) {
            for i in chunk..<min(chunk + 5552, bytes.count) {
                a += UInt32(bytes[i])
                b += a
            }
            a %= 65521
            b %= 65521
        }
        out.appendBE(b << 16 | a)
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendBE(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
}
