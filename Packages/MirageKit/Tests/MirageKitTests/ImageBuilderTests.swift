import Foundation
import Testing
@testable import MirageKit

@Test func uuid5MatchesPython() {
    // python3 -c 'import uuid; print(uuid.uuid5(uuid.UUID("6f8a3c8e-1b70-4d2e-9a5e-0e3b7d1c1700"), "disk"))'
    let u = ImageBuilder.uuid5(ImageBuilder.namespace, "disk")
    #expect(u.uuidString.lowercased() == "ec6363be-2e8c-5e11-a4ad-d493cb9980d5")
}

@Test func crc32() {
    #expect(ImageBuilder.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
}

@Test func packageNames() {
    let p = ProductCatalog.parsePackageName("miwear.watch.q63_v4.101.020_full_4eabac72.bin")
    #expect(p?.product == "miwear.watch.q63")
    #expect(p?.version == "4.101.020")
    #expect(p?.kind == "full")
    let i = ProductCatalog.parsePackageName("miwear.watch.p67tc_v3.101.043_from_v3.100.170_incremental_42ee0350.bin")
    #expect(i?.kind == "from_v3.100.170_incremental")
}

@Test func nshOutput() {
    let text = "ps\r\n  PID GROUP\r\n    0     0 Idle\r\nap> \u{1B}[K"
    #expect(NSHOutput.isComplete(text, command: "ps"))
    #expect(NSHOutput.body(text, command: "ps") == "  PID GROUP\n    0     0 Idle")
}

@Test func factoryRoundTrip() throws {
    let part = DeviceProfile.p67.storage.factory
    let props: [FactoryIdentity.Property] = [.init(key: "ro.factory.did", value: "1"), .init(key: "a.b", value: "c")]
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-test-nor.img")
    try ImageBuilder.createErasedNOR(at: url, size: 0x100_0000)
    defer { try? FileManager.default.removeItem(at: url) }
    try ImageBuilder.writeFactory(into: url, part: part, properties: props)
    #expect(try ImageBuilder.readFactory(from: url, part: part) == props)
}

@Test func yaffs2DirectoryTree() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-yaffs-\(UUID().uuidString)")
    let sys = tmp.appendingPathComponent("system")
    let fontDir = sys.appendingPathComponent("font")
    try FileManager.default.createDirectory(at: fontDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let fileData = Data("sample-font-data-for-testing".utf8)
    try fileData.write(to: fontDir.appendingPathComponent("test.ttf"))

    let files = try Yaffs2.systemFiles(in: tmp)
    #expect(files.count == 2) // font dir + test.ttf file
    #expect(files.contains(where: { $0.isDirectory && $0.name == "font" }))
    #expect(files.contains(where: { !$0.isDirectory && $0.name == "test.ttf" }))

    let pages = try Yaffs2.pageCount(files)
    #expect(pages == 3) // 1 for font dir header, 1 for test.ttf header, 1 for test.ttf data chunk

    var emitted = 0
    try Yaffs2.forEachPage(files) { page in
        #expect(page.count == Yaffs2.chunkData + 16)
        emitted += 1
    }
    #expect(emitted == 3)
}

@Test func p65FactoryRoundTrip() throws {
    let part = DeviceProfile.p65.storage.factory
    let props: [FactoryIdentity.Property] = [
        .init(key: "ro.factory.did", value: "1502000001"),
        .init(key: "ro.factory.psn", value: "QEMU1502P00001"),
        .init(key: "ro.factory.mac_bt", value: "C0:FF:EE:15:02:01"),
        .init(key: "ro.factory.key", value: "0123456789ABCDEF"),
        .init(key: "ro.factory.fsn", value: "QEMU1502P00001"),
        .init(key: "ro.factory.sku", value: "M2509W1"),
    ]
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-test-p65-nor.img")
    try ImageBuilder.createErasedNOR(at: url, size: 0x100_0000)
    defer { try? FileManager.default.removeItem(at: url) }
    try ImageBuilder.writeFactory(into: url, part: part, properties: props)
    let readBack = try ImageBuilder.readFactory(from: url, part: part)
    #expect(readBack == props)
}

@Test func p65NSHInjectorPlan() throws {
    let fwURL = URL(fileURLWithPath: "/Volumes/EXT0/GitHub/qemu-miwear/miwear.watch.p65_v3.100.043_full_662aa7db/vela_ap.bin")
    guard FileManager.default.fileExists(atPath: fwURL.path) else { return }
    let plan = try NSHInjector.plan(firmware: fwURL)
    #expect(plan.shMain == 0x0c5ad859)
    #expect(plan.shName == 0x3c181fac)
    #expect(plan.call == 0x0c4c3002)
    #expect(plan.spawn == 0x0c4c96f4)
}
