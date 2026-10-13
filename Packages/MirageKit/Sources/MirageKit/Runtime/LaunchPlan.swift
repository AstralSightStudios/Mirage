import Foundation

/// Finds qemu-system-arm built from the qemu-miwear submodule.
public enum QEMULocator {
    public static let overrideKey = "QEMUPath"

    /// Mirage's source checkout (for the submodule build), from the app's
    /// Info.plist (`MirageSourceRoot`) or found above the executable.
    public static var sourceRoot: URL? {
        if let s = Bundle.main.object(forInfoDictionaryKey: "MirageSourceRoot") as? String, !s.isEmpty,
           FileManager.default.fileExists(atPath: s + "/External/qemu-miwear") {
            return URL(fileURLWithPath: s, isDirectory: true)
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("External/qemu-miwear").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    public struct Candidate: Identifiable, Hashable, Sendable {
        public var id: String { url.path }
        public var title: String
        public var url: URL
        public var exists: Bool
    }

    #if os(Windows)
    static let binaryName = "qemu-system-arm.exe"
    #else
    static let binaryName = "qemu-system-arm"
    #endif

    static func isRunnable(_ url: URL) -> Bool {
        #if os(Windows)
        return FileManager.default.fileExists(atPath: url.path)
        #else
        return FileManager.default.isExecutableFile(atPath: url.path)
        #endif
    }

    public static func candidates() -> [Candidate] {
        var out: [Candidate] = []
        func add(_ title: String, _ url: URL) {
            guard !out.contains(where: { $0.url == url }) else { return }
            out.append(.init(title: title, url: url, exists: isRunnable(url)))
        }
        if let env = ProcessInfo.processInfo.environment["MIRAGE_QEMU"], !env.isEmpty {
            add("MIRAGE_QEMU", URL(fileURLWithPath: env))
        }
        if let custom = MirageLibrary.defaults.string(forKey: overrideKey), !custom.isEmpty {
            add("Custom", URL(fileURLWithPath: custom))
        }
        #if os(macOS)
        if let helpers = Bundle.main.privateFrameworksURL?.deletingLastPathComponent() {
            add("Bundled with Mirage", helpers.appendingPathComponent("Helpers/qemu/bin/qemu-system-arm"))
        }
        #else
        // qemu\ next to Mirage.exe (Windows zip) or the mirage binary
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        add("Bundled with Mirage", exeDir.appendingPathComponent("qemu/\(binaryName)"))
        #endif
        if let root = sourceRoot {
            add("Submodule build", root.appendingPathComponent("External/qemu-miwear/build/\(binaryName)"))
        }
        return out
    }

    public static func locate() -> URL? {
        candidates().first { $0.exists }?.url
    }

    /// `profile=help` of a qemu binary: the boards it knows.
    public static func boards(of qemu: URL) -> [String] {
        let p = Process()
        p.executableURL = qemu
        #if os(Windows)
        let nullDevice = "NUL"
        #else
        let nullDevice = "/dev/null"
        #endif
        p.arguments = ["-M", "miwear,profile=help", "-kernel", nullDevice, "-display", "none"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("Board"), let first = t.split(separator: " ").first else { return nil }
            return String(first)
        }
    }

    public static func version(of qemu: URL) -> String? {
        let p = Process()
        p.executableURL = qemu
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init)
    }
}

/// Command line for one boot of a device.
public struct LaunchPlan: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    public var paths: DevicePaths
    public var endpoints: DeviceEndpoints
    public var bluetoothPort: Int?
    public var shell: Bool
    public var firmwareImage: URL

    /// Aux QMP socket for tools (miragectl) while Mirage holds the main one.
    public var auxQMPSocket: URL { paths.runtime.appendingPathComponent("qmp-aux.sock") }

