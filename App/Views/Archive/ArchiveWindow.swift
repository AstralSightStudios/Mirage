import MirageKit
import SwiftUI
import UniformTypeIdentifiers

/// Firmware library and the MiWear Firmware Archives on GitHub.
struct ArchiveWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Item? = .library
    @State private var search = ""
    @AppStorage("archiveEmulatableOnly") private var emulatableOnly = true

    enum Item: Hashable {
        case library
        case product(String)
    }

    var body: some View {
        let archive = model.archive
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    Label {
                        HStack {
                            Text("Installed Firmware")
                            Spacer()
                            Text("\(model.firmwares.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    } icon: { Image(systemName: "shippingbox.fill").foregroundStyle(.tint) }
                    .tag(Item.library)
                }
                Section {
                    ForEach(products(archive), id: \.self) { p in
                        ProductRow(product: p, emulatable: archive.isEmulatable(p), count: archive.releases(of: p).count)
                            .tag(Item.product(p))
                    }
                } header: {
                    HStack {
                        Text("MiWear Firmware Archives")
                        Spacer()
                        if archive.loading { ProgressView().controlSize(.mini) }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Products")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Emulatable devices only", isOn: $emulatableOnly).toggleStyle(.checkbox)
                    if let e = archive.error {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3)
                    } else if let t = archive.fetchedAt {
                        Text("Updated \(Format.relative(t))").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
        } detail: {
            switch selection {
            case .product(let p):
                ProductDetail(product: p)
            default:
                LibraryDetail()
            }
        }
        .toolbar {
            ToolbarItem {
                Button { archive.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(archive.loading)
                    .help("Fetch releases from GitHub")
            }
        }
        .onAppear { archive.refreshIfStale() }
        .frame(minWidth: 820, minHeight: 520)
    }

    private func products(_ archive: ArchiveModel) -> [String] {
        archive.products
            .filter { !emulatableOnly || archive.isEmulatable($0) }
            .filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) || ProductCatalog.name(of: $0).localizedCaseInsensitiveContains(search) }
            .sorted { (ProductCatalog.name(of: $0), $0) < (ProductCatalog.name(of: $1), $1) }
    }
}

private struct ProductRow: View {
    @Environment(AppModel.self) private var model
    let product: String
    let emulatable: Bool
    let count: Int

    var body: some View {
        let profile = model.profiles.first { $0.runs(product: product) }
        HStack(spacing: 10) {
            DeviceGlyph(profile: profile, size: 26, active: emulatable)
            VStack(alignment: .leading, spacing: 1) {
                Text(ProductCatalog.name(of: product)).lineLimit(1)
                Text(product).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if emulatable {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help("Mirage can emulate this device")
            }
        }
    }
}

private struct ProductDetail: View {
    @Environment(AppModel.self) private var model
    let product: String

