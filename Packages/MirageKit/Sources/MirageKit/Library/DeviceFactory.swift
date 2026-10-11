import Foundation

public extension MirageLibrary {
    /// Profiles that can run `firmware`.
    func profiles(for firmware: Firmware) -> [DeviceProfile] {
        profiles().filter { $0.runs(firmware) }
    }

    /// A new device record (images not built yet; see DeviceStorage.provision).
    func makeDevice(name: String? = nil, firmware: Firmware, profile: DeviceProfile? = nil,
                    binding: BindInfo? = nil, options: RuntimeOptions = .init()) throws -> VirtualDevice {
        guard let profile = profile ?? profiles(for: firmware).first else {
            throw MirageError.invalid("No device profile runs \(firmware.product) (\(firmware.chip ?? "unknown chip")). Add one in Device Profiles.")
        }
        guard profile.runs(firmware) else {
            throw MirageError.invalid("\(profile.name) does not run \(firmware.product)")
        }
        let base = name ?? firmware.marketingName
        var finalName = base
        var n = 2
        let names = Set(devices().map(\.name))
        while names.contains(finalName) {
            finalName = "\(base) (\(n))"
            n += 1
        }
        return VirtualDevice(name: finalName, profileID: profile.id, firmwareID: firmware.id,
                             identity: .generate(for: profile), binding: binding ?? .generate(), options: options)
    }
}
