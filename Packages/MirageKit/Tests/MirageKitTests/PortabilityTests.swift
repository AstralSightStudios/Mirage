#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif
import Foundation
import Testing
@testable import MirageKit

private func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

@Test func softHashesMatchKnownDigests() {
    var s = SoftSHA256()
    s.update(data: Data("abc".utf8))
    #expect(hex(s.finalize()) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(hex(SoftSHA1.hash(data: Data("abc".utf8))) == "a9993e364706816aba3e25717850c26c9cd0d89d")
    #expect(hex(SoftSHA1.hash(data: Data())) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
}

#if canImport(CryptoKit)
@Test func softHashesMatchCryptoKit() {
    var rng = SystemRandomNumberGenerator()
    for n in [0, 1, 55, 56, 63, 64, 65, 119, 120, 1000, 70_000] {
        let data = Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
        var soft = SoftSHA256()
        var kit = CryptoKit.SHA256()
        // uneven chunks exercise the block buffer
        var off = 0
        var step = 1
        while off < n {
            let end = min(n, off + step)
            soft.update(data: data[off..<end])
            kit.update(data: data[off..<end])
            off = end
            step = step * 3 + 1
        }
        #expect(hex(soft.finalize()) == hex(kit.finalize()), "SHA-256 of \(n) bytes")
        #expect(hex(SoftSHA1.hash(data: data)) == hex(Insecure.SHA1.hash(data: data)), "SHA-1 of \(n) bytes")
    }
}
#endif

#if canImport(ImageIO)
@Test func pngWriterRoundTrips() throws {
    let w = 300, h = 250
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            px[i] = UInt8(x & 0xFF)          // B
            px[i + 1] = UInt8(y & 0xFF)      // G
            px[i + 2] = UInt8((x ^ y) & 0xFF) // R
        }
    }
    let frame = VNCClient.Frame(width: w, height: h, pixels: Data(px), sequence: 0)
    let png = try #require(PNGWriter.png(frame))
    let src = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    #expect(img.width == w && img.height == h)
    let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let out = ctx.data!.assumingMemoryBound(to: UInt8.self)
    for (x, y) in [(0, 0), (17, 3), (299, 249), (128, 200)] {
        let i = (y * w + x) * 4
        #expect(out[i] == UInt8((x ^ y) & 0xFF) && out[i + 1] == UInt8(y & 0xFF) && out[i + 2] == UInt8(x & 0xFF))
    }
}
#endif

@Test func unixEndpointsKeepQEMUArguments() {
    let paths = DevicePaths(root: URL(fileURLWithPath: "/tmp/dev", isDirectory: true), shortID: "ABCD1234")
    let e = DeviceEndpoints.unix(paths)
    #expect(e.vnc.vncOption == "unix:\(paths.vncSocket.path)")
    #expect(e.qmp.serverOption == "unix:\(paths.qmpSocket.path),server=on,wait=off")
    #expect(e.qmpAux.serverOption == "unix:\(paths.runtime.appendingPathComponent("qmp-aux.sock").path),server=on,wait=off")
    #expect(e.console.chardevAddress == "path=\(paths.consoleSocket.path)")
    #expect(e.gdb.serverOption == "unix:\(paths.gdbSocket.path),server=on,wait=off")
}

@Test func loopbackEndpoints() throws {
    let e = try DeviceEndpoints.loopback()
    let ports = [e.qmp, e.qmpAux, e.vnc, e.console, e.gdb].map { ep -> Int in
        if case .tcp(let p) = ep { return p }
        return -1
    }
    #expect(Set(ports).count == 5 && !ports.contains(-1))
    if case .tcp(let vnc) = e.vnc {
        #expect((5900..<6000).contains(vnc))
        #expect(e.vnc.vncOption == "127.0.0.1:\(vnc - 5900)")
    }
    #expect(e.console.chardevAddress.hasPrefix("host=127.0.0.1,port="))
    let data = try JSONEncoder().encode(e)
    #expect(try JSONDecoder().decode(DeviceEndpoints.self, from: data) == e)
}

@Test func hostProcess() {
    let me = ProcessInfo.processInfo.processIdentifier
    #expect(HostProcess.isAlive(me))
    #expect(HostProcess.executablePath(me) != nil)
}
