import Foundation
import MirageKit
import Observation

/// State of one Files window: which file system of the device is open,
/// where in it, and what is going on.
///
/// A running device is browsed live through its NSH shell; a shut-down one
/// through its storage images (data partitions read-write, romfs read-only).
@MainActor
@Observable
final class FileBrowser {
    enum Source: Hashable, Identifiable {
        case live
        case volume(DeviceVolume)
        /// A romfs .bin file opened from another file system.
        case image(String)

        var id: String {
            switch self {
            case .live: return "live"
            case .volume(let v): return "volume:" + v.name
            case .image(let name): return "image:" + name
            }
        }
    }

    struct Busy {
        var title: String
        var progress: Double?
    }

    let deviceID: UUID
    private let model: AppModel

    private(set) var live = false
    private(set) var volumes: [DeviceVolume] = []
    private(set) var imageNames: [String] = []
    private(set) var source: Source?
    private(set) var path = "/"
    private(set) var entries: [GuestEntry] = []
    private(set) var loading = false
    private(set) var busy: Busy?
    private(set) var notice: String?
    var selection = Set<GuestEntry.ID>()
    /// Opens a downloaded copy of a file with the platform's default app.
    @ObservationIgnored var openFile: ((URL) -> Void)?

    @ObservationIgnored private var fs: GuestFileSystem?
    @ObservationIgnored private var shell: ShellFileSystem?
    @ObservationIgnored private var images: [String: RomFSVolume] = [:]
    @ObservationIgnored private var back: [(Source, String)] = []

    init(deviceID: UUID, model: AppModel) {
        self.deviceID = deviceID
        self.model = model
    }

    var device: VirtualDevice? { model.device(deviceID) }
    var canWrite: Bool { fs.map { !$0.isReadOnly } ?? false }
    var canGoBack: Bool { !back.isEmpty }
    var replaceableVolume: DeviceVolume? {
        if case .volume(let v) = source, v.replaceable { return v }
        return nil
    }

    var selectedEntries: [GuestEntry] { entries.filter { selection.contains($0.id) } }

    // MARK: Sources

    /// Picks live or offline access from the device's state.
    func reloadSources() async {
        guard let device, let profile = model.profile(device.profileID) else { return }
        let session = model.session(deviceID)
        fs = nil
        shell = nil
        entries = []
        selection = []
        back = []
        notice = nil
        if session.state.isActive {
            live = true
            volumes = []
            guard device.options.shell else {
                source = nil
                notice = "The shell is off for this device. Turn it on in Device Settings and restart to browse its files while it runs, or shut it down to open its storage images."
                return
            }
            guard case .ready = session.shell else {
                source = nil
                notice = "Waiting for the device's shell…"
                return
            }
            let shell = ShellFileSystem(session: session, unstatable: DeviceFiles.unstatableDirectories(profile: profile))
            loading = true
            defer { loading = false }
            do {
                try await shell.connect()
            } catch {
                source = nil
                notice = "This firmware has no console to run commands on, so its files can only be opened while the device is shut down."
                return
            }
            self.shell = shell
            await open(.live, path: "/")
        } else {
            live = false
            volumes = DeviceFiles.volumes(of: device, profile: profile, library: model.library)
            if case .image(let name)? = source, images[name] != nil {
                await open(.image(name), path: "/")
            } else if let first = volumes.first(where: { $0.mountPoint == "/data" }) ?? volumes.first {
                await open(.volume(first), path: "/")
            } else {
                source = nil
                notice = "The device has no storage images yet."
            }
        }
    }

    private func fileSystem(for source: Source) throws -> GuestFileSystem {
        switch source {
        case .live:
            guard let shell else { throw MirageError.process("The device is not running") }
            return shell
        case .volume(let v):
            guard let device, let profile = model.profile(device.profileID) else { throw MirageError.notFound("No profile") }
            guard !model.session(deviceID).state.isActive else {
                throw MirageError.invalid("Shut the device down to open its storage images")
            }
            return try DeviceFiles.open(v, profile: profile)
        case .image(let name):
            guard let image = images[name] else { throw MirageError.notFound(name) }
            return image
        }
    }

    func select(_ source: Source) async {
        guard source != self.source else { return }
        await open(source, path: "/")
    }

    private func open(_ source: Source, path: String, remember: Bool = false) async {
        if remember, let current = self.source { back.append((current, self.path)) }
        do {
            if source != self.source || fs == nil {
                fs = try fileSystem(for: source)
            }
            self.source = source
            self.path = path
            await refresh()
        } catch {
            self.source = source
            fs = nil
            entries = []
            notice = error.localizedDescription
        }
    }

    // MARK: Navigation

