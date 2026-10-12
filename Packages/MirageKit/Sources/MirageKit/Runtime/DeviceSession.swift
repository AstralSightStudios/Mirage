import Foundation
import Observation
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// A running (or startable) emulator for one device: the QEMU process and
/// its QMP, VNC, console and gdbstub connections.
///
/// QEMU outlives the process that started it, so a session can attach to an
/// emulator that `miragectl` or an earlier Mirage started (runtime.json).
@MainActor
@Observable
public final class DeviceSession {
    public enum State: Equatable, Sendable {
        case stopped
        case launching
        case injectingShell
        case running
        case paused
        case stopping

        public var isActive: Bool { self != .stopped }

        public var title: String {
            switch self {
            case .stopped: return "Shut Down"
            case .launching: return "Starting"
            case .injectingShell: return "Booting"
            case .running: return "Booted"
            case .paused: return "Paused"
            case .stopping: return "Shutting Down"
            }
        }
    }

    public enum ShellStatus: Equatable, Sendable {
        case disabled
        case injecting
        case ready(pid: Int)
        case failed(String)
        case unavailable
    }

    public let deviceID: UUID
    public let library: MirageLibrary
    public private(set) var state: State = .stopped
    public private(set) var shell: ShellStatus = .disabled
    public private(set) var lastError: String?
    public private(set) var bluetoothPort: Int?
    public private(set) var startedAt: Date?
    public private(set) var pid: Int32?
    public private(set) var screenSize: CGSize?
    public private(set) var commandLine: String?
    public private(set) var exitStatus: Int32?
    public private(set) var consoleConnected = false

    @ObservationIgnored private var qmp: QMPClient?
    @ObservationIgnored private var vnc: VNCClient?
    @ObservationIgnored private var console: ConsoleConnection?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var exitWatch: HostProcess.ExitWatch?
    @ObservationIgnored private var endpoints: DeviceEndpoints?
    @ObservationIgnored private var bootTask: Task<Void, Never>?
    @ObservationIgnored public private(set) var consoleHistory = ByteRing(capacity: 2 << 20)
    @ObservationIgnored private var consoleObservers: [UUID: (Data) -> Void] = [:]
    @ObservationIgnored private var frameObservers: [UUID: (VNCClient.Frame) -> Void] = [:]
    @ObservationIgnored public private(set) var latestFrame: VNCClient.Frame?
    @ObservationIgnored private let frameMailbox = FrameMailbox()
    @ObservationIgnored private var userStopped = false

    static var nshPlans: [String: NSHInjector.Plan] = [:]

    public init(deviceID: UUID, library: MirageLibrary) {
        self.deviceID = deviceID
        self.library = library
    }

    public var device: VirtualDevice? { library.device(deviceID) }

    // MARK: Observers

    @discardableResult
    public func observeConsole(replay: Bool = true, _ handler: @escaping (Data) -> Void) -> UUID {
        let id = UUID()
        consoleObservers[id] = handler
        if replay, !consoleHistory.data.isEmpty { handler(consoleHistory.data) }
        return id
    }

    @discardableResult
    public func observeFrames(_ handler: @escaping (VNCClient.Frame) -> Void) -> UUID {
        let id = UUID()
        frameObservers[id] = handler
        if let f = latestFrame { handler(f) }
        return id
    }

    public func removeObserver(_ id: UUID) {
        consoleObservers[id] = nil
        frameObservers[id] = nil
    }

    // MARK: Lifecycle

