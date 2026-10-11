import Foundation

/// One emulated device: a profile, a firmware, its own storage images and
/// factory identity. Lives in `<library>/Devices/<id>/device.json`.
public struct VirtualDevice: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var profileID: String
    public var firmwareID: String
    public var createdAt: Date
    public var lastBootedAt: Date?
    public var identity: FactoryIdentity
    public var binding: BindInfo
    public var options: RuntimeOptions
    public var storage: StorageState

    public init(id: UUID = UUID(), name: String, profileID: String, firmwareID: String,
                identity: FactoryIdentity, binding: BindInfo, options: RuntimeOptions = .init()) {
        self.id = id
        self.name = name
        self.profileID = profileID
        self.firmwareID = firmwareID
        self.createdAt = Date()
        self.identity = identity
        self.binding = binding
        self.options = options
        self.storage = .init()
    }

    public var shortID: String { String(id.uuidString.prefix(8)).lowercased() }
}

/// What the factory line writes into /factory.prop.
public struct FactoryIdentity: Codable, Hashable, Sendable {
    /// ro.factory.did, decimal; the bind state machine fails without it.
    public var did: String
    /// ro.factory.psn, 1...31 characters.
    public var serial: String
    /// ro.factory.mac_bt; also the emulated controller's BD_ADDR.
    public var bluetoothAddress: String
    /// Extra factory properties, written after the ones above.
    public var extra: [Property]

    public struct Property: Codable, Hashable, Sendable, Identifiable {
        public var key: String
        public var value: String
        public var id: String { key }

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public init(did: String, serial: String, bluetoothAddress: String, extra: [Property] = []) {
        self.did = did
        self.serial = serial
        self.bluetoothAddress = bluetoothAddress
        self.extra = extra
    }

    public static func generate(for profile: DeviceProfile) -> FactoryIdentity {
        var rng = SystemRandomNumberGenerator()
        let did = profile.defaults.didPrefix + String(format: "%06d", Int.random(in: 1...999_999, using: &rng))
        let tail = (0..<(18 - profile.defaults.psnPrefix.count)).map { _ in
            String(Int.random(in: 0...9, using: &rng))
        }.joined()
        // locally administered unicast address
        var mac = (0..<6).map { _ in UInt8.random(in: 0...255, using: &rng) }
        mac[0] = (mac[0] & 0xFC) | 0x02
        return FactoryIdentity(
            did: did,
            serial: profile.defaults.psnPrefix + tail,
            bluetoothAddress: mac.map { String(format: "%02X", $0) }.joined(separator: ":"))
    }

    public func validate() throws {
        guard !did.isEmpty, did.allSatisfy(\.isNumber) else {
            throw MirageError.invalid("Device ID must be decimal digits")
        }
        guard (1...31).contains(serial.count), serial.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
            throw MirageError.invalid("Serial number must have 1–31 printable ASCII characters")
        }
        guard FactoryIdentity.isValidAddress(bluetoothAddress) else {
            throw MirageError.invalid("Bluetooth address must look like XX:XX:XX:XX:XX:XX")
        }
    }

    public static func isValidAddress(_ s: String) -> Bool {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 6 && parts.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }
    }
}

/// The band's view of the phone it is bound to. The firmware binds over
/// the server-PSK flow only, so an offline emulator cannot be bound for the
/// first time; instead it starts out "already bound" with these keys, and
/// AstroBox connects with the token key as its AuthKey.
public struct BindInfo: Codable, Hashable, Sendable {
    public var bound: Bool
    /// persist.miwear_token_key: 16 bytes hex; AstroBox's AuthKey.
    public var authKey: String
    public var userID: String
    public var beaconKey: String
    public var irKey: String
    public var seqnum: String

    public init(bound: Bool, authKey: String, userID: String, beaconKey: String, irKey: String, seqnum: String) {
        self.bound = bound
        self.authKey = authKey
        self.userID = userID
        self.beaconKey = beaconKey
        self.irKey = irKey
        self.seqnum = seqnum
    }

    public static func randomKey() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    public static func generate() -> BindInfo {
        BindInfo(bound: true, authKey: randomKey(), userID: "10000001",
                beaconKey: randomKey(), irKey: randomKey(), seqnum: "1")
    }

    public static func isValidKey(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy(\.isHexDigit)
    }

    public func validate() throws {
        guard bound else { return }
        for (name, key) in [("AuthKey", authKey), ("Beacon key", beaconKey), ("IR key", irKey)] {
            guard BindInfo.isValidKey(key) else {
                throw MirageError.invalid("\(name) must be 32 hex digits (16 bytes)")
            }
        }
        guard !userID.isEmpty else { throw MirageError.invalid("User ID must not be empty") }
    }

    /// The persist.miwear_* properties that make the band consider itself
    /// bound.
    public var properties: [FactoryIdentity.Property] {
        guard bound else { return [] }
        return [
            .init(key: "persist.miwear_token_key", value: authKey.lowercased()),
            .init(key: "persist.miwear_user_id", value: userID),
            .init(key: "persist.miwear_beacon_key", value: beaconKey.lowercased()),
            .init(key: "persist.miwear_ir_key", value: irKey.lowercased()),
            .init(key: "persist.miwear_seqnum", value: seqnum),
        ]
    }
}

public struct RuntimeOptions: Codable, Hashable, Sendable {
    /// Start the firmware's built-in NuttX shell on the console UART.
    public var shell: Bool
    /// Serve the band's Bluetooth radio to a peer host (AstroBox) on TCP.
    public var bluetoothBridge: Bool
    /// TCP port of the Bluetooth bridge; 0 picks a free one at boot.
    public var bluetoothPort: Int
    /// Extra QEMU arguments, one per element.
    public var extraArguments: [String]
    /// QEMU -d log items (e.g. "guest_errors,unimp").
    public var debugLog: String
    public var traceEvents: [String]

    public init(shell: Bool = true, bluetoothBridge: Bool = true, bluetoothPort: Int = 0,
                extraArguments: [String] = [], debugLog: String = "", traceEvents: [String] = []) {
        self.shell = shell
        self.bluetoothBridge = bluetoothBridge
        self.bluetoothPort = bluetoothPort
        self.extraArguments = extraArguments
        self.debugLog = debugLog
        self.traceEvents = traceEvents
    }
}

/// What the device's images were built from.
public struct StorageState: Codable, Hashable, Sendable {
    public var builtAt: Date?
    /// Firmware whose romfs images are in NAND / eMMC.
    public var contentFirmwareID: String?
    /// Factory properties last written (to tell when they need rewriting).
    public var factoryProperties: [FactoryIdentity.Property]

    public init() {
        factoryProperties = []
    }
}

public enum MirageError: LocalizedError, Equatable {
    case invalid(String)
    case notFound(String)
    case io(String)
    case process(String)
    case protocolError(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .notFound(let s), .io(let s), .process(let s), .protocolError(let s):
            return s
        case .cancelled:
            return "Cancelled"
        }
    }
}
