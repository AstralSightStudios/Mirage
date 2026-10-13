import Foundation
import MirageKit
import Observation

/// Library state shared by every window: devices, firmware, profiles,
/// running sessions and background jobs.
@MainActor
@Observable
final class AppModel {
    private(set) var library: MirageLibrary
    private(set) var devices: [VirtualDevice] = []
    private(set) var firmwares: [Firmware] = []
    private(set) var profiles: [DeviceProfile] = []
    private(set) var sessions: [UUID: DeviceSession] = [:]
    /// Image builds and firmware switches in progress, by device.
    private(set) var deviceJobs: [UUID: Job] = [:]
    var selection: UUID?
    var alert: AlertItem?
    var showNewDevice = false
    var newDeviceFirmware: String?

    let archive: ArchiveModel
    let astrobox = AstroBoxService()
    /// The multi-device canvas.
    let workspace = WorkspaceModel()

    struct Job: Equatable {
        var title: String
        var progress: Double
        var detail: String
    }

    struct AlertItem: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    init() {
        let lib = (try? MirageLibrary.shared()) ?? (try! MirageLibrary(root: MirageLibrary.defaultRoot))
        library = lib
        archive = ArchiveModel(library: lib)
        reload()
        archive.model = self
        workspace.app = self
        workspace.load(libraryRoot: lib.root)
        Task { await attachRunning() }
    }

    func reload() {
        devices = library.devices()
        firmwares = library.firmwares()
        profiles = library.profiles()
        if let s = selection, !devices.contains(where: { $0.id == s }) { selection = nil }
        if selection == nil { selection = devices.first?.id }
        workspace.prune()
    }

    /// Switches to another library folder.
    func setLibraryRoot(_ url: URL) {
        MirageLibrary.setConfiguredRoot(url)
        guard sessions.values.allSatisfy({ !$0.state.isActive }) else {
            report("Shut down all devices first", "Running devices keep their images in the current library.")
            return
        }
        do {
            library = try MirageLibrary(root: url)
            archive.library = library
            sessions = [:]
            workspace.load(libraryRoot: url)
            reload()
            Task { await attachRunning() }
        } catch {
            report("Cannot use this folder", error.localizedDescription)
        }
    }

    func report(_ title: String, _ message: String) {
        alert = AlertItem(title: title, message: message)
    }

    func report(_ error: Error, _ title: String = "Something went wrong") {
        if let e = error as? MirageError, e == .cancelled { return }
        if error is CancellationError { return }
        report(title, error.localizedDescription)
    }

    // MARK: Lookups

    func device(_ id: UUID?) -> VirtualDevice? {
        guard let id else { return nil }
        return devices.first { $0.id == id }
    }

    func profile(_ id: String) -> DeviceProfile? {
        profiles.first { $0.id == id }
    }

    func firmware(_ id: String) -> Firmware? {
        firmwares.first { $0.id == id }
    }

    func session(_ id: UUID) -> DeviceSession {
        if let s = sessions[id] { return s }
        let s = DeviceSession(deviceID: id, library: library)
        sessions[id] = s
        return s
    }

    func state(of id: UUID) -> DeviceSession.State {
        sessions[id]?.state ?? .stopped
    }

    var runningCount: Int { sessions.values.filter { $0.state.isActive }.count }

    private func attachRunning() async {
        for d in devices {
            let paths = library.paths(for: d)
            if RuntimeRecord.live(at: paths.runtimeFile) != nil {
                await session(d.id).attachIfRunning()
            }
        }
    }

    // MARK: Device lifecycle

    func boot(_ id: UUID) {
        guard deviceJobs[id] == nil else { return }
        if workspace.autoAdd { workspace.add(id) }
        let s = session(id)
        Task {
            do {
                try await s.start()
            } catch {
                report(error, "Couldn’t boot \(device(id)?.name ?? "the device")")
            }
            reload()
        }
    }