    /// Boots the device. Returns once QEMU runs; the shell is injected and
    /// the screen attached in the background.
    public func start(qemu: URL? = nil) async throws {
        guard state == .stopped else { return }
        guard let device else { throw MirageError.notFound("Device not found") }
        guard let profile = library.profile(device.profileID) else {
            throw MirageError.notFound("Device profile \(device.profileID) does not exist")
        }
        guard let firmware = library.firmware(device.firmwareID) else {
            throw MirageError.notFound("Firmware \(device.firmwareID) is not in the library")
        }
        guard let qemuURL = qemu ?? QEMULocator.locate() else {
            throw MirageError.notFound("qemu-system-arm not found. Build the qemu-miwear submodule (make qemu) or choose a QEMU binary in Settings.")
        }
        lastError = nil
        exitStatus = nil
        userStopped = false
        state = .launching
        do {
            let plan = try LaunchPlan.make(device: device, profile: profile, firmware: firmware,
                                           library: library, qemu: qemuURL)
            try prepareDirectories(plan.paths)
            var nsh: NSHInjector.Plan?
            if plan.shell {
                shell = .injecting
                nsh = try? await nshPlan(for: firmware, image: plan.firmwareImage)
                if nsh == nil { shell = .unavailable }
            } else {
                shell = .disabled
            }
            try launch(plan)
            var d = device
            d.lastBootedAt = Date()
            if let port = plan.bluetoothPort { d.options.bluetoothPort = port }
            try? library.saveDevice(d)

            let q = try await connectQMP(plan)
            adoptQMP(q)
            if plan.shell {
                state = .injectingShell
                if let nsh {
                    bootTask = Task { [weak self] in await self?.injectShell(nsh, plan: plan) }
                } else {
                    _ = try? await q.execute("cont")
                    state = .running
                }
            } else {
                state = .running
            }
            await attachConsole(plan.endpoints)
            await attachScreen(plan.endpoints)
        } catch {
            lastError = error.localizedDescription
            if let p = process, p.isRunning { p.terminate() }
            if process == nil { state = .stopped }
            throw error
        }
    }

    private func nshPlan(for firmware: Firmware, image: URL) async throws -> NSHInjector.Plan {
        if let p = Self.nshPlans[firmware.id] { return p }
        // the analysis takes a while; keep it next to the firmware
        let cache = library.firmwareDirectory(firmware.id).appendingPathComponent("nsh-plan.json")
        if let d = try? Data(contentsOf: cache), let p = try? JSONDecoder().decode(NSHInjector.Plan.self, from: d) {
            Self.nshPlans[firmware.id] = p
            return p
        }
        let p = try await runBlocking { try NSHInjector.plan(firmware: image) }
        Self.nshPlans[firmware.id] = p
        try? JSONEncoder().encode(p).write(to: cache, options: .atomic)
        return p
    }

