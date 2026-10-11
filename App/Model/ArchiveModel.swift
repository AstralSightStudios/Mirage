import Foundation
import MirageKit
import Observation

/// The MiWear Firmware Archives browser: releases from GitHub, downloads
/// and imports into the firmware library.
@MainActor
@Observable
final class ArchiveModel {
    var library: MirageLibrary
    weak var model: AppModel?

    private(set) var releases: [ArchiveRelease] = []
    private(set) var fetchedAt: Date?
    private(set) var loading = false
    private(set) var error: String?
    /// Downloads and imports in progress, by asset ID (or import path).
    private(set) var transfers: [String: Transfer] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    struct Transfer: Equatable {
        var phase: Phase
        var progress: Double
        var detail: String

        enum Phase: Equatable { case downloading, importing }
    }

    init(library: MirageLibrary) {
        self.library = library
        if let c = FirmwareArchiveClient(library: library).cached() {
            releases = c.releases
            fetchedAt = c.fetchedAt
        }
    }

    /// Products in the archive, newest release first.
    var products: [String] {
        var seen = Set<String>()
        return releases.compactMap { seen.insert($0.product).inserted ? $0.product : nil }
    }

    func releases(of product: String) -> [ArchiveRelease] {
        releases.filter { $0.product == product }.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func isEmulatable(_ product: String) -> Bool {
        (model?.profiles ?? DeviceProfile.builtins).contains { $0.runs(product: product) }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        error = nil
        Task {
            do {
                releases = try await FirmwareArchiveClient(library: library).fetch()
                fetchedAt = Date()
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    func refreshIfStale() {
        if fetchedAt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true { refresh() }
    }

    func transfer(for asset: ArchiveAsset) -> Transfer? {
        transfers[String(asset.id)]
    }

    func installed(_ asset: ArchiveAsset) -> Firmware? {
        model?.firmwares.first { $0.id == asset.packageName }
    }

    func download(_ release: ArchiveRelease, then createDevice: Bool = false) {
        guard let asset = release.fullPackage else { return }
        let key = String(asset.id)
        guard tasks[key] == nil else { return }
        transfers[key] = Transfer(phase: .downloading, progress: 0, detail: "Waiting…")
        let lib = library
        tasks[key] = Task {
            defer {
                tasks[key] = nil
                transfers[key] = nil
            }
            do {
                let dl = ArchiveDownload(asset: asset, into: lib.downloadsDirectory)
                let file = try await dl.start { [weak self] done, total in
                    Task { @MainActor in
                        self?.transfers[key]?.progress = Double(done) / Double(max(total, 1))
                        self?.transfers[key]?.detail = "\(Format.bytes(done)) of \(Format.bytes(total))"
                    }
                }
                try Task.checkCancellation()
                transfers[key] = Transfer(phase: .importing, progress: 0, detail: "Unpacking…")
                let fw = try await FirmwareImporter(library: lib).importPackage(
                    at: file, origin: .archive(tag: release.tag, asset: asset.name, notes: release.notes),
                    replace: true) { [weak self] f, d in
                        Task { @MainActor in
                            self?.transfers[key]?.progress = f
                            self?.transfers[key]?.detail = d
                        }
                    }
                try? FileManager.default.removeItem(at: file)
                model?.reload()
                if createDevice { model?.newDevice(with: fw) }
            } catch {
                model?.report(error, "Couldn’t download \(release.marketingName) \(release.version)")
            }
        }
    }

    func cancel(_ asset: ArchiveAsset) {
        tasks[String(asset.id)]?.cancel()
    }

    func importLocal(_ url: URL) {
        let key = "import:" + url.path
        guard tasks[key] == nil else { return }
        transfers[key] = Transfer(phase: .importing, progress: 0, detail: url.lastPathComponent)
        let lib = library
        tasks[key] = Task {
            defer {
                tasks[key] = nil
                transfers[key] = nil
            }
            do {
                let fw = try await FirmwareImporter(library: lib).importPackage(at: url, replace: true) { [weak self] f, d in
                    Task { @MainActor in
                        self?.transfers[key]?.progress = f
                        self?.transfers[key]?.detail = d
                    }
                }
                model?.reload()
                model?.report("Imported \(fw.marketingName) \(fw.version)",
                              (model?.library.profiles(for: fw).isEmpty ?? true)
                                  ? "No device profile runs \(fw.product) yet."
                                  : "Create a device from it with File ▸ New Device.")
            } catch {
                model?.report(error, "Couldn’t import \(url.lastPathComponent)")
            }
        }
    }

    var importsInProgress: [(String, Transfer)] {
        transfers.filter { $0.key.hasPrefix("import:") }.map { (String($0.key.dropFirst(7)), $0.value) }
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func date(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .omitted)
    }

    static func relative(_ d: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }
}
