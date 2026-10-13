import Foundation

/// Hardware description of an emulated device model: which qemu-miwear board
/// it runs on, what its screen and buttons look like, and how its storage
/// is laid out. Built-in profiles mirror the boards in qemu-miwear's
/// hw/arm/bes_board.c; users can add their own (for another product code of
/// the same board, or a board added to the emulator later).
public struct DeviceProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var family: Family
    /// SoC, as the firmware names it in its boot info (CHIP=).
    public var chip: String
    /// Board profile passed to the machine (`-M miwear,profile=<board>`).
    public var qemuBoard: String
    /// Firmware products this profile runs, matched as prefixes of the
    /// product name (`miwear.watch.p67` matches p67cn, p67tc, ...).
    public var productPrefixes: [String]
    public var screen: Screen
    public var buttons: [HardwareButton]
    public var storage: StorageLayout
    /// UART that carries the console (and the injected NSH).
    public var consoleUART: Int
    public var uartCount: Int
    public var defaults: FactoryDefaults
    public var accent: String
    public var notes: String
    public var builtin: Bool

    public enum Family: String, Codable, Sendable, CaseIterable {
        case band, watch

        public var title: String { self == .band ? "Band" : "Watch" }
    }

    public struct Screen: Codable, Hashable, Sendable {
        public var width: Int
        public var height: Int
        public var shape: Shape
        /// Corner radius in panel pixels for `.roundedRect`.
        public var cornerRadius: Double

        public enum Shape: String, Codable, Sendable, CaseIterable {
            case roundedRect, circle
        }

        public init(width: Int, height: Int, shape: Shape, cornerRadius: Double = 0) {
            self.width = width
            self.height = height
            self.shape = shape
            self.cornerRadius = cornerRadius
        }
    }

    public struct HardwareButton: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// QEMU key code the board's gpio-keys device listens for.
        public var qcode: String
        public var placement: Placement
        public var symbol: String

        public enum Placement: String, Codable, Sendable, CaseIterable {
            case crown, rightUpper, rightLower, left
        }

        public init(id: String, title: String, qcode: String, placement: Placement, symbol: String) {
            self.id = id
            self.title = title
            self.qcode = qcode
            self.placement = placement
            self.symbol = symbol
        }
    }

    public struct FactoryDefaults: Codable, Hashable, Sendable {
        /// Leading digits of generated device IDs (ro.factory.did).
        public var didPrefix: String
        /// Leading characters of generated serials (ro.factory.psn).
        public var psnPrefix: String

        public init(didPrefix: String, psnPrefix: String) {
            self.didPrefix = didPrefix
            self.psnPrefix = psnPrefix
        }
    }

    public init(id: String, name: String, family: Family, chip: String, qemuBoard: String,
                productPrefixes: [String], screen: Screen, buttons: [HardwareButton],
                storage: StorageLayout, consoleUART: Int, uartCount: Int = 3,
                defaults: FactoryDefaults, accent: String, notes: String = "", builtin: Bool = false) {
        self.id = id
        self.name = name
        self.family = family
        self.chip = chip
        self.qemuBoard = qemuBoard
        self.productPrefixes = productPrefixes
        self.screen = screen
        self.buttons = buttons
        self.storage = storage
        self.consoleUART = consoleUART
        self.uartCount = uartCount
        self.defaults = defaults
        self.accent = accent
        self.notes = notes
        self.builtin = builtin
    }

    public func runs(_ firmware: Firmware) -> Bool {
        if let chip = firmware.chip, chip != self.chip { return false }
        return productPrefixes.contains { firmware.product.hasPrefix($0) }
    }

    public func runs(product: String) -> Bool {
        productPrefixes.contains { product.hasPrefix($0) }
    }
}

/// Where a device keeps its persistent state, and what the factory line
/// would have written there.
public struct StorageLayout: Codable, Hashable, Sendable {
    /// Boot NOR backing file (`-M flash-image=`). Its size is the firmware's
    /// FLASH_SIZE; the AP firmware is installed into it on every boot.
    public var mainNOR: Bool
    /// Sensor hub NOR backing file (`-M sensor-nor=`), in bytes.
    public var sensorNORSize: Int?
    public var nand: NANDSpec?
    public var emmc: EMMCSpec?
    /// littlefs partition that holds /factory.prop.
    public var factory: FactoryPartition

    public init(mainNOR: Bool, sensorNORSize: Int? = nil, nand: NANDSpec? = nil,
                emmc: EMMCSpec? = nil, factory: FactoryPartition) {
        self.mainNOR = mainNOR
        self.sensorNORSize = sensorNORSize
        self.nand = nand
        self.emmc = emmc
        self.factory = factory
    }

