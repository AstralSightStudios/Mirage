import Foundation

/// The on-disk library: firmware packages, devices and custom profiles.
///
///     <root>/Firmwares/<package>/          unpacked OTA package + firmware.json
///     <root>/Devices/<uuid>/device.json    device record
///     <root>/Devices/<uuid>/*.img          its storage images
///     <root>/Devices/<uuid>/Logs/          console, UART and QEMU logs
///     <root>/Profiles/<id>.json            user device profiles
///     <root>/Downloads/                    partial archive downloads
public final class MirageLibrary: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()

    public static let defaultsSuite = "moe.astralsight.mirage"
    public static let libraryPathKey = "LibraryPath"

    public static var defaults: UserDefaults {
        if Bundle.main.bundleIdentifier == defaultsSuite {
            return .standard
        }
        return UserDefaults(suiteName: defaultsSuite) ?? .standard
    }

    public init(root: URL) throws {
        self.root = root
        for dir in [firmwaresDirectory, devicesDirectory, profilesDirectory, downloadsDirectory] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// The library the app and miragectl share (UserDefaults suite
    /// `moe.astralsight.mirage`, key `LibraryPath`).
    public static func shared() throws -> MirageLibrary {
        try MirageLibrary(root: configuredRoot)
    }

    public static var defaultRoot: URL {
        #if os(Windows)
        if let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"], !local.isEmpty {
            return URL(fileURLWithPath: local, isDirectory: true).appendingPathComponent("Mirage", isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mirage", isDirectory: true)
    }

    public static var configuredRoot: URL {
        if let env = ProcessInfo.processInfo.environment["MIRAGE_LIBRARY"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let path = defaults.string(forKey: libraryPathKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultRoot
    }

    public static func setConfiguredRoot(_ url: URL?) {
        defaults.set(url?.path, forKey: libraryPathKey)
    }

    public var firmwaresDirectory: URL { root.appendingPathComponent("Firmwares", isDirectory: true) }
    public var devicesDirectory: URL { root.appendingPathComponent("Devices", isDirectory: true) }
    public var profilesDirectory: URL { root.appendingPathComponent("Profiles", isDirectory: true) }
    public var downloadsDirectory: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    public var archiveCacheURL: URL { root.appendingPathComponent("archive-cache.json") }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Profiles

    public func profiles() -> [DeviceProfile] {
        var all = DeviceProfile.builtins
        let files = (try? FileManager.default.contentsOfDirectory(at: profilesDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  var p = try? Self.decoder.decode(DeviceProfile.self, from: data) else { continue }
            p.builtin = false
            if let i = all.firstIndex(where: { $0.id == p.id }) {
                all[i] = p
            } else {
                all.append(p)
            }
        }
        return all
    }

    public func profile(_ id: String) -> DeviceProfile? {
        profiles().first { $0.id == id }
    }

    public func saveProfile(_ profile: DeviceProfile) throws {
        guard !profile.id.isEmpty, profile.id.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else {
            throw MirageError.invalid("Profile IDs may only contain letters, digits, '-', '_' and '.'")
        }
        var p = profile
        p.builtin = false
        let data = try Self.encoder.encode(p)
        try data.write(to: profilesDirectory.appendingPathComponent("\(p.id).json"), options: .atomic)
    }

    public func deleteProfile(_ id: String) throws {
        let url = profilesDirectory.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Firmware

    public func firmwareDirectory(_ id: String) -> URL {
        firmwaresDirectory.appendingPathComponent(id, isDirectory: true)
    }

    public func firmwares() -> [Firmware] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: firmwaresDirectory, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("firmware.json")) else { return nil }
            return try? Self.decoder.decode(Firmware.self, from: data)
        }.sorted { ($0.product, $1.version) < ($1.product, $0.version) }
    }

    public func firmware(_ id: String) -> Firmware? {
        guard let data = try? Data(contentsOf: firmwareDirectory(id).appendingPathComponent("firmware.json")) else { return nil }
        return try? Self.decoder.decode(Firmware.self, from: data)
    }

    func saveFirmware(_ fw: Firmware) throws {
        try Self.encoder.encode(fw).write(to: firmwareDirectory(fw.id).appendingPathComponent("firmware.json"), options: .atomic)
    }

    public func deleteFirmware(_ id: String) throws {
        if let user = devices().first(where: { $0.firmwareID == id }) {
            throw MirageError.invalid("“\(user.name)” runs this firmware; delete or move that device first")
        }
        try FileManager.default.removeItem(at: firmwareDirectory(id))
    }

    // MARK: Devices

    public func deviceDirectory(_ id: UUID) -> URL {
        devicesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func devices() -> [VirtualDevice] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: devicesDirectory, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("device.json")) else { return nil }
            return try? Self.decoder.decode(VirtualDevice.self, from: data)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func device(_ id: UUID) -> VirtualDevice? {
        guard let data = try? Data(contentsOf: deviceDirectory(id).appendingPathComponent("device.json")) else { return nil }
        return try? Self.decoder.decode(VirtualDevice.self, from: data)
    }

    /// Finds a device by UUID, UUID prefix or (case-insensitive) name.
    public func findDevice(_ query: String) -> VirtualDevice? {
        let all = devices()
        if let u = UUID(uuidString: query), let d = all.first(where: { $0.id == u }) { return d }
        let q = query.lowercased()
        if let d = all.first(where: { $0.name.lowercased() == q }) { return d }
        let byPrefix = all.filter { $0.id.uuidString.lowercased().hasPrefix(q) }
        return byPrefix.count == 1 ? byPrefix[0] : nil
    }

    public func saveDevice(_ device: VirtualDevice) throws {
        lock.lock()
        defer { lock.unlock() }
        let dir = deviceDirectory(device.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.encoder.encode(device).write(to: dir.appendingPathComponent("device.json"), options: .atomic)
    }

    public func deleteDevice(_ id: UUID) throws {
        try FileManager.default.removeItem(at: deviceDirectory(id))
    }

    public func paths(for device: VirtualDevice) -> DevicePaths {
        DevicePaths(root: deviceDirectory(device.id), shortID: device.shortID)
    }
}

/// Files of one device.
public struct DevicePaths: Sendable {
    public let root: URL
    public let shortID: String

    public var nor: URL { root.appendingPathComponent("nor.img") }
    public var sensorNOR: URL { root.appendingPathComponent("sensor-nor.img") }
    public var nand: URL { root.appendingPathComponent("nand.img") }
    public var emmc: URL { root.appendingPathComponent("emmc.img") }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var screenshots: URL { root.appendingPathComponent("Screenshots", isDirectory: true) }
    public var astrobox: URL { root.appendingPathComponent("AstroBox", isDirectory: true) }
    public var pidFile: URL { root.appendingPathComponent("qemu.pid") }
    public var runtimeFile: URL { root.appendingPathComponent("runtime.json") }

    /// Sockets live in a short per-device directory: unix socket paths are
    /// limited to 104 bytes and the library may be deep.
    public var runtime: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mirage-\(shortID)", isDirectory: true)
    }

    public var qmpSocket: URL { runtime.appendingPathComponent("qmp.sock") }
    public var vncSocket: URL { runtime.appendingPathComponent("vnc.sock") }
    public var consoleSocket: URL { runtime.appendingPathComponent("console.sock") }
    public var gdbSocket: URL { runtime.appendingPathComponent("gdb.sock") }

    public func uartLog(_ n: Int) -> URL { logs.appendingPathComponent("uart\(n).log") }
    public var consoleLog: URL { logs.appendingPathComponent("console.log") }
    public var qemuLog: URL { logs.appendingPathComponent("qemu.log") }
    public var stdoutLog: URL { logs.appendingPathComponent("stdout.log") }
}
