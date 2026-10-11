import Darwin
import Foundation
import MirageKit

let usage = """
usage: miragectl <command> [arguments]

Library
  library [PATH]                     show (or set) the library location
  qemu                               show the QEMU binary and its boards
  profiles                           list device profiles

Firmware
  firmware list                      firmware in the library
  firmware import PATH               import a full OTA package (.zip/.bin or directory)
  firmware archive [--all] [QUERY]   releases on MiWearFirmwareArchives (emulatable ones)
  firmware download TAG|PRODUCT      download a full package and import it
  firmware rm ID                     remove firmware from the library

Devices
  list                               devices and their state
  create NAME --firmware ID [--profile ID] [--authkey HEX] [--unbound] [--no-shell]
  info DEVICE                        device details and factory data
  erase DEVICE                       rebuild storage (keeps identity and keys)
  delete DEVICE
  boot DEVICE [--no-shell]           boot in the background
  shutdown DEVICE
  screenshot DEVICE FILE.png
  tap DEVICE X Y                     touch the panel (pixels)
  swipe DEVICE X0 Y0 X1 Y1 [MS]
  button DEVICE QCODE [--hold SEC]   press a hardware key (home, pgdn, ...)
  sh DEVICE COMMAND...               run an NSH command, print its output
  console DEVICE                     interactive console (Ctrl-] quits)

Images
  image nor OUT --size BYTES --part main|sensor [--did N --psn S --mac ADDR --prop K=V ...]
  image nand OUT --resource FILE
  image emmc OUT FIRMWARE_DIR
  image gpt FILE                     print an eMMC image's partitions
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("miragectl: \(msg)\n".utf8))
    exit(1)
}

struct Args {
    var positional: [String] = []
    var options: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ argv: ArraySlice<String>, valued: Set<String>) {
        var it = argv.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if valued.contains(key) {
                    guard let v = it.next() else { fail("--\(key) needs a value") }
                    options[key, default: []].append(v)
                } else {
                    flags.insert(key)
                }
            } else {
                positional.append(a)
            }
        }
    }

    func value(_ k: String) -> String? { options[k]?.last }
}

func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

final class ProgressLine: @unchecked Sendable {
    private var last = ""
    private let lock = NSLock()

    func update(_ fraction: Double, _ label: String) {
        let line = String(format: "%3.0f%% %@", fraction * 100, label)
        lock.lock()
        defer { lock.unlock() }
        guard line != last else { return }
        last = line
        FileHandle.standardError.write(Data("\r\u{1B}[K\(line)".utf8))
    }

    func done() {
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
    }
}

@MainActor
func session(for device: VirtualDevice, _ library: MirageLibrary) async -> DeviceSession {
    let s = DeviceSession(deviceID: device.id, library: library)
    await s.attachIfRunning()
    return s
}

@MainActor
func waitForScreen(_ s: DeviceSession) async {
    for _ in 0..<50 where s.latestFrame == nil {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}

@MainActor
func run() async throws {
    let argv = CommandLine.arguments.dropFirst()
    guard let cmd = argv.first else { print(usage); return }
    let library = try MirageLibrary.shared()
    let rest = argv.dropFirst()
    let args = Args(rest, valued: ["firmware", "profile", "authkey", "hold", "size", "part", "did", "psn", "mac",
                                   "prop", "resource", "system", "timeout"])

    func device(_ i: Int = 0) -> VirtualDevice {
        guard args.positional.count > i else { fail("missing DEVICE") }
        guard let d = library.findDevice(args.positional[i]) else { fail("no device \(args.positional[i])") }
        return d
    }

    switch cmd {
    case "help", "-h", "--help":
        print(usage)

    case "library":
        if let path = args.positional.first {
            MirageLibrary.setConfiguredRoot(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            print("library: \(MirageLibrary.configuredRoot.path)")
        } else {
            print(library.root.path)
        }

    case "qemu":
        for c in QEMULocator.candidates() {
            print("\(c.exists ? "*" : " ") \(c.title): \(c.url.path)")
        }
        guard let q = QEMULocator.locate() else { fail("no qemu-system-arm found (make qemu)") }
        print(QEMULocator.version(of: q) ?? "")
        print("boards: \(QEMULocator.boards(of: q).joined(separator: ", "))")

    case "profiles":
        for p in library.profiles() {
            print("\(p.id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(p.name) [\(p.chip), board \(p.qemuBoard), \(p.screen.width)x\(p.screen.height), \(p.storage.kindTitle)]\(p.builtin ? "" : " (custom)")")
        }

    case "firmware":
        let sub = args.positional.first ?? "list"
        let pos = Array(args.positional.dropFirst())
        switch sub {
        case "list":
            for f in library.firmwares() {
                let runs = library.profiles(for: f).map(\.id).joined(separator: ",")
                print("\(f.id)\n    \(f.marketingName) \(f.version) \(f.chip ?? "?") \(bytes(f.totalSize)) profiles: \(runs.isEmpty ? "none" : runs)")
            }
        case "import":
            guard let path = pos.first else { fail("missing PATH") }
            let p = ProgressLine()
            let fw = try await FirmwareImporter(library: library).importPackage(
                at: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
                replace: args.flags.contains("replace"), progress: { p.update($0, $1) })
            p.done()
            print("imported \(fw.id) (\(fw.marketingName) \(fw.version), \(fw.chip ?? "?"))")
        case "archive":
            let client = FirmwareArchiveClient(library: library)
            let releases = try await client.fetch()
            let profiles = library.profiles()
            let q = pos.first?.lowercased()
            for r in releases {
                let runs = profiles.contains { $0.runs(product: r.product) }
                guard args.flags.contains("all") || runs else { continue }
                if let q, !(r.product.lowercased().contains(q) || r.marketingName.lowercased().contains(q)) { continue }
                let full = r.fullPackage.map { bytes($0.size) } ?? "no full package"
                print("\(runs ? "*" : " ") \(r.tag)  \(r.marketingName) \(r.version)  \(full)")
            }
        case "download":
            guard let q = pos.first else { fail("missing TAG or PRODUCT") }
            let client = FirmwareArchiveClient(library: library)
            var releases = client.cached()?.releases ?? []
            if releases.isEmpty { releases = try await client.fetch() }
            guard let r = releases.first(where: { $0.tag == q }) ?? releases.first(where: { $0.product == q || $0.product.hasSuffix("." + q) }),
                  let asset = r.fullPackage else { fail("no release with a full package matches \(q)") }
            let p = ProgressLine()
            let file = try await ArchiveDownload(asset: asset, into: library.downloadsDirectory).start { done, total in
                p.update(Double(done) / Double(max(total, 1)), "Downloading \(asset.name) (\(bytes(done)) / \(bytes(total)))")
            }
            p.done()
            let fw = try await FirmwareImporter(library: library).importPackage(
                at: file, origin: .archive(tag: r.tag, asset: asset.name, notes: r.notes), progress: { p.update($0, $1) })
            p.done()
            try? FileManager.default.removeItem(at: file)
            print("imported \(fw.id)")
        case "rm":
            guard let id = pos.first else { fail("missing ID") }
            try library.deleteFirmware(id)
        default:
            fail("unknown firmware command \(sub)")
        }

    case "list":
        for d in library.devices() {
            let live = RuntimeRecord.live(at: library.paths(for: d).runtimeFile)
            let state = live.map { "Booted (pid \($0.pid)\($0.bluetoothPort.map { ", BT :\($0)" } ?? ""))" } ?? "Shut Down"
            print("\(d.shortID)  \(d.name.padding(toLength: 30, withPad: " ", startingAt: 0)) \(d.profileID.padding(toLength: 6, withPad: " ", startingAt: 0)) \(library.firmware(d.firmwareID)?.version ?? "?")  \(state)")
        }

    case "create":
        guard let name = args.positional.first else { fail("missing NAME") }
        guard let fwID = args.value("firmware"), let fw = library.firmware(fwID) ?? library.firmwares().first(where: { $0.id.hasPrefix(fwID) }) else {
            fail("--firmware ID required (miragectl firmware list)")
        }
        let profile = args.value("profile").flatMap(library.profile)
        var binding = BindInfo.generate()
        if let key = args.value("authkey") { binding.authKey = key.lowercased() }
        if args.flags.contains("unbound") { binding.bound = false }
        var opts = RuntimeOptions()
        opts.shell = !args.flags.contains("no-shell")
        var d = try library.makeDevice(name: name, firmware: fw, profile: profile, binding: binding, options: opts)
        try library.saveDevice(d)
        let p = ProgressLine()
        do {
            try await DeviceStorage(library: library).provision(&d) { p.update($0, $1) }
        } catch {
            try? library.deleteDevice(d.id)
            throw error
        }
        p.done()
        print("created \(d.name) (\(d.id.uuidString)) AuthKey \(d.binding.authKey)")

    case "info":
        let d = device()
        let storage = DeviceStorage(library: library)
        print("name:      \(d.name)\nid:        \(d.id.uuidString)\nprofile:   \(d.profileID)\nfirmware:  \(d.firmwareID)")
        print("did:       \(d.identity.did)\nserial:    \(d.identity.serial)\nbt addr:   \(d.identity.bluetoothAddress)")
        print("bound:     \(d.binding.bound)  authkey \(d.binding.authKey)")
        if let p = library.profile(d.profileID) {
            for img in storage.images(of: d, profile: p) {
                print("\(img.role.title.padding(toLength: 11, withPad: " ", startingAt: 0)) \(img.exists ? "\(bytes(img.size)) (\(bytes(img.allocated)) on disk)" : "missing")  \(img.url.path)")
            }
        }
        if let props = try? storage.readFactory(of: d) {
            print("factory.prop:")
            for p in props { print("  \(p.key)=\(p.value)") }
        }
        if let r = RuntimeRecord.live(at: library.paths(for: d).runtimeFile) {
            print("running:   pid \(r.pid), started \(r.startedAt)\(r.bluetoothPort.map { ", Bluetooth bridge 127.0.0.1:\($0)" } ?? "")")
        }

    case "erase":
        var d = device()
        let p = ProgressLine()
        try await DeviceStorage(library: library).erase(&d) { p.update($0, $1) }
        p.done()
        print("erased \(d.name)")

    case "delete":
        let d = device()
        if RuntimeRecord.live(at: library.paths(for: d).runtimeFile) != nil { fail("\(d.name) is running") }
        try library.deleteDevice(d.id)
        print("deleted \(d.name)")

    case "boot":
        var d = device()
        if args.flags.contains("no-shell") { d.options.shell = false; try library.saveDevice(d) }
        let s = DeviceSession(deviceID: d.id, library: library)
        if await s.attachIfRunning() { fail("\(d.name) is already running") }
        try await s.start()
        print("started \(d.name): pid \(s.pid ?? 0)\(s.bluetoothPort.map { ", Bluetooth bridge 127.0.0.1:\($0)" } ?? "")")
        if d.options.shell {
            for _ in 0..<1200 {
                if case .injecting = s.shell { try await Task.sleep(nanoseconds: 100_000_000) } else { break }
            }
            switch s.shell {
            case .ready(let pid): print("shell: nsh pid \(pid)")
            case .failed(let m): print("shell: failed: \(m)")
            default: print("shell: \(s.shell)")
            }
        }

    case "shutdown":
        let d = device()
        let s = await session(for: d, library)
        guard s.state.isActive else { fail("\(d.name) is not running") }
        await s.shutdown()
        print("shut down \(d.name)")

    case "screenshot":
        let d = device()
        guard args.positional.count > 1 else { fail("missing FILE") }
        let s = await session(for: d, library)
        guard s.state.isActive else { fail("\(d.name) is not running") }
        await waitForScreen(s)
        guard let png = s.screenshotPNG() else { fail("no screen") }
        try png.write(to: URL(fileURLWithPath: args.positional[1]))
        print("\(s.latestFrame.map { "\($0.width)x\($0.height)" } ?? "") -> \(args.positional[1])")

    case "tap", "swipe":
        let d = device()
        let n = args.positional.dropFirst().compactMap(Double.init)
        let s = await session(for: d, library)
        guard s.state.isActive else { fail("\(d.name) is not running") }
        await waitForScreen(s)
        if cmd == "tap" {
            guard n.count >= 2 else { fail("tap DEVICE X Y") }
            s.touch(x: Int(n[0]), y: Int(n[1]), down: true)
            try await Task.sleep(nanoseconds: 100_000_000)
            s.touch(x: Int(n[0]), y: Int(n[1]), down: false)
        } else {
            guard n.count >= 4 else { fail("swipe DEVICE X0 Y0 X1 Y1 [MS]") }
            let ms = n.count > 4 ? n[4] : 300
            let steps = 12
            s.touch(x: Int(n[0]), y: Int(n[1]), down: true)
            for i in 1...steps {
                try await Task.sleep(nanoseconds: UInt64(ms / Double(steps) * 1e6))
                let t = Double(i) / Double(steps)
                s.touch(x: Int(n[0] + (n[2] - n[0]) * t), y: Int(n[1] + (n[3] - n[1]) * t), down: true)
            }
            s.touch(x: Int(n[2]), y: Int(n[3]), down: false)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

    case "button":
        let d = device()
        guard args.positional.count > 1 else { fail("missing QCODE") }
        let s = await session(for: d, library)
        guard s.state.isActive else { fail("\(d.name) is not running") }
        await s.press(args.positional[1], duration: Double(args.value("hold") ?? "0.12") ?? 0.12)

    case "sh":
        let d = device()
        let command = args.positional.dropFirst().joined(separator: " ")
        guard !command.isEmpty else { fail("missing COMMAND") }
        let s = await session(for: d, library)
        guard s.state.isActive else { fail("\(d.name) is not running") }
        guard s.consoleConnected else { fail("the console is in use (Mirage holds it?)") }
        let out = try await s.execute(command, timeout: Double(args.value("timeout") ?? "15") ?? 15)
        print(out)

    case "console":
        let d = device()
        let paths = library.paths(for: d)
        guard RuntimeRecord.live(at: paths.runtimeFile) != nil else { fail("\(d.name) is not running") }
        let c = try await ConsoleConnection.connect(path: paths.consoleSocket.path, timeout: 3)
        var old = termios()
        tcgetattr(0, &old)
        var raw = old
        cfmakeraw(&raw)
        tcsetattr(0, TCSANOW, &raw)
        print("connected to \(d.name), Ctrl-] quits\r")
        let saved = old
        c.start(onData: { FileHandle.standardOutput.write($0) }, onClose: {
            var o = saved
            tcsetattr(0, TCSANOW, &o)
            exit(0)
        })
        while true {
            var buf = [UInt8](repeating: 0, count: 256)
            let n = read(0, &buf, buf.count)
            if n <= 0 { break }
            let chunk = Data(buf.prefix(n))
            if chunk.contains(0x1D) { break }
            c.send(chunk)
        }
        tcsetattr(0, TCSANOW, &old)
        print()

    case "image":
        func profileArg(_ args: Args) -> DeviceProfile {
            guard let id = args.value("profile") else { return DeviceProfile.p67 }
            guard let p = DeviceProfile.builtins.first(where: { $0.id == id }) else { fail("unknown profile \(id)") }
            return p
        }
        let sub = args.positional.first ?? ""
        let pos = Array(args.positional.dropFirst())
        switch sub {
        case "nor":
            guard let out = pos.first, let size = args.value("size").flatMap({ Int($0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0, radix: $0.hasPrefix("0x") ? 16 : 10) }) else {
                fail("image nor OUT --size BYTES --part main|sensor")
            }
            let part = args.value("part") == "sensor" ? DeviceProfile.q63.storage.factory : profileArg(args).storage.factory
            let url = URL(fileURLWithPath: out)
            try ImageBuilder.createErasedNOR(at: url, size: size)
            var props: [FactoryIdentity.Property] = [
                .init(key: "ro.factory.did", value: args.value("did") ?? "1503000001"),
                .init(key: "ro.factory.psn", value: args.value("psn") ?? "QEMU15030000000001"),
                .init(key: "ro.factory.mac_bt", value: (args.value("mac") ?? "C0:FF:EE:15:03:01").uppercased()),
            ]
            for kv in args.options["prop"] ?? [] {
                let parts = kv.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { fail("--prop KEY=VALUE") }
                props.append(.init(key: String(parts[0]), value: String(parts[1])))
            }
            try ImageBuilder.writeFactory(into: url, part: part, properties: props)
            print("\(out): factory.prop at 0x\(String(part.offset, radix: 16))")
        case "nand":
            guard let out = pos.first else { fail("image nand OUT [--profile ID] (--resource FILE | --system DIR)") }
            let profile = profileArg(args)
            guard let spec = profile.storage.nand else { fail("\(profile.id) has no NAND") }
            let p = ProgressLine()
            try ImageBuilder.buildNAND(at: URL(fileURLWithPath: out), spec: spec,
                                       resource: args.value("resource").map { URL(fileURLWithPath: $0) },
                                       systemDir: args.value("system").map { URL(fileURLWithPath: $0) }) { p.update($0, $1) }
            p.done()
        case "emmc":
            guard pos.count >= 2 else { fail("image emmc OUT FIRMWARE_DIR") }
            let p = ProgressLine()
            try ImageBuilder.buildEMMC(at: URL(fileURLWithPath: pos[0]), spec: DeviceProfile.q63.storage.emmc!,
                                       firmwareDirectory: URL(fileURLWithPath: pos[1])) { p.update($0, $1) }
            p.done()
        case "gpt":
            guard let f = pos.first else { fail("image gpt FILE") }
            for part in try ImageBuilder.readGPT(URL(fileURLWithPath: f)) {
                print(String(format: "%-12@ 0x%09lx %6d MiB", part.name as NSString, part.offset, part.size >> 20))
            }
        default:
            fail("unknown image command \(sub)")
        }

    default:
        fail("unknown command \(cmd)\n\(usage)")
    }
}

@main
struct MirageCTL {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            fail(error.localizedDescription)
        }
        exit(0)
    }
}
