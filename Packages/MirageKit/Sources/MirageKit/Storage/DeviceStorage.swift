import Foundation

/// Builds and maintains a device's storage images.
public struct DeviceStorage: Sendable {
    public let library: MirageLibrary

    public init(library: MirageLibrary) {
        self.library = library
    }

    public struct ImageFile: Identifiable, Sendable, Hashable {
        public var id: String { role.rawValue }
        public var role: Role
        public var url: URL
        public var exists: Bool
        /// Logical size.
        public var size: Int64
        /// Bytes actually allocated (eMMC images are sparse).
        public var allocated: Int64

        public enum Role: String, Sendable, CaseIterable {
            case mainNOR, sensorNOR, nand, emmc

            public var title: String {
                switch self {
                case .mainNOR: return "Boot NOR"
                case .sensorNOR: return "Sensor NOR"
                case .nand: return "SPI NAND"
                case .emmc: return "eMMC"
                }
            }

            public var detail: String {
                switch self {
                case .mainNOR: return "BL2, factory and parameter partitions; the AP firmware is installed on every boot"
                case .sensorNOR: return "Sensor hub flash: its firmware is installed on every boot, /misc keeps the factory data"
                case .nand: return "system (romfs or yaffs), /data (yaffs), coredump and nand_nv"
                case .emmc: return "GPT: firmware romfs partitions, nv, data and userlog (exFAT)"
                }
            }
        }
    }

    public func images(of device: VirtualDevice, profile: DeviceProfile) -> [ImageFile] {
        let paths = library.paths(for: device)
        var roles: [(ImageFile.Role, URL)] = []
        if profile.storage.mainNOR { roles.append((.mainNOR, paths.nor)) }
        if profile.storage.sensorNORSize != nil { roles.append((.sensorNOR, paths.sensorNOR)) }
        if profile.storage.nand != nil { roles.append((.nand, paths.nand)) }
        if profile.storage.emmc != nil { roles.append((.emmc, paths.emmc)) }
        return roles.map { role, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
            return ImageFile(role: role, url: url, exists: FileManager.default.fileExists(atPath: url.path),
                             size: Int64(values?.fileSize ?? 0), allocated: Int64(values?.totalFileAllocatedSize ?? 0))
        }
    }

    public func factoryNOR(of device: VirtualDevice, profile: DeviceProfile) -> URL {
        let paths = library.paths(for: device)
        return profile.storage.factory.flash == .mainNOR ? paths.nor : paths.sensorNOR
    }

    /// Builds every image from scratch: erased flashes with the factory
    /// partition, NAND / eMMC with the firmware's romfs content.
    public func provision(_ device: inout VirtualDevice, progress: ImageBuilder.Progress? = nil) async throws {
        let (profile, firmware) = try resolve(device)
        let paths = library.paths(for: device)
        let fwDir = library.firmwareDirectory(firmware.id)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try device.identity.validate()
        try device.binding.validate()
        let props = ImageBuilder.factoryProperties(identity: device.identity, binding: device.binding)

        if profile.storage.mainNOR {
            progress?(0, "Creating boot NOR")
            let info = try FirmwareImageInfo.read(apImage: fwDir.appendingPathComponent("vela_ap.bin"))
            try ImageBuilder.createErasedNOR(at: paths.nor, size: info.flashSize ?? 0x100_0000)
        }
        if let size = profile.storage.sensorNORSize {
            progress?(0, "Creating sensor NOR")
            try ImageBuilder.createErasedNOR(at: paths.sensorNOR, size: size)
        }
        progress?(0, "Writing factory data")
        try ImageBuilder.writeFactory(into: factoryNOR(of: device, profile: profile), part: profile.storage.factory, properties: props)

        if let nand = profile.storage.nand {
            let res = fwDir.appendingPathComponent(nand.resourceImage)
            let resource = !nand.resourceImage.isEmpty && FileManager.default.fileExists(atPath: res.path) ? res : nil
            try await runBlocking {
                try ImageBuilder.buildNAND(at: paths.nand, spec: nand, resource: resource,
                                           systemDir: fwDir, progress: progress)
            }
        }
        if let emmc = profile.storage.emmc {
            try await runBlocking {
                try ImageBuilder.buildEMMC(at: paths.emmc, spec: emmc, firmwareDirectory: fwDir, progress: progress)
            }
        }
        device.storage.builtAt = Date()
        device.storage.contentFirmwareID = firmware.id
        device.storage.factoryProperties = props
        try library.saveDevice(device)
    }