    /// Waits for QEMU's monitor; fails with QEMU's own message when it
    /// exits first (bad option, missing image, ...).
    private func connectQMP(_ plan: LaunchPlan) async throws -> QMPClient {
        let deadline = Date().addingTimeInterval(20)
        while true {
            if let q = try? await QMPClient.connect(plan.endpoints.qmp, timeout: 0.2) { return q }
            if process?.isRunning != true {
                try? await Task.sleep(nanoseconds: 200_000_000)
                let out = (try? String(contentsOf: plan.paths.stdoutLog, encoding: .utf8)) ?? ""
                let tail = out.split(separator: "\n").suffix(6).joined(separator: "\n")
                throw MirageError.process("QEMU exited during launch\(tail.isEmpty ? "" : ":\n" + tail)")
            }
            if Date() > deadline { throw MirageError.process("QEMU did not open its monitor socket") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func prepareDirectories(_ paths: DevicePaths) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: paths.runtime.path)) ?? [] where name.hasSuffix(".sock") {
            try? fm.removeItem(at: paths.runtime.appendingPathComponent(name))
        }
        // keep the previous boot's logs next to the new ones
        let previous = paths.logs.appendingPathComponent("Previous Boot", isDirectory: true)
        try? fm.removeItem(at: previous)
        try fm.createDirectory(at: previous, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: paths.logs.path)) ?? [] where name.hasSuffix(".log") {
            try? fm.moveItem(at: paths.logs.appendingPathComponent(name), to: previous.appendingPathComponent(name))
        }
        consoleHistory.clear()
    }

    private func launch(_ plan: LaunchPlan) throws {
        let p = Process()
        p.executableURL = plan.executable
        p.arguments = plan.arguments
        p.currentDirectoryURL = plan.workingDirectory
        FileManager.default.createFile(atPath: plan.paths.stdoutLog.path, contents: nil)
        let out = try FileHandle(forWritingTo: plan.paths.stdoutLog)
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try p.run()
        process = p
        pid = p.processIdentifier
        startedAt = Date()
        bluetoothPort = plan.bluetoothPort
        commandLine = plan.commandLine
        endpoints = plan.endpoints
        watchExit(pid: p.processIdentifier)
        let record = RuntimeRecord(pid: p.processIdentifier, qemu: plan.executable.path, startedAt: Date(),
                                   bluetoothPort: plan.bluetoothPort, shell: plan.shell, commandLine: plan.commandLine,
                                   endpoints: plan.endpoints)
        try? record.write(to: plan.paths.runtimeFile)
    }

    private func watchExit(pid: Int32) {
        exitWatch = HostProcess.watchExit(pid) { [weak self] in self?.processExited() }
    }

    private func processExited() {
        exitWatch?.cancel()
        exitWatch = nil
        if let p = process {
            p.waitUntilExit()
            exitStatus = p.terminationStatus
            if !userStopped, p.terminationStatus != 0 {
                lastError = "QEMU exited with status \(p.terminationStatus); see the device's Logs/stdout.log"
            }
        } else if !userStopped {
            lastError = "QEMU exited"
        }
        teardown()
    }

    private func teardown() {
        bootTask?.cancel()
        bootTask = nil
        qmp?.close()
        vnc?.close()
        console?.close()
        qmp = nil
        vnc = nil
        console = nil
        process = nil
        pid = nil
        endpoints = nil
        consoleConnected = false
        if let device {
            let paths = library.paths(for: device)
            try? FileManager.default.removeItem(at: paths.runtimeFile)
            try? FileManager.default.removeItem(at: paths.runtime)
        }
        if case .injecting = shell { shell = .unavailable }
        state = .stopped
    }

    /// Orderly shutdown (QEMU writes the NOR images back on exit).
    public func shutdown() async {
        guard state.isActive, let pid else { return }
        userStopped = true
        state = .stopping
        bootTask?.cancel()
        if let qmp {
            _ = try? await qmp.execute("quit")
        } else {
            HostProcess.terminate(pid)
        }
        for _ in 0..<100 where self.pid == pid {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !HostProcess.isAlive(pid) { break }
        }
        if HostProcess.isAlive(pid) {
            HostProcess.terminate(pid)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if HostProcess.isAlive(pid) { HostProcess.forceKill(pid) }
        }
        if process == nil && self.pid == pid {
            // attached session: no Process to report the exit
            teardown()
        }
    }

    public func forceQuit() {
        guard let pid else { return }
        userStopped = true
        HostProcess.forceKill(pid)
        if process == nil { teardown() }
    }

    public func restart() async throws {
        await shutdown()
        while state != .stopped { try await Task.sleep(nanoseconds: 100_000_000) }
        try await start()
    }

    public func pause() async {
        guard state == .running, let qmp else { return }
        if (try? await qmp.execute("stop")) != nil { state = .paused }
    }

    public func resume() async {
        guard state == .paused, let qmp else { return }
        if (try? await qmp.execute("cont")) != nil { state = .running }
    }

    // MARK: Attach

    /// Attaches to an emulator started elsewhere. Returns false when none
    /// runs for this device.
    @discardableResult
    public func attachIfRunning() async -> Bool {
        guard state == .stopped, let device else { return false }
        let paths = library.paths(for: device)
        guard let record = RuntimeRecord.read(from: paths.runtimeFile) else { return false }
        guard HostProcess.isAlive(record.pid), processPath(record.pid)?.contains("qemu") == true else {
            try? FileManager.default.removeItem(at: paths.runtimeFile)
            return false
        }
        pid = record.pid
        startedAt = record.startedAt
        bluetoothPort = record.bluetoothPort
        commandLine = record.commandLine
        shell = record.shell ? .unavailable : .disabled
        if let sp = record.shellPID { shell = .ready(pid: sp) }
        state = .running
        let endpoints = record.endpoints(paths)
        self.endpoints = endpoints
        watchExit(pid: record.pid)
        var q = try? await QMPClient.connect(endpoints.qmp, timeout: 1)
        if q == nil {
            q = try? await QMPClient.connect(endpoints.qmpAux, timeout: 1)
        }
        if let q {
            adoptQMP(q)
            if let s = try? await q.status(), !s.running { state = s.status == "paused" ? .paused : .running }
        }
        await attachConsole(endpoints)
        await attachScreen(endpoints)
        return true
    }

    private func adoptQMP(_ q: QMPClient) {
        qmp = q
        q.onEvent { [weak self] event, _ in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case "STOP": if self.state == .running { self.state = .paused }
                case "RESUME": if self.state == .paused { self.state = .running }
                default: break
                }
            }
        }
    }

    private func injectShell(_ nsh: NSHInjector.Plan, plan: LaunchPlan) async {
        do {
            let pid = try await NSHInjector.inject(plan: nsh, gdb: plan.endpoints.gdb)
            shell = .ready(pid: pid)
            if var record = RuntimeRecord.read(from: plan.paths.runtimeFile) {
                record.shellPID = pid
                try? record.write(to: plan.paths.runtimeFile)
            }
        } catch {
            shell = .failed(error.localizedDescription)
            _ = try? await qmp?.execute("cont")
        }
        if state == .injectingShell { state = .running }
    }

    private func attachConsole(_ endpoints: DeviceEndpoints) async {
        guard let c = try? await ConsoleConnection.connect(endpoints.console, timeout: 5) else { return }
        console = c
        consoleConnected = true
        c.start(onData: { [weak self] data in
            Task { @MainActor in self?.consoleReceived(data) }
        }, onClose: { [weak self] in
            Task { @MainActor in self?.consoleConnected = false }
        })
    }

    private func consoleReceived(_ data: Data) {
        consoleHistory.append(data)
        for h in consoleObservers.values { h(data) }
    }

    private func attachScreen(_ endpoints: DeviceEndpoints) async {
        guard let v = try? await VNCClient.connect(endpoints.vnc, timeout: 10) else { return }
        vnc = v
        let size = v.size
        screenSize = CGSize(width: size.width, height: size.height)
        let mailbox = frameMailbox
        v.onFrame { [weak self] frame in
            if mailbox.put(frame) {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let f = mailbox.take() else { return }
                        self.deliver(f)
                    }
                }
            }
        }
    }

    private func deliver(_ frame: VNCClient.Frame) {
        latestFrame = frame
        let size = CGSize(width: frame.width, height: frame.height)
        if screenSize != size { screenSize = size }
        for h in frameObservers.values { h(frame) }
    }

    // MARK: Input & output

    public func sendConsole(_ data: Data) {
        console?.send(data)
    }

    /// Runs an NSH command line (no output capture; it shows in the console).
    public func run(_ command: String) {
        console?.send(command + "\r")
    }

    /// Runs an NSH command and returns its output (up to the next prompt).
    public func execute(_ command: String, timeout: TimeInterval = 15) async throws -> String {
        guard case .ready = shell, console != nil else {
            throw MirageError.process("The shell is not running on this device")
        }
        var collected = Data()
        var done = false
        let token = observeConsole(replay: false) { data in
            collected.append(data)
            if let text = String(data: collected, encoding: .utf8) ?? String(data: collected, encoding: .isoLatin1),
               NSHOutput.isComplete(text, command: command) {
                done = true
            }
        }
        defer { removeObserver(token) }
        run(command)
        let deadline = Date().addingTimeInterval(timeout)
        while !done && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let text = String(decoding: collected, as: UTF8.self)
        guard done else { throw MirageError.process("Timed out waiting for the NSH prompt:\n\(NSHOutput.body(text, command: command))") }
        return NSHOutput.body(text, command: command)
    }

    /// Finger at panel pixel coordinates.
    public func touch(x: Int, y: Int, down: Bool) {
        vnc?.pointer(x: x, y: y, pressed: down)
    }

    public func button(_ qcode: String, down: Bool) async {
        try? await qmp?.key(qcode, down: down)
    }

    public func press(_ qcode: String, duration: TimeInterval = 0.12) async {
        await button(qcode, down: true)
        try? await Task.sleep(nanoseconds: UInt64(duration * 1e9))
        await button(qcode, down: false)
    }

    public func hmp(_ command: String) async throws -> String {
        guard let qmp else { throw MirageError.process("Not connected to QEMU") }
        return try await qmp.hmp(command)
    }

    /// The current screen as PNG.
    public func screenshotPNG() -> Data? {
        guard let frame = latestFrame ?? vnc?.snapshot(), frame.width > 0 else { return nil }
        #if canImport(CoreGraphics)
        guard let image = Self.cgImage(frame) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
        #else
        return PNGWriter.png(frame)
        #endif
    }

    #if canImport(CoreGraphics)
    private static let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

    public nonisolated static func cgImage(_ frame: VNCClient.Frame) -> CGImage? {
        guard frame.width > 0, frame.height > 0,
              let provider = CGDataProvider(data: frame.pixels as CFData) else { return nil }
        return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: frame.width * 4, space: rgbColorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    #endif
}