    public var kindTitle: String {
        if nand != nil { return "SPI NAND" }
        if emmc != nil { return "eMMC" }
        return "NOR only"
    }
}

public struct FactoryPartition: Codable, Hashable, Sendable {
    public enum Flash: String, Codable, Sendable, CaseIterable {
        case mainNOR, sensorNOR

        public var title: String { self == .mainNOR ? "Boot NOR" : "Sensor NOR" }
    }

    public var flash: Flash
    public var offset: Int
    public var blockSize: Int
    public var blockCount: Int
    public var ioSize: Int
    public var nameMax: Int
    /// littlefs on-disk version, 0x00020000 = 2.0.
    public var diskVersion: UInt32
    /// How the factory data is stored; nil means littlefs.
    public var format: Format?

    public enum Format: String, Codable, Sendable {
        /// A littlefs filesystem holding /factory.prop (best1503 Band 10 Pro, Band 11).
        case littlefs
        /// The fixed-layout factory record the Band 9 and Band 10 firmware
        /// reads from /dev/factory: magic 0x9A55, CRC32 of the body, then
        /// the device fields at fixed offsets (see ImageBuilder.rawInfo).
        case rawInfo
        /// 256-byte fixed binary factory record (best1502p REDMI Watch 6, p65).
        case p65Record
    }

    public init(flash: Flash, offset: Int, blockSize: Int, blockCount: Int, ioSize: Int,
                nameMax: Int = 32, diskVersion: UInt32, format: Format? = nil) {
        self.flash = flash
        self.offset = offset
        self.blockSize = blockSize
        self.blockCount = blockCount
        self.ioSize = ioSize
        self.nameMax = nameMax
        self.diskVersion = diskVersion
        self.format = format
    }

    public var size: Int { blockSize * blockCount }
    public var isRawInfo: Bool { format == .rawInfo }
    public var isP65Record: Bool { format == .p65Record }
}

public struct NANDSpec: Codable, Hashable, Sendable {
    public var pageSize: Int
    public var oobSize: Int
    public var pagesPerBlock: Int
    public var blocks: Int
    /// The resource romfs (`dd of=/dev/resource` in the OTA script).
    public var resourceImage: String
    public var resourceFirstPage: Int
    public var resourcePages: Int
    /// Size in pages of a yaffs2 /system partition at page 0 that is built
    /// from the package's main_res files (Band 9 / Band 10). nil means the
    /// resource romfs above is used instead.
    public var systemPages: Int?
    /// Size in pages of the yaffs2 /data partition (nand_data in the
    /// firmware's partition table), right after system / resource. nil
    /// runs to the end of the part.
    public var dataPages: Int?

    public init(pageSize: Int, oobSize: Int, pagesPerBlock: Int, blocks: Int,
                resourceImage: String, resourceFirstPage: Int, resourcePages: Int,
                systemPages: Int? = nil, dataPages: Int? = nil) {
        self.pageSize = pageSize
        self.oobSize = oobSize
        self.pagesPerBlock = pagesPerBlock
        self.blocks = blocks
        self.resourceImage = resourceImage
        self.resourceFirstPage = resourceFirstPage
        self.resourcePages = resourcePages
        self.systemPages = systemPages
        self.dataPages = dataPages
    }

    public var dataFirstPage: Int { systemPages ?? (resourceFirstPage + resourcePages) }
    public var dataPageCount: Int { dataPages ?? (blocks * pagesPerBlock - dataFirstPage) }

    public var imageSize: Int { (pageSize + oobSize) * pagesPerBlock * blocks }
    public var capacity: Int { pageSize * pagesPerBlock * blocks }
}

public struct EMMCSpec: Codable, Hashable, Sendable {
    public var sizeGiB: Int
    /// romfs partitions, each filled from vela_<name>.bin.
    public var romfs: [String]
    /// Partitions the firmware formats itself (mount -o autoformat), MiB.
    public var blank: [Blank]

    public struct Blank: Codable, Hashable, Sendable {
        public var name: String
        public var mib: Int

        public init(name: String, mib: Int) {
            self.name = name
            self.mib = mib
        }
    }

    public init(sizeGiB: Int, romfs: [String], blank: [Blank]) {
        self.sizeGiB = sizeGiB
        self.romfs = romfs
        self.blank = blank
    }
}