    func shutdown(_ id: UUID) {
        guard let s = sessions[id] else { return }
        Task {
            await s.shutdown()
            for _ in 0..<50 where s.state != .stopped {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // binding / identity edits made while it ran
            applyPendingFactory(id)
        }
    }

    func restart(_ id: UUID) {
        let s = session(id)
        Task {
            do { try await s.restart() } catch { report(error, "Couldn’t restart the device") }
        }
    }

    func shutdownAll() async {
        await withTaskGroup(of: Void.self) { group in
            for s in sessions.values where s.state.isActive {
                group.addTask { await s.shutdown() }
            }
        }
    }

    // MARK: Device management

    func createDevice(name: String, firmware: Firmware, profile: DeviceProfile, binding: BindInfo,
                      options: RuntimeOptions, identity: FactoryIdentity?) {
        do {
            var d = try library.makeDevice(name: name.isEmpty ? nil : name, firmware: firmware, profile: profile,
                                           binding: binding, options: options)
            if let identity { d.identity = identity }
            try d.identity.validate()
            try d.binding.validate()
            try library.saveDevice(d)
            reload()
            selection = d.id
            runJob(d.id, "Building storage") { storage, progress in
                var dev = d
                try await storage.provision(&dev, progress: progress)
            } onFailure: { [weak self] in
                try? self?.library.deleteDevice(d.id)
            }
        } catch {
            report(error, "Couldn’t create the device")
        }
    }

    func eraseDevice(_ id: UUID) {
        guard var d = device(id) else { return }
        runJob(id, "Erasing") { storage, progress in
            try await storage.erase(&d, progress: progress)
        }
    }

    func switchFirmware(_ id: UUID, to fw: Firmware) {
        guard var d = device(id) else { return }
        runJob(id, "Installing \(fw.version)") { [weak self] storage, progress in
            let kept = try await storage.switchFirmware(&d, to: fw, progress: progress)
            if !kept {
                await MainActor.run {
                    self?.report("Storage rebuilt", "The new firmware’s partitions did not fit the old layout, so the device was erased.")
                }
            }
        }
    }

    func duplicateDevice(_ id: UUID) {
        guard let d = device(id) else { return }
        do {
            let copy = try DeviceStorage(library: library).duplicate(d, name: d.name + " Copy")
            reload()
            selection = copy.id
        } catch {
            report(error, "Couldn’t duplicate the device")
        }
    }

    func deleteDevice(_ id: UUID) {
        if state(of: id).isActive {
            report("Shut down the device first", "")
            return
        }
        do {
            try library.deleteDevice(id)
            sessions[id] = nil
            reload()
        } catch {
            report(error, "Couldn’t delete the device")
        }
    }

    /// Saves edits to a device; factory data is rewritten when it changed.
    func update(_ device: VirtualDevice, rewriteFactory: Bool = false) {
        do {
            var d = device
            try library.saveDevice(d)
            if rewriteFactory {
                if state(of: d.id).isActive {
                    report("Saved for the next boot", "The factory data is written once the device is shut down.")
                } else {
                    try DeviceStorage(library: library).rewriteFactory(&d)
                }
            }
            reload()
        } catch {
            report(error, "Couldn’t save the device")
        }
    }

    /// Applies pending factory data to devices that are shut down.
    func applyPendingFactory(_ id: UUID) {
        guard var d = device(id), !state(of: id).isActive else { return }
        let want = ImageBuilder.factoryProperties(identity: d.identity, binding: d.binding)
        guard want != d.storage.factoryProperties else { return }
        do {
            try DeviceStorage(library: library).rewriteFactory(&d)
            reload()
        } catch {
            report(error, "Couldn’t write the factory data")
        }
    }

    private func runJob(_ id: UUID, _ title: String,
                        _ body: @escaping (DeviceStorage, @escaping ImageBuilder.Progress) async throws -> Void,
                        onFailure: (() -> Void)? = nil) {
        guard deviceJobs[id] == nil else { return }
        if state(of: id).isActive {
            report("Shut down the device first", "Its storage is in use.")
            return
        }
        deviceJobs[id] = Job(title: title, progress: 0, detail: "")
        let storage = DeviceStorage(library: library)
        let progress: ImageBuilder.Progress = { [weak self] fraction, detail in
            Task { @MainActor in
                guard let self, self.deviceJobs[id] != nil else { return }
                self.deviceJobs[id]?.progress = fraction
                self.deviceJobs[id]?.detail = detail
            }
        }
        Task {
            do {
                try await body(storage, progress)
            } catch {
                onFailure?()
                report(error, "\(title) failed")
            }
            deviceJobs[id] = nil
            reload()
        }
    }

    // MARK: Firmware

    func importFirmware(at url: URL) {
        archive.importLocal(url)
    }

    func deleteFirmware(_ id: String) {
        do {
            try library.deleteFirmware(id)
            reload()
        } catch {
            report(error, "Couldn’t remove the firmware")
        }
    }

    func newDevice(with firmware: Firmware? = nil) {
        newDeviceFirmware = firmware?.id
        showNewDevice = true
    }

    // MARK: Profiles

    func saveProfile(_ p: DeviceProfile) {
        do {
            try library.saveProfile(p)
            reload()
        } catch {
            report(error, "Couldn’t save the profile")
        }
    }

    func deleteProfile(_ id: String) {
        if let user = devices.first(where: { $0.profileID == id }) {
            report("Profile in use", "“\(user.name)” uses this profile.")
            return
        }
        try? library.deleteProfile(id)
        reload()
    }
}