/// Holds the newest frame until the main thread takes it (frames that
/// arrive in between replace it).
final class FrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: VNCClient.Frame?

    /// True when the caller must schedule a take.
    func put(_ f: VNCClient.Frame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasEmpty = frame == nil
        frame = f
        return wasEmpty
    }

    func take() -> VNCClient.Frame? {
        lock.lock()
        defer { lock.unlock() }
        let f = frame
        frame = nil
        return f
    }
}

/// What a running emulator left behind for others to attach to.
public struct RuntimeRecord: Codable, Sendable {
    public var pid: Int32
    public var qemu: String
    public var startedAt: Date
    public var bluetoothPort: Int?
    public var shell: Bool
    public var shellPID: Int?
    public var commandLine: String
    /// Missing in records of Mirage versions that only used unix sockets.
    public var endpoints: DeviceEndpoints?

    public init(pid: Int32, qemu: String, startedAt: Date, bluetoothPort: Int?, shell: Bool,
                shellPID: Int? = nil, commandLine: String, endpoints: DeviceEndpoints?) {
        self.pid = pid
        self.qemu = qemu
        self.startedAt = startedAt
        self.bluetoothPort = bluetoothPort
        self.shell = shell
        self.shellPID = shellPID
        self.commandLine = commandLine
        self.endpoints = endpoints
    }

    public func endpoints(_ paths: DevicePaths) -> DeviceEndpoints {
        endpoints ?? .unix(paths)
    }

    public func write(to url: URL) throws {
        try MirageLibrary.encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) -> RuntimeRecord? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? MirageLibrary.decoder.decode(RuntimeRecord.self, from: d)
    }

    /// The record if its process still runs.
    public static func live(at url: URL) -> RuntimeRecord? {
        guard let r = read(from: url), HostProcess.isAlive(r.pid), processPath(r.pid)?.contains("qemu") == true else { return nil }
        return r
    }
}

func processPath(_ pid: Int32) -> String? {
    HostProcess.executablePath(pid)
}