    func refresh() async {
        guard let fs else { return }
        loading = true
        defer { loading = false }
        do {
            let list = try await fs.list(path)
            entries = list.sorted {
                $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            selection = selection.filter { id in entries.contains { $0.id == id } }
            if source != .live || notice?.hasPrefix("Waiting") == true { notice = nil }
        } catch {
            entries = []
            report(error)
        }
    }

    func go(to path: String) async {
        guard let source else { return }
        await open(source, path: path, remember: true)
    }

    func goUp() async {
        guard path != "/" else { return }
        await go(to: GuestPath.parent(path))
    }

    func goBack() async {
        guard let (source, path) = back.popLast() else { return }
        await open(source, path: path)
    }

    /// Path components with the path each one leads to.
    var crumbs: [(name: String, path: String)] {
        var out: [(String, String)] = [("/", "/")]
        var p = ""
        for part in GuestPath.components(path) {
            p += "/" + part
            out.append((part, p))
        }
        return out
    }

    // MARK: Operations

    private func report(_ error: Error) {
        model.report(error, "File operation failed")
    }

    private func run(_ title: String, _ op: @escaping (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Void) async {
        busy = Busy(title: title, progress: nil)
        defer { busy = nil }
        let progress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.busy?.progress = value }
        }
        do {
            try await op(progress)
        } catch {
            report(error)
        }
        await refresh()
    }

    func open(_ entry: GuestEntry) async {
        if entry.isDirectory {
            await go(to: entry.path)
            return
        }
        guard let fs else { return }
        await run("Opening \(entry.name)") { progress in
            let data = try await fs.read(entry.path, progress: progress)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Mirage Files/\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(entry.name)
            try data.write(to: url)
            await MainActor.run { self.openFile?(url) }
        }
    }

    /// Opens a romfs image file (e.g. /system/app.bin on a band) as a volume.
    func browseImage(_ entry: GuestEntry) async {
        guard let fs else { return }
        busy = Busy(title: "Reading \(entry.name)", progress: nil)
        do {
            let data = try await fs.read(entry.path) { [weak self] value in
                Task { @MainActor in self?.busy?.progress = value }
            }
            let image = try RomFSVolume(data: data)
            let name = entry.name
            images[name] = image
            if !imageNames.contains(name) { imageNames.append(name) }
            busy = nil
            await open(.image(name), path: "/", remember: true)
        } catch {
            busy = nil
            report(error)
        }
    }

    func closeImage(_ name: String) async {
        images[name] = nil
        imageNames.removeAll { $0 == name }
        if source == .image(name) { await reloadSources() }
    }

    func upload(_ urls: [URL]) async {
        guard let fs, canWrite else { return }
        let target = path
        await run(urls.count == 1 ? "Copying \(urls[0].lastPathComponent)" : "Copying \(urls.count) items") { progress in
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try await Self.copyIn(url, to: GuestPath.join(target, url.lastPathComponent), fs: fs, progress: progress)
            }
        }
    }

    private nonisolated static func copyIn(_ url: URL, to path: String, fs: GuestFileSystem,
                                           progress: @escaping @Sendable (Double) -> Void) async throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            try? await fs.createDirectory(path)
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for child in children where !child.lastPathComponent.hasPrefix(".") {
                try await copyIn(child, to: GuestPath.join(path, child.lastPathComponent), fs: fs, progress: progress)
            }
        } else {
            try await fs.write(path, data: try Data(contentsOf: url), progress: progress)
        }
    }

    func download(_ entries: [GuestEntry], to folder: URL) async {
        guard let fs else { return }
        await run(entries.count == 1 ? "Saving \(entries[0].name)" : "Saving \(entries.count) items") { progress in
            for e in entries {
                try await Self.copyOut(e, to: folder.appendingPathComponent(e.name), fs: fs, progress: progress)
            }
        }
    }

    /// Saves one file under the name a save dialog chose.
    func save(_ entry: GuestEntry, as url: URL) async {
        guard let fs else { return }
        await run("Saving \(entry.name)") { progress in
            try await fs.read(entry.path, progress: progress).write(to: url)
        }
    }

    private nonisolated static func copyOut(_ entry: GuestEntry, to url: URL, fs: GuestFileSystem,
                                            progress: @escaping @Sendable (Double) -> Void) async throws {
        if entry.isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for child in try await fs.list(entry.path) {
                try await copyOut(child, to: url.appendingPathComponent(child.name), fs: fs, progress: progress)
            }
        } else {
            try await fs.read(entry.path, progress: progress).write(to: url)
        }
    }

    func createFolder(_ name: String) async {
        guard let fs, !name.isEmpty else { return }
        let target = GuestPath.join(path, name)
        await run("Creating \(name)") { _ in try await fs.createDirectory(target) }
    }

    func rename(_ entry: GuestEntry, to name: String) async {
        guard let fs, !name.isEmpty, name != entry.name else { return }
        let target = GuestPath.join(GuestPath.parent(entry.path), name)
        await run("Renaming \(entry.name)") { _ in try await fs.rename(entry.path, to: target) }
    }

    func delete(_ entries: [GuestEntry]) async {
        guard let fs else { return }
        await run(entries.count == 1 ? "Deleting \(entries[0].name)" : "Deleting \(entries.count) items") { _ in
            for e in entries { try await fs.remove(e.path) }
        }
    }

    func replaceImage(with url: URL) async {
        guard let volume = replaceableVolume, let device, let profile = model.profile(device.profileID) else { return }
        await run("Writing \(url.lastPathComponent) to \(volume.title)") { _ in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try await Task.detached { try DeviceFiles.replaceImage(volume, with: url, profile: profile) }.value
        }
        fs = nil
        await open(.volume(volume), path: "/")
    }
}