    public static func make(device: VirtualDevice, profile: DeviceProfile, firmware: Firmware,
                            library: MirageLibrary, qemu: URL) throws -> LaunchPlan {
        let paths = library.paths(for: device)
        let fwDir = library.firmwareDirectory(firmware.id)
        let ap = fwDir.appendingPathComponent("vela_ap.bin")
        guard FileManager.default.fileExists(atPath: ap.path) else {
            throw MirageError.notFound("The firmware has no vela_ap.bin")
        }
        var machine = "miwear,profile=\(profile.qemuBoard)"
        let storage = DeviceStorage(library: library)
        for img in storage.images(of: device, profile: profile) where !img.exists {
            throw MirageError.notFound("\(img.role.title) image is missing; rebuild the device's storage")
        }
        if profile.storage.mainNOR { machine += ",flash-image=\(escape(paths.nor.path))" }
        if profile.storage.sensorNORSize != nil { machine += ",sensor-nor=\(escape(paths.sensorNOR.path))" }
        if profile.storage.nand != nil { machine += ",nand-image=\(escape(paths.nand.path))" }
        if let battery = device.options.battery {
            machine += ",battery-level=\(max(0, min(100, battery.level))),battery-charging=\(battery.charging ? "on" : "off")"
        }

        let endpoints = try DeviceEndpoints.forHost(paths)
        var args = ["-M", machine, "-kernel", ap.path,
                    "-name", "Mirage: \(escape(device.name))",
                    "-display", "none",
                    "-vnc", endpoints.vnc.vncOption,
                    "-qmp", endpoints.qmp.serverOption,
                    "-qmp", endpoints.qmpAux.serverOption,
                    "-monitor", "none",
                    "-chardev", "socket,id=con,\(endpoints.console.chardevAddress),server=on,wait=off,logfile=\(escape(paths.consoleLog.path))"]
        for n in 0..<max(profile.uartCount, profile.consoleUART + 1) {
            args += ["-serial", n == profile.consoleUART ? "chardev:con" : "file:\(paths.uartLog(n).path)"]
        }
        if let emmc = profile.storage.emmc, emmc.sizeGiB > 0 {
            args += ["-drive", "if=sd,index=0,format=raw,file=\(escape(paths.emmc.path))"]
        }
        args += ["-global", "driver=bes.btss,property=bdaddr,value=\(device.identity.bluetoothAddress.uppercased())"]
        var btPort: Int?
        if device.options.bluetoothBridge {
            var port = device.options.bluetoothPort
            if port == 0 || !isLoopbackPortFree(port) { port = freeLoopbackPort() ?? 0 }
            if port > 0 {
                btPort = port
                args += ["-chardev", "socket,id=bt,host=127.0.0.1,port=\(port),server=on,wait=off",
                         "-global", "driver=bes.btss,property=chardev,value=bt"]
            }
        }
        if device.options.shell {
            args += ["-S", "-gdb", endpoints.gdb.serverOption]
        }
        // Keymaps directory for VNC so QEMU never fails with missing 'en-us' keymap
        let qemuDir = qemu.deletingLastPathComponent()
        let bundleResources = qemuDir.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/qemu", isDirectory: true)

        let candidateDirs = [
            bundleResources,
            qemuDir.deletingLastPathComponent().appendingPathComponent("share/qemu", isDirectory: true),
            qemuDir.appendingPathComponent("share/qemu", isDirectory: true),
            qemuDir.deletingLastPathComponent().appendingPathComponent("pc-bios", isDirectory: true),
            qemuDir.appendingPathComponent("pc-bios", isDirectory: true),
            library.root.deletingLastPathComponent().appendingPathComponent("External/qemu-miwear/pc-bios", isDirectory: true)
        ]
        for dir in candidateDirs {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("keymaps/en-us").path) {
                args += ["-L", dir.path]
                break
            }
        }
        args += ["-D", paths.qemuLog.path]
        if !device.options.debugLog.isEmpty { args += ["-d", device.options.debugLog] }
        for t in device.options.traceEvents where !t.isEmpty { args += ["-trace", t] }
        args += device.options.extraArguments.filter { !$0.isEmpty }
        return LaunchPlan(executable: qemu, arguments: args, workingDirectory: paths.root, paths: paths,
                          endpoints: endpoints, bluetoothPort: btPort, shell: device.options.shell, firmwareImage: ap)
    }

    /// QEMU option values escape commas by doubling them.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: ",", with: ",,")
    }

    public var commandLine: String {
        ([executable.path] + arguments).map { a in
            a.contains(where: { " \"'$`\\".contains($0) }) ? "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'" : a
        }.joined(separator: " ")
    }
}