    var body: some View {
        let archive = model.archive
        let releases = archive.releases(of: product)
        let emulatable = archive.isEmulatable(product)
        let profile = model.profiles.first { $0.runs(product: product) }
        List {
            Section {
                HStack(spacing: 16) {
                    DeviceGlyph(profile: profile, size: 56, active: emulatable)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ProductCatalog.name(of: product)).font(.title2.weight(.semibold))
                        Text(product).font(.callout.monospaced()).foregroundStyle(.secondary)
                        if emulatable, let profile {
                            Label("Runs on the \(profile.name) profile (\(profile.chip))", systemImage: "checkmark.seal.fill")
                                .font(.callout).foregroundStyle(.green)
                        } else {
                            Label("No device profile emulates this product yet", systemImage: "info.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            Section("Releases") {
                ForEach(releases) { r in
                    ReleaseRow(release: r, emulatable: emulatable)
                }
            }
        }
        .navigationTitle(ProductCatalog.name(of: product))
    }
}

private struct ReleaseRow: View {
    @Environment(AppModel.self) private var model
    let release: ArchiveRelease
    let emulatable: Bool
    @State private var showNotes = false

    var body: some View {
        let archive = model.archive
        let asset = release.fullPackage
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HyperOS \(release.version)").font(.headline)
                    Text("\(Format.date(release.publishedAt)) · \(asset.map { Format.bytes($0.size) } ?? "no full package") · \(release.assets.count) package\(release.assets.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let asset {
                    if let fw = archive.installed(asset) {
                        Label("In Library", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                        if emulatable {
                            Button("Create Device") { model.newDevice(with: fw) }
                        }
                    } else if let t = archive.transfer(for: asset) {
                        VStack(alignment: .trailing, spacing: 3) {
                            ProgressView(value: t.progress).frame(width: 160)
                            Text(t.phase == .downloading ? t.detail : "Importing · \(t.detail)")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if t.phase == .downloading {
                            Button { archive.cancel(asset) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .help("Cancel")
                        }
                    } else {
                        Button("Download") { archive.download(release) }
                        if emulatable {
                            Button("Download & Create Device") { archive.download(release, then: true) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            if !release.notes.isEmpty {
                DisclosureGroup("Release Notes", isExpanded: $showNotes) {
                    Text(release.notes).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
            HStack {
                Link("View on GitHub", destination: release.url).font(.caption)
                if let asset, let sha = asset.sha256 {
                    Text("SHA-256 \(sha.prefix(16))…").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct LibraryDetail: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var targeted = false
    @State private var toDelete: Firmware?

    var body: some View {
        let imports = model.archive.importsInProgress
        Table(model.firmwares) {
            TableColumn("Device") { fw in
                HStack {
                    DeviceGlyph(profile: model.profiles.first { $0.runs(fw) }, size: 22)
                    Text(fw.marketingName)
                }
            }
            .width(min: 180, ideal: 220)
            TableColumn("Version") { fw in Text(fw.version).monospacedDigit() }.width(80)
            TableColumn("Chip") { fw in Text(fw.chip ?? "?") }.width(70)
            TableColumn("Size") { fw in Text(Format.bytes(fw.totalSize)).monospacedDigit() }.width(70)
            TableColumn("Devices") { fw in
                Text("\(model.devices.filter { $0.firmwareID == fw.id }.count)").monospacedDigit()
            }
            .width(55)
            TableColumn("Source") { fw in Text(fw.sourceTitle).foregroundStyle(.secondary).lineLimit(1) }
            TableColumn("") { fw in
                HStack {
                    if model.profiles.contains(where: { $0.runs(fw) }) {
                        Button("Create Device") { model.newDevice(with: fw) }.controlSize(.small)
                    }
                    Menu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.library.firmwareDirectory(fw.id)]) }
                        Button("Remove from Library", role: .destructive) { toDelete = fw }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .width(150)
        }
        .overlay {
            if model.firmwares.isEmpty && imports.isEmpty {
                ContentUnavailableView {
                    Label("No Firmware", systemImage: "shippingbox")
                } description: {
                    Text("Drop an official full OTA package (.zip / .bin, or an unpacked folder) here, or download one from the archive on the left.")
                } actions: {
                    Button("Import Package…") { importing = true }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !imports.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(imports, id: \.0) { path, t in
                        HStack {
                            Text("Importing \(URL(fileURLWithPath: path).lastPathComponent)").lineLimit(1)
                            ProgressView(value: t.progress)
                            Text(t.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 200, alignment: .leading)
                        }
                    }
                }
                .padding(10)
                .background(.bar)
            }
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8])).padding(6)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.importFirmware(at: url) } }
                }
            }
            return true
        }
        .navigationTitle("Installed Firmware")
        .toolbar {
            ToolbarItem {
                Button { importing = true } label: { Label("Import Package", systemImage: "square.and.arrow.down") }
                    .help("Import an official firmware package")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .data, .folder], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { urls.forEach(model.importFirmware) }
        }
        .confirmationDialog("Remove \(toDelete?.marketingName ?? "") \(toDelete?.version ?? "")?",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            presenting: toDelete) { fw in
            Button("Remove", role: .destructive) { model.deleteFirmware(fw.id) }
        } message: { _ in
            Text("The unpacked images are deleted from the library.")
        }
    }
}