public extension DeviceProfile {
    /// Xiaomi Smart Band 10 Pro: board "p67" (best1503, Cortex-M33).
    static let p67 = DeviceProfile(
        id: "p67",
        name: "Xiaomi Smart Band 10 Pro",
        family: .band,
        chip: "best1503",
        qemuBoard: "p67",
        productPrefixes: ["miwear.watch.p67"],
        screen: .init(width: 336, height: 480, shape: .roundedRect, cornerRadius: 48),
        buttons: [],
        storage: .init(
            mainNOR: true,
            nand: .init(pageSize: 2048, oobSize: 64, pagesPerBlock: 64, blocks: 4096,
                        resourceImage: "vela_resource.bin", resourceFirstPage: 0,
                        resourcePages: 0x19000, dataPages: 133_120),
            factory: .init(flash: .mainNOR, offset: 32512 * 512, blockSize: 8192,
                           blockCount: 16, ioSize: 512, diskVersion: 0x0002_0001)),
        consoleUART: 2,
        defaults: .init(didPrefix: "1503", psnPrefix: "QEMU1503"),
        accent: "#7B8CFF",
        notes: "Panel 336x480, Zinitix touch, SPI NAND (resource romfs + /data). No physical buttons.",
        builtin: true)

    /// Xiaomi Watch S5: board "q63" (best1700, Cortex-M55 + TEE, cp and sensor cores).
    static let q63 = DeviceProfile(
        id: "q63",
        name: "Xiaomi Watch S5",
        family: .watch,
        chip: "best1700",
        qemuBoard: "q63",
        productPrefixes: ["miwear.watch.q63"],
        screen: .init(width: 466, height: 466, shape: .circle),
        buttons: [
            .init(id: "home", title: "Crown", qcode: "home", placement: .crown, symbol: "digitalcrown.horizontal.press"),
            .init(id: "down", title: "Side Button", qcode: "pgdn", placement: .rightLower, symbol: "button.horizontal.top.press"),
        ],
        storage: .init(
            mainNOR: false,
            sensorNORSize: 0x80_0000,
            emmc: .init(sizeGiB: 4,
                        romfs: ["vendor", "system", "app", "health", "misc", "i18n", "font",
                                "watchface", "quickapp", "cp_image", "audio_image", "sensor", "store"],
                        blank: [.init(name: "nv", mib: 32), .init(name: "data", mib: 1024),
                                .init(name: "userlog", mib: 64)]),
            factory: .init(flash: .sensorNOR, offset: 0x7800 * 256, blockSize: 4096,
                           blockCount: 64, ioSize: 256, diskVersion: 0x0002_0000)),
        consoleUART: 0,
        defaults: .init(didPrefix: "1700", psnPrefix: "QEMU1700"),
        accent: "#F2A65A",
        notes: "466x466 round AMOLED, Raydium touch, eMMC (GPT), crown = HOME, side button = DOWN.",
        builtin: true)

    /// Xiaomi Smart Band 11: board "q66" (best1503), 212x520 panel.
    static let q66 = DeviceProfile(
        id: "q66",
        name: "Xiaomi Smart Band 11",
        family: .band,
        chip: "best1503",
        qemuBoard: "q66",
        productPrefixes: ["miwear.watch.q66"],
        screen: .init(width: 212, height: 520, shape: .roundedRect, cornerRadius: 104),
        buttons: [],
        storage: .init(
            mainNOR: true,
            nand: .init(pageSize: 2048, oobSize: 64, pagesPerBlock: 64, blocks: 4096,
                        resourceImage: "vela_resource.bin", resourceFirstPage: 0,
                        resourcePages: 65536, dataPages: 196_608),
            factory: .init(flash: .mainNOR, offset: 32256 * 512, blockSize: 8192,
                           blockCount: 16, ioSize: 512, diskVersion: 0x0002_0001)),
        consoleUART: 2,
        defaults: .init(didPrefix: "150", psnPrefix: "QEMU1503"),
        accent: "#5AC8FA",
        notes: "Panel 212x520, CST92xx touch, SPI NAND (resource romfs + /data). No physical buttons.",
        builtin: true)

    /// Xiaomi Smart Band 9: board "n66" (best1503), 192x490 panel. The
    /// firmware mounts /system from a yaffs2 partition built from its package.
    static let n66 = DeviceProfile(
        id: "n66",
        name: "Xiaomi Smart Band 9",
        family: .band,
        chip: "best1503",
        qemuBoard: "n66",
        productPrefixes: ["miwear.watch.n66"],
        screen: .init(width: 192, height: 490, shape: .roundedRect, cornerRadius: 96),
        buttons: [],
        storage: .init(
            mainNOR: true,
            nand: .init(pageSize: 2048, oobSize: 64, pagesPerBlock: 64, blocks: 4096,
                        resourceImage: "", resourceFirstPage: 0, resourcePages: 0,
                        systemPages: 65536, dataPages: 65536),
            factory: .init(flash: .mainNOR, offset: 16368 * 512, blockSize: 8192,
                           blockCount: 1, ioSize: 512, diskVersion: 0, format: .rawInfo)),
        consoleUART: 2,
        defaults: .init(didPrefix: "150", psnPrefix: "QEMU1503"),
        accent: "#34C759",
        notes: "Panel 192x490, Hynitron CST92xx touch, SPI NAND (yaffs /system + /data). No physical buttons.",
        builtin: true)

