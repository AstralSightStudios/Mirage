import MirageKit
import SwiftUI
import UniformTypeIdentifiers

/// Browses and edits a device's file systems: the live tree while it runs,
/// its storage images while it is shut down.
struct FilesWindow: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    @State private var browser: FileBrowser?

    var body: some View {
        Group {
            if let browser {
                FilesContent(browser: browser, device: device)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("\(device.name) — Files")
        .task {
            if browser == nil {
                let b = FileBrowser(deviceID: device.id, model: model)
                b.openFile = { NSWorkspace.shared.open($0) }
                browser = b
                await b.reloadSources()
            }
        }
    }
}

private struct FilesContent: View {
    @Environment(AppModel.self) private var model
    @Bindable var browser: FileBrowser
    let device: VirtualDevice
    @State private var importing = false
    @State private var replacing = false
    @State private var dropTargeted = false
    @State private var naming: Naming?
    @State private var confirmDelete: [GuestEntry]?

    struct Naming: Identifiable {
        var id = UUID()
        var title: String
        var text: String
        var entry: GuestEntry?
    }

    var body: some View {
        let session = model.session(device.id)
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                banner
                table
                Divider()
                statusBar
            }
            .toolbar { toolbar }
        }
        .task(id: "\(session.state.isActive)\(session.shell == .disabled)\(shellReady(session))") {
            await browser.reloadSources()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { Task { await browser.upload(urls) } }
        }
        .fileImporter(isPresented: $replacing, allowedContentTypes: [.data], allowsMultipleSelection: false) { r in
            if case .success(let urls) = r, let url = urls.first { Task { await browser.replaceImage(with: url) } }
        }
        .sheet(item: $naming) { n in
            NameSheet(naming: n) { text in
                Task {
                    if let entry = n.entry { await browser.rename(entry, to: text) } else { await browser.createFolder(text) }
                }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let items = confirmDelete { Task { await browser.delete(items) } }
            }
        } message: {
            Text(browser.live ? "This changes the running device immediately." : "This changes the device's storage image.")
        }
    }

    private func shellReady(_ s: DeviceSession) -> Bool {
        if case .ready = s.shell { return true }
        return false
    }

    private var deleteTitle: String {
        guard let items = confirmDelete else { return "" }
        return items.count == 1 ? "Delete “\(items[0].name)”?" : "Delete \(items.count) items?"
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { browser.source?.id }, set: { id in
            guard let id, let s = sources.first(where: { $0.id == id }) else { return }
            Task { await browser.select(s) }
        })) {
            if browser.live {
                Section("Running Device") {
                    Label("Device", systemImage: "applewatch.radiowaves.left.and.right")
                        .tag(FileBrowser.Source.live.id)
                }
            } else {
                let writable = browser.volumes.filter(\.writable)
                let readOnly = browser.volumes.filter { !$0.writable }
                if !writable.isEmpty {
                    Section("Data") {
                        ForEach(writable) { v in volumeRow(v).tag(FileBrowser.Source.volume(v).id) }
                    }
                }
                if !readOnly.isEmpty {
                    Section("Read-Only Images") {
                        ForEach(readOnly) { v in volumeRow(v).tag(FileBrowser.Source.volume(v).id) }
                    }
                }
            }
            if !browser.imageNames.isEmpty {
                Section("Opened Images") {
                    ForEach(browser.imageNames, id: \.self) { name in
                        Label(name, systemImage: "shippingbox")
                            .tag(FileBrowser.Source.image(name).id)
                            .contextMenu {
                                Button("Close") { Task { await browser.closeImage(name) } }
                            }
                    }
                }
            }
        }
    }

    private var sources: [FileBrowser.Source] {
        (browser.live ? [.live] : browser.volumes.map { .volume($0) }) + browser.imageNames.map { .image($0) }
    }

    private func volumeRow(_ v: DeviceVolume) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(v.title, systemImage: v.writable ? "internaldrive" : "opticaldisc")
            Text("\(v.name) · \(v.format.rawValue) · \(Format.bytes(v.size))")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 26)
        }
    }

    // MARK: Banner

    @ViewBuilder
    private var banner: some View {
        if let notice = browser.notice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
                Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(12)
            .background(.quaternary.opacity(0.5))
        } else if browser.source != nil {
            HStack(spacing: 8) {
                Image(systemName: browser.live ? "bolt.horizontal.circle.fill" : "externaldrive.fill")
                    .foregroundStyle(browser.live ? .green : .secondary)
                Text(modeText).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.35))
        }
    }

    private var modeText: String {
        if browser.live {
            return "Live through the device's shell. Changes take effect immediately; uploads travel as command lines and are slow for large files."
        }
        if case .image = browser.source { return "Read-only romfs image." }
        if browser.replaceableVolume != nil { return "Read-only romfs partition. Use Replace Image to write another romfs image over it." }
        return "The device is shut down: changes are written into its storage image and seen on the next boot."
    }

    // MARK: Table

    private var table: some View {
        Table(browser.entries, selection: $browser.selection) {
            TableColumn("Name") { e in
                Label {
                    Text(e.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: icon(e)).foregroundStyle(e.isDirectory ? Color.accentColor : .secondary)
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Size") { e in
                Text(e.isDirectory ? "—" : Format.bytes(e.size)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Permissions") { e in
                Text(e.mode ?? "").font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Modified") { e in
                Text(e.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "").foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 150)
        }
        .contextMenu(forSelectionType: GuestEntry.ID.self) { ids in
            let items = browser.entries.filter { ids.contains($0.id) }
            if items.count == 1, let e = items.first {
                Button(e.isDirectory ? "Open" : "Open with Default App") { Task { await browser.open(e) } }
                if !e.isDirectory && e.name.hasSuffix(".bin") {
                    Button("Browse as romfs Image") { Task { await browser.browseImage(e) } }
                }
                Divider()
            }
            if !items.isEmpty {
                Button("Save to Folder…") { saveItems(items) }
                if browser.canWrite {
                    if items.count == 1, let e = items.first {
                        Button("Rename…") { naming = Naming(title: "Rename", text: e.name, entry: e) }
                    }
                    Button("Delete…", role: .destructive) { confirmDelete = items }
                }
            } else if browser.canWrite {
                Button("New Folder…") { naming = Naming(title: "New Folder", text: "untitled folder") }
                Button("Copy Files Here…") { importing = true }
            }
        } primaryAction: { ids in
            guard let e = browser.entries.first(where: { ids.contains($0.id) }) else { return }
            Task { await browser.open(e) }
        }
        .overlay {
            if browser.loading && browser.entries.isEmpty {
                ProgressView()
            } else if browser.entries.isEmpty && browser.source != nil && browser.notice == nil {
                Text("Empty Folder").foregroundStyle(.tertiary)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard browser.canWrite else { return false }
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in await browser.upload([url]) } }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted && browser.canWrite {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).padding(4)
            }
        }
    }

    private func icon(_ e: GuestEntry) -> String {
        if e.isDirectory { return "folder.fill" }
        switch (e.name as NSString).pathExtension.lowercased() {
        case "json", "txt", "conf", "prop", "xml", "js", "lua", "log": return "doc.text"
        case "png", "jpg", "jpeg", "bmp", "gif", "webp": return "photo"
        case "ttf", "otf": return "textformat"
        case "bin", "rpk", "mwz", "zip": return "shippingbox"
        case "db", "sqlite": return "cylinder"
        default: return "doc"
        }
    }

    private func saveItems(_ items: [GuestEntry]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where to save \(items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items")"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await browser.download(items, to: url) }
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(browser.crumbs.enumerated()), id: \.offset) { i, crumb in
                if i > 1 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(crumb.name == "/" ? (browser.source.map(rootName) ?? "/") : crumb.name) {
                    Task { await browser.go(to: crumb.path) }
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(i == browser.crumbs.count - 1 ? .primary : .secondary)
            }
            Spacer(minLength: 12)
            if let busy = browser.busy {
                Text(busy.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let p = busy.progress {
                    ProgressView(value: p).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                Text("\(browser.entries.count) items").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func rootName(_ s: FileBrowser.Source) -> String {
        switch s {
        case .live: return device.name
        case .volume(let v): return v.title
        case .image(let name): return name
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { Task { await browser.goBack() } } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!browser.canGoBack)
            Button { Task { await browser.goUp() } } label: { Label("Enclosing Folder", systemImage: "arrow.up") }
                .disabled(browser.path == "/")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await browser.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r")
                .disabled(browser.source == nil)
            Button { naming = Naming(title: "New Folder", text: "untitled folder") } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .disabled(!browser.canWrite || browser.busy != nil)
            Button { importing = true } label: { Label("Copy Files Here", systemImage: "square.and.arrow.down.on.square") }
                .disabled(!browser.canWrite || browser.busy != nil)
                .help("Copy files from this Mac into the current folder")
            Button { saveItems(browser.selectedEntries) } label: { Label("Save to Folder", systemImage: "square.and.arrow.up") }
                .disabled(browser.selectedEntries.isEmpty || browser.busy != nil)
                .help("Save the selected items to this Mac")
            Button { confirmDelete = browser.selectedEntries } label: { Label("Delete", systemImage: "trash") }
                .disabled(!browser.canWrite || browser.selectedEntries.isEmpty || browser.busy != nil)
            if browser.replaceableVolume != nil {
                Button { replacing = true } label: { Label("Replace Image", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard") }
                    .disabled(browser.busy != nil)
                    .help("Write another romfs image over this partition")
            }
        }
    }
}

private struct NameSheet: View {
    let naming: FilesContent.Naming
    let commit: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(naming.title).font(.headline)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(done)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(naming.entry == nil ? "Create" : "Rename", action: done)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty || text.contains("/"))
            }
        }
        .padding(20)
        .onAppear { text = naming.text }
    }

    private func done() {
        guard !text.isEmpty, !text.contains("/") else { return }
        commit(text)
        dismiss()
    }
}
