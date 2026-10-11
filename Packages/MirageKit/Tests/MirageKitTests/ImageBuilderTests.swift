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