    /// Xiaomi Smart Band 10: board "o66" (best1503), 212x520 panel.
    static let o66 = DeviceProfile(
        id: "o66",
        name: "Xiaomi Smart Band 10",
        family: .band,
        chip: "best1503",
        qemuBoard: "o66",
        productPrefixes: ["miwear.watch.o66"],
        screen: .init(width: 212, height: 520, shape: .roundedRect, cornerRadius: 104),
        buttons: [],
        storage: .init(
            mainNOR: true,
            nand: .init(pageSize: 2048, oobSize: 64, pagesPerBlock: 64, blocks: 4096,
                        resourceImage: "", resourceFirstPage: 0, resourcePages: 0,
                        systemPages: 65536, dataPages: 196_608),
            factory: .init(flash: .mainNOR, offset: 16368 * 512, blockSize: 8192,
                           blockCount: 1, ioSize: 512, diskVersion: 0, format: .rawInfo)),
        consoleUART: 2,
        defaults: .init(didPrefix: "150", psnPrefix: "QEMU1503"),
        accent: "#FF9F0A",
        notes: "Panel 212x520, CST9217M touch, SPI NAND (yaffs /system + /data). No physical buttons.",
        builtin: true)

    /// Xiaomi Smart Band 9 Pro: board "n67" (best1503).
    static let n67 = DeviceProfile(
        id: "n67",
        name: "Xiaomi Smart Band 9 Pro",
        family: .band,
        chip: "best1503",
        qemuBoard: "n67",
        productPrefixes: ["miwear.watch.n67"],
        screen: .init(width: 336, height: 480, shape: .roundedRect, cornerRadius: 48),
        buttons: [],
        storage: .init(
            mainNOR: true,
            nand: .init(pageSize: 2048, oobSize: 64, pagesPerBlock: 64, blocks: 4096,
                        resourceImage: "", resourceFirstPage: 0, resourcePages: 0,
                        systemPages: 57600, dataPages: 73472),
            factory: .init(flash: .mainNOR, offset: 16368 * 512, blockSize: 8192,
                           blockCount: 1, ioSize: 512, diskVersion: 0, format: .rawInfo)),
        consoleUART: 1,
        defaults: .init(didPrefix: "150", psnPrefix: "QEMU1506"),
        accent: "#FF9F0A",
        notes: "Panel 336x480 (rm690c0 driver), Hynitron CST92xx touch on I2C5, W1150 light sensor on I2C5, SPI NAND (yaffs /system + /data). No physical buttons.",
        builtin: true)

    /// REDMI Watch 6: board "p65" (best1502p), 432x514 panel.
    static let p65 = DeviceProfile(
        id: "p65",
        name: "REDMI Watch 6",
        family: .watch,
        chip: "best1502p",
        qemuBoard: "p65",
        productPrefixes: ["miwear.watch.p65"],
        screen: .init(width: 432, height: 514, shape: .roundedRect, cornerRadius: 48),
        buttons: [
            .init(id: "home", title: "Upper Button", qcode: "home", placement: .rightUpper, symbol: "button.horizontal.top.press"),
            .init(id: "down", title: "Power Key", qcode: "pgdn", placement: .rightLower, symbol: "button.horizontal.top.press"),
        ],
        storage: .init(
            mainNOR: true,
            nand: .init(pageSize: 2048, oobSize: 64, pagesPerBlock: 64, blocks: 4096,
                        resourceImage: "vela_resource.bin", resourceFirstPage: 0,
                        resourcePages: 112640, dataPages: 149504),
            factory: .init(flash: .mainNOR, offset: 0xCC0000, blockSize: 256,
                           blockCount: 1, ioSize: 256, diskVersion: 0, format: .p65Record)),
        consoleUART: 1,
        defaults: .init(didPrefix: "1502", psnPrefix: "QEMU1502"),
        accent: "#FF5722",
        notes: "Panel 432x514 (rm690c0 driver), Zinitix touch on I2C5, SPI NAND (resource romfs + /data).",
        builtin: true)

    static let builtins: [DeviceProfile] = [.p67, .q63, .q66, .n66, .o66, .n67, .p65]
}
