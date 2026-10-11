import Foundation
import MirageKit
import Observation

/// AstroBox core, linked in as a Rust static library (AstroBoxBridge/),
/// talking to the emulated band over its Bluetooth bridge: device info,
/// watchfaces and quick apps without a phone.
///
/// The bridge is process-wide, so one device is connected at a time.
@MainActor
@Observable
final class AstroBoxService {
    enum State: Equatable {
        case unavailable
        case idle
        case connecting
        case connected
    }

    struct DeviceInfo: Equatable {
        var name = ""
        var address = ""
        var serialNumber = ""
        var firmwareVersion = ""
        var model = ""
        var productDevice = ""
        var battery: Int?
    }

    struct Watchface: Identifiable, Hashable {
        var id: String
        var name: String
        var current: Bool
        var canRemove: Bool
    }

    struct QuickApp: Identifiable, Hashable {
        var id: String { packageName }
        var packageName: String
        var name: String
        var version: String
    }

    struct Install: Identifiable, Equatable {
        let id: UInt64
        var file: String
        var progress: Double
        var message: String
    }

    private(set) var state: State
    private(set) var deviceID: UUID?
    private(set) var info: DeviceInfo?
    private(set) var watchfaces: [Watchface] = []
    private(set) var quickApps: [QuickApp] = []
    private(set) var installs: [Install] = []
    private(set) var log: [String] = []
    private(set) var lastError: String?
    private(set) var loadingApps = false

    @ObservationIgnored private var pending: [UInt64: CheckedContinuation<Any, Error>] = [:]

    init() {
        state = AstroBoxFFI.available ? .idle : .unavailable
        AstroBoxFFI.shared.handler = { [weak self] message in
            Task { @MainActor in self?.receive(message) }
        }
    }

    var isAvailable: Bool { state != .unavailable }

    func isConnected(_ id: UUID) -> Bool { deviceID == id && state == .connected }

    // MARK: Requests

    private func call(_ method: String, _ params: [String: Any] = [:], onStart: ((UInt64) -> Void)? = nil) async throws -> Any {
        guard AstroBoxFFI.available else {
            throw MirageError.process("This Mirage build doesn’t include AstroBox core (build it with make astrobox).")
        }
        let data = try JSONSerialization.data(withJSONObject: params)
        let json = String(decoding: data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { cont in
            let id = AstroBoxFFI.shared.call(method, json)
            pending[id] = cont
            onStart?(id)
        }
    }

    private func receive(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "result":
            guard let id = (msg["id"] as? NSNumber)?.uint64Value, let cont = pending.removeValue(forKey: id) else { return }
            if msg["ok"] as? Bool == true {
                cont.resume(returning: msg["result"] ?? NSNull())
            } else {
                cont.resume(throwing: MirageError.process(msg["error"] as? String ?? "AstroBox error"))
            }
        case "progress":
            guard let id = (msg["id"] as? NSNumber)?.uint64Value, let i = installs.firstIndex(where: { $0.id == id }) else { return }
            installs[i].progress = (msg["progress"] as? Double) ?? installs[i].progress
            if let m = msg["message"] as? String { installs[i].message = m }
        case "state":
            switch msg["state"] as? String {
            case "connected": state = .connected
            case "attaching", "connecting": state = .connecting
            default:
                if state == .connected { lastError = "The band disconnected" }
                state = .idle
                info = nil
            }
        case "log":
            let line = "[\(msg["level"] as? String ?? "info")] \(msg["message"] as? String ?? "")"
            log.append(line)
            if log.count > 2000 { log.removeFirst(log.count - 1500) }
        default:
            break
        }
    }

    // MARK: Connection

    func connect(device: VirtualDevice, port: Int, stateDirectory: URL) async {
        guard isAvailable else { return }
        if state == .connected || state == .connecting { await disconnect() }
        lastError = nil
        deviceID = device.id
        state = .connecting
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        do {
            let r = try await call("connect", ["host": "127.0.0.1", "port": port, "authKey": device.binding.authKey,
                                               "stateDir": stateDirectory.path, "timeoutSecs": 180])
            info = Self.parseInfo(r)
            state = .connected
            await refreshApps()
        } catch {
            lastError = error.localizedDescription
            state = .idle
        }
    }

