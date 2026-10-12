import Foundation
import MirageKit
import SwiftCrossUI

/// Firmware library and the MiWear Firmware Archives on GitHub.
struct ArchiveWindow: View {
    var model: AppModel
    @State var selection: String? = ArchiveWindow.libraryID
    @State var search = ""
    @State var emulatableOnly = true
    @Environment(\.chooseFile) var chooseFile

    static let libraryID = "library:"

    var body: some View {
        let archive = model.archive
        let products = archive.products
            .filter { !emulatableOnly || archive.isEmulatable($0) }
            .filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) || ProductCatalog.name(of: $0).localizedCaseInsensitiveContains(search) }
            .sorted { (ProductCatalog.name(of: $0), $0) < (ProductCatalog.name(of: $1), $1) }
        let items = [SidebarItem(id: Self.libraryID, title: "Installed Firmware (\(model.firmwares.count))", detail: "Library")]
            + products.map { SidebarItem(id: $0, title: ProductCatalog.name(of: $0) + (archive.isEmulatable($0) ? " ✓" : ""), detail: $0) }
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search products", text: $search)
                ScrollView {
                    List(items, selection: $selection) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).lineLimit(1)
                            Footnote(item.detail)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                Toggle("Emulatable devices only", isOn: $emulatableOnly)
                if let e = archive.error {
                    Text(e).font(.caption).foregroundColor(.orange).lineLimit(3)
                } else if let t = archive.fetchedAt {
                    Footnote("Updated \(Format.relative(t))")
                }
                Button(archive.loading ? "Refreshing…" : "Refresh") { archive.refresh() }
                    .disabled(archive.loading)
            }
            .padding(10)
            .frame(minWidth: 270)
        } detail: {
            if let product = selection, product != Self.libraryID {
                ProductDetail(model: model, product: product)
            } else {
                LibraryDetail(model: model, importPackage: importPackage)
            }
        }
        .onAppear { archive.refreshIfStale() }
    }

    private func importPackage() {
        Task {
            guard let url = await chooseFile(title: "Import Firmware Package", defaultButtonLabel: "Import",
                                             allowSelectingDirectories: true) else { return }
            model.importFirmware(at: url)
        }
    }
}

struct SidebarItem: Identifiable {
    let id: String
    let title: String
    let detail: String
}

private struct ProductDetail: View {
    var model: AppModel
    let product: String

    var body: some View {
        let archive = model.archive
        let releases = archive.releases(of: product)
        let emulatable = archive.isEmulatable(product)
        let profile = model.profiles.first { $0.runs(product: product) }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(ProductCatalog.name(of: product)).font(.title2)
                Footnote(product)
                if emulatable, let profile {
                    Text("Runs on the \(profile.name) profile (\(profile.chip))").foregroundColor(.green)
                } else {
                    Footnote("No device profile emulates this product yet")
                }
                ForEach(releases) { r in
                    ReleaseRow(model: model, release: r, emulatable: emulatable)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ReleaseRow: View {
    var model: AppModel
    let release: ArchiveRelease
    let emulatable: Bool
    @State var showNotes = false
    @Environment(\.openURL) var openURL

    var body: some View {
        let archive = model.archive
        let asset = release.fullPackage
        InspectorSection {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HyperOS \(release.version)").font(.headline)
                    Footnote("\(Format.date(release.publishedAt)) · \(asset.map { Format.bytes($0.size) } ?? "no full package") · \(release.assets.count) package\(release.assets.count == 1 ? "" : "s")")
                }
                Spacer()
                if let asset {
                    if let fw = archive.installed(asset) {
                        Text("In Library").foregroundColor(.green)
                        if emulatable {
                            Button("Create Device") { model.newDevice(with: fw) }
                        }
                    } else if let t = archive.transfer(for: asset) {
                        VStack(alignment: .trailing, spacing: 2) {
                            ProgressView(value: t.progress).frame(width: 160)
                            Footnote(t.phase == .downloading ? t.detail : "Importing · \(t.detail)")
                        }
                        if t.phase == .downloading {
                            Button("Cancel") { archive.cancel(asset) }
                        }
                    } else {
                        Button("Download") { archive.download(release) }
                        if emulatable {
                            Button("Download & Create Device") { archive.download(release, then: true) }
                        }
                    }
                }
            }
            HStack {
                Button("View on GitHub") { openURL(release.url) }
                if !release.notes.isEmpty {
                    Button(showNotes ? "Hide Release Notes" : "Release Notes") { showNotes.toggle() }
                }
                if let asset, let sha = asset.sha256 {
                    Footnote("SHA-256 \(sha.prefix(16))…")
                }
            }
            if showNotes {
                Text(release.notes).font(.callout).foregroundColor(.gray).textSelectionEnabled()
            }
        }
    }
}

private struct LibraryDetail: View {
    var model: AppModel
    let importPackage: () -> Void
    @State var toDelete: Firmware?
    @Environment(\.revealFile) var revealFile

    var body: some View {
        let imports = model.archive.importsInProgress.map { ImportRow(path: $0.0, transfer: $0.1) }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Installed Firmware").font(.headline)
                Spacer()
                Button("Import Package…") { importPackage() }
            }
            .padding(12)
            Divider()
            if model.firmwares.isEmpty && imports.isEmpty {
                ContentUnavailableView {
                    Text("No Firmware")
                } description: {
                    Text("Import an official full OTA package (.zip / .bin, or an unpacked folder), or download one from the archive on the left.")
                } actions: {
                    Button("Import Package…") { importPackage() }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.firmwares) { fw in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(fw.marketingName) · \(fw.version)")
                                    Footnote("\(fw.chip ?? "?") · \(Format.bytes(fw.totalSize)) · \(model.devices.filter { $0.firmwareID == fw.id }.count) device(s) · \(fw.sourceTitle)")
                                }
                                Spacer()
                                if model.profiles.contains(where: { $0.runs(fw) }) {
                                    Button("Create Device") { model.newDevice(with: fw) }
                                }
                                Menu("…") {
                                    Button("Show Files") { revealFile?(model.library.firmwareDirectory(fw.id)) }
                                    Button("Remove from Library") { toDelete = fw }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            ForEach(imports) { row in
                HStack {
                    Text("Importing \(URL(fileURLWithPath: row.path).lastPathComponent)").lineLimit(1)
                    ProgressView(value: row.transfer.progress).frame(width: 200)
                    Footnote(row.transfer.detail)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .alert(Binding(get: { toDelete.map { "Remove \($0.marketingName) \($0.version)? The unpacked images are deleted from the library." } },
                       set: { if $0 == nil { toDelete = nil } })) {
            Button("Remove") { if let fw = toDelete { model.deleteFirmware(fw.id) }; toDelete = nil }
            Button("Cancel") { toDelete = nil }
        }
    }
}