    /// Rewrites /factory.prop after identity or binding changes. The rest
    /// of the factory filesystem is rebuilt too (it holds nothing else).
    public func rewriteFactory(_ device: inout VirtualDevice) throws {
        let (profile, _) = try resolve(device)
        try device.identity.validate()
        try device.binding.validate()
        let url = factoryNOR(of: device, profile: profile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MirageError.notFound("The device's images have not been built yet")
        }
        let props = ImageBuilder.factoryProperties(identity: device.identity, binding: device.binding)
        try ImageBuilder.writeFactory(into: url, part: profile.storage.factory, properties: props)
        device.storage.factoryProperties = props
        try library.saveDevice(device)
    }

    public func readFactory(of device: VirtualDevice) throws -> [FactoryIdentity.Property] {
        let (profile, _) = try resolve(device)
        return try ImageBuilder.readFactory(from: factoryNOR(of: device, profile: profile), part: profile.storage.factory)
    }

    /// Moves a device to another firmware. NAND resource / eMMC romfs
    /// partitions are rewritten in place when they fit, so user data
    /// survives; otherwise everything is rebuilt.
    public func switchFirmware(_ device: inout VirtualDevice, to firmware: Firmware,
                               progress: ImageBuilder.Progress? = nil) async throws -> Bool {
        let profile = try profileOf(device)
        guard profile.runs(firmware) else {
            throw MirageError.invalid("\(firmware.id) is not firmware for \(profile.name)")
        }
        device.firmwareID = firmware.id
        let paths = library.paths(for: device)
        let fwDir = library.firmwareDirectory(firmware.id)
        var kept = true
        if let nand = profile.storage.nand, FileManager.default.fileExists(atPath: paths.nand.path) {
            if nand.systemPages != nil {
                try await runBlocking {
                    try ImageBuilder.updateSystemNAND(at: paths.nand, spec: nand, systemDir: fwDir, progress: progress)
                }
            } else {
                let res = fwDir.appendingPathComponent(nand.resourceImage)
                try await runBlocking {
                    try ImageBuilder.updateNANDResource(at: paths.nand, spec: nand, resource: res, progress: progress)
                }
            }
        }
        if let emmc = profile.storage.emmc, FileManager.default.fileExists(atPath: paths.emmc.path) {
            kept = try await runBlocking {
                try ImageBuilder.updateEMMC(at: paths.emmc, spec: emmc, firmwareDirectory: fwDir, progress: progress)
            }
        }
        if !kept {
            try await provision(&device, progress: progress)
            return false
        }
        device.storage.contentFirmwareID = firmware.id
        try library.saveDevice(device)
        return true
    }

    /// "Erase All Content and Settings": rebuilds every image, keeping the
    /// device's identity and binding keys.
    public func erase(_ device: inout VirtualDevice, progress: ImageBuilder.Progress? = nil) async throws {
        try await provision(&device, progress: progress)
    }

    /// A copy of a device with its own identity; images are APFS clones.
    public func duplicate(_ device: VirtualDevice, name: String) throws -> VirtualDevice {
        let profile = try profileOf(device)
        var copy = device
        copy.id = UUID()
        copy.name = name
        copy.createdAt = Date()
        copy.lastBootedAt = nil
        copy.identity = FactoryIdentity.generate(for: profile)
        copy.options.bluetoothPort = 0
        let src = library.paths(for: device), dst = library.paths(for: copy)
        try FileManager.default.createDirectory(at: dst.logs, withIntermediateDirectories: true)
        for img in images(of: device, profile: profile) where img.exists {
            try FileManager.default.copyItem(at: img.url, to: dst.root.appendingPathComponent(img.url.lastPathComponent))
        }
        try library.saveDevice(copy)
        if FileManager.default.fileExists(atPath: factoryNOR(of: copy, profile: profile).path) {
            try rewriteFactory(&copy)
        }
        _ = src
        return copy
    }

    func resolve(_ device: VirtualDevice) throws -> (DeviceProfile, Firmware) {
        let profile = try profileOf(device)
        guard let fw = library.firmware(device.firmwareID) else {
            throw MirageError.notFound("Firmware \(device.firmwareID) is not in the library")
        }
        return (profile, fw)
    }

    func profileOf(_ device: VirtualDevice) throws -> DeviceProfile {
        guard let p = library.profile(device.profileID) else {
            throw MirageError.notFound("Device profile \(device.profileID) does not exist")
        }
        return p
    }
}

/// Runs blocking file work off the cooperative pool.
func runBlocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            cont.resume(with: Result { try body() })
        }
    }
}