    func disconnect() async {
        _ = try? await call("disconnect")
        state = isAvailable ? .idle : .unavailable
        info = nil
        watchfaces = []
        quickApps = []
    }

    func refreshInfo() async {
        if let r = try? await call("deviceInfo") { info = Self.parseInfo(r) }
    }

    func refreshApps() async {
        guard state == .connected else { return }
        loadingApps = true
        defer { loadingApps = false }
        do {
            let w = try await call("watchfaces") as? [[String: Any]] ?? []
            watchfaces = w.map {
                Watchface(id: Self.string($0["id"]), name: Self.string($0["name"]).isEmpty ? Self.string($0["id"]) : Self.string($0["name"]),
                          current: $0["current"] as? Bool ?? false, canRemove: $0["canRemove"] as? Bool ?? true)
            }
        } catch {
            lastError = error.localizedDescription
        }
        do {
            let q = try await call("quickApps") as? [[String: Any]] ?? []
            quickApps = q.map {
                QuickApp(packageName: Self.string($0["packageName"]), name: Self.string($0["name"]), version: Self.string($0["version"]))
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Apps

    enum Kind: String {
        case watchface, quickapp

        static func of(_ url: URL) -> Kind? {
            switch url.pathExtension.lowercased() {
            case "rpk": return .quickapp
            case "bin", "mwz", "face", "zip": return .watchface
            default: return nil
            }
        }
    }

    func install(_ url: URL, kind: Kind) async {
        var installID: UInt64 = 0
        do {
            _ = try await call("install", ["path": url.path, "kind": kind.rawValue]) { [weak self] id in
                installID = id
                self?.installs.append(Install(id: id, file: url.lastPathComponent, progress: 0, message: "Starting…"))
            }
            installs.removeAll { $0.id == installID }
            await refreshApps()
        } catch {
            installs.removeAll { $0.id == installID }
            lastError = "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func setWatchface(_ id: String) async {
        await perform("setWatchface", ["id": id])
    }

    func removeWatchface(_ id: String) async {
        await perform("removeWatchface", ["id": id])
    }

    func launch(_ app: QuickApp) async {
        do { _ = try await call("launchQuickApp", ["packageName": app.packageName]) } catch { lastError = error.localizedDescription }
    }

    func remove(_ app: QuickApp) async {
        await perform("removeQuickApp", ["packageName": app.packageName])
    }

    private func perform(_ method: String, _ params: [String: Any]) async {
        do {
            _ = try await call(method, params)
            await refreshApps()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Parsing

    static func string(_ v: Any?) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }

    static func parseInfo(_ v: Any) -> DeviceInfo {
        let d = v as? [String: Any] ?? [:]
        var battery: Int?
        if let b = d["battery"] as? NSNumber { battery = b.intValue }
        if let b = d["battery"] as? [String: Any], let c = b["capacity"] as? NSNumber { battery = c.intValue }
        return DeviceInfo(name: string(d["name"]), address: string(d["addr"]), serialNumber: string(d["serialNumber"]),
                          firmwareVersion: string(d["firmwareVersion"]), model: string(d["model"]),
                          productDevice: string(d["productDevice"]), battery: battery)
    }
}

/// The C ABI of libmirage_astrobox (AstroBoxBridge/include/mirage_astrobox.h).
final class AstroBoxFFI: @unchecked Sendable {
    static let shared = AstroBoxFFI()
    var handler: (([String: Any]) -> Void)?

    #if MIRAGE_ASTROBOX
    static let available = true

    private init() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        mab_init({ json, ctx in
            guard let json, let ctx else { return }
            let me = Unmanaged<AstroBoxFFI>.fromOpaque(ctx).takeUnretainedValue()
            let data = Data(bytes: json, count: strlen(json))
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                me.handler?(obj)
            }
        }, ctx)
    }

    func call(_ method: String, _ params: String) -> UInt64 {
        mab_call(method, params)
    }
    #else
    static let available = false

    private init() {}

    func call(_ method: String, _ params: String) -> UInt64 { 0 }
    #endif
}
