import Foundation
import MirageKit
import SwiftCrossUI

/// The selected device's files: the live tree while it runs, its storage
/// images while it is shut down (see FileBrowser).
struct FilesWindow: View {
    var model: AppModel

    var body: some View {
        if let device = model.device(model.selection) {
            FilesView(model: model, device: device, browser: FileBrowsers.browser(for: device.id, model: model))
        } else {
            Text("No device selected").foregroundColor(.gray).padding()
        }
    }
}

/// One browser per device, kept while the window switches between them.
@MainActor
enum FileBrowsers {
    private static var all: [UUID: FileBrowser] = [:]

    static func browser(for id: UUID, model: AppModel) -> FileBrowser {
        if let b = all[id] { return b }
        let b = FileBrowser(deviceID: id, model: model)
        all[id] = b
        return b
    }
}

struct SourceItem: Identifiable {
    var id: String { source.id }
    var title: String
    var detail: String
    var source: FileBrowser.Source
}

enum Naming: Equatable {
    case newFolder
    case rename(GuestEntry)
}

struct FilesView: View {
    var model: AppModel
    let device: VirtualDevice
    var browser: FileBrowser
    @State var naming: Naming?
    @State var name = ""
    @State var confirmDelete = false
    @Environment(\.chooseFile) var chooseFile
    @Environment(\.chooseFileSaveDestination) var chooseSaveDestination
    @Environment(\.openURL) var openURL

    var body: some View {
        let session = model.session(device.id)
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text(device.name).emphasized()
                ScrollView {
                    List(sources, selection: Binding(get: { browser.source?.id }, set: { id in
                        guard let id, let item = sources.first(where: { $0.id == id }) else { return }
                        Task { await browser.select(item.source) }
                    })) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).lineLimit(1)
                            Footnote(item.detail)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(10)
            .frame(minWidth: 220)
        } detail: {
            VStack(alignment: .leading, spacing: 8) {
                Footnote(browser.notice ?? modeText)
                HStack {
                    Button("Back") { Task { await browser.goBack() } }.disabled(!browser.canGoBack)
                    Button("Up") { Task { await browser.goUp() } }.disabled(browser.path == "/")
                    Button("Refresh") { Task { await browser.refresh() } }.disabled(browser.source == nil)
                    Text(browser.path).lineLimit(1)
                    Spacer()
                    if let busy = browser.busy {
                        Footnote(busy.title)
                        if let p = busy.progress { ProgressView(value: p).frame(width: 100) }
                    } else {
                        Footnote("\(browser.entries.count) items")
                    }
                }
                if let naming {
                    HStack {
                        TextField(naming == .newFolder ? "Folder name" : "New name", text: $name)
                        Button(naming == .newFolder ? "Create" : "Rename") { commitName() }
                            .disabled(name.isEmpty || name.contains("/"))
                        Button("Cancel") { self.naming = nil }
                    }
                }
                ScrollView {
                    List(browser.entries, selection: Binding(get: { browser.selection.first }, set: { id in
                        browser.selection = id.map { [$0] } ?? []
                    })) { e in
                        HStack {
                            Text((e.isDirectory ? "▸ " : "   ") + e.name).lineLimit(1)
                            Spacer()
                            Text(e.isDirectory ? "" : Format.bytes(e.size)).foregroundColor(.gray)
                            Text(e.mode ?? "").font(.caption).foregroundColor(.gray)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                actions
            }
            .padding(10)
        }
        .task(id: "\(device.id)\(session.state.isActive)\(shellReady(session))") {
            browser.openFile = { url in openURL(url) }
            await browser.reloadSources()
        }
        .alert(deleteTitle, isPresented: $confirmDelete) {
            Button("Delete") {
                let items = browser.selectedEntries
                Task { await browser.delete(items) }
            }
            Button("Cancel") {}
        }
    }

    private var actions: some View {
        let selected = browser.selectedEntries.first
        let idle = browser.busy == nil
        return HStack {
            Button("Open") { if let e = selected { Task { await browser.open(e) } } }
                .disabled(selected == nil || !idle)
            Button("Save…") { if let e = selected { save(e) } }
                .disabled(selected == nil || !idle)
            if let e = selected, !e.isDirectory, e.name.hasSuffix(".bin") {
                Button("Browse romfs") { Task { await browser.browseImage(e) } }.disabled(!idle)
            }
            Spacer()
            if browser.canWrite {
                Button("Copy File Here…") { upload(directory: false) }.disabled(!idle)
                Button("Copy Folder Here…") { upload(directory: true) }.disabled(!idle)
                Button("New Folder") { name = ""; naming = .newFolder }.disabled(!idle)
                Button("Rename") { if let e = selected { name = e.name; naming = .rename(e) } }
                    .disabled(selected == nil || !idle)
                Button("Delete") { confirmDelete = true }.disabled(selected == nil || !idle)
            }
            if browser.replaceableVolume != nil {
                Button("Replace Image…") { replaceImage() }.disabled(!idle)
            }
        }
    }

    private var sources: [SourceItem] {
        var out: [SourceItem] = []
        if browser.live {
            out.append(SourceItem(title: "Device", detail: "Live, through the shell", source: .live))
        }
        for v in browser.volumes {
            out.append(SourceItem(title: v.title, detail: "\(v.name) · \(v.format.rawValue) · \(Format.bytes(v.size))\(v.writable ? "" : " · read-only")",
                                  source: .volume(v)))
        }
        for name in browser.imageNames {
            out.append(SourceItem(title: name, detail: "romfs image", source: .image(name)))
        }
        return out
    }

    private var modeText: String {
        if browser.live {
            return "Live through the device's shell: changes take effect immediately; large uploads are slow."
        }
        if case .image = browser.source { return "Read-only romfs image." }
        if browser.replaceableVolume != nil { return "Read-only romfs partition; Replace Image writes another romfs image over it." }
        return "The device is shut down: changes go into its storage image and show on the next boot."
    }

    private var deleteTitle: String {
        guard let e = browser.selectedEntries.first else { return "" }
        return "Delete “\(e.name)”?" + (browser.live ? " This changes the running device immediately." : "")
    }

    private func shellReady(_ s: DeviceSession) -> Bool {
        if case .ready = s.shell { return true }
        return false
    }

    private func commitName() {
        guard let naming, !name.isEmpty, !name.contains("/") else { return }
        let text = name
        self.naming = nil
        Task {
            switch naming {
            case .newFolder: await browser.createFolder(text)
            case .rename(let e): await browser.rename(e, to: text)
            }
        }
    }

    private func save(_ e: GuestEntry) {
        Task {
            if e.isDirectory {
                guard let folder = await chooseFile(title: "Save “\(e.name)” Into", defaultButtonLabel: "Save Here",
                                                    allowSelectingFiles: false, allowSelectingDirectories: true) else { return }
                await browser.download([e], to: folder)
            } else {
                guard let url = await chooseSaveDestination(title: "Save “\(e.name)”", defaultFileName: e.name) else { return }
                await browser.save(e, as: url)
            }
        }
    }

    private func upload(directory: Bool) {
        Task {
            guard let url = await chooseFile(title: "Copy to \(browser.path)", defaultButtonLabel: "Copy",
                                             allowSelectingFiles: !directory, allowSelectingDirectories: directory) else { return }
            await browser.upload([url])
        }
    }

    private func replaceImage() {
        Task {
            guard let url = await chooseFile(title: "Replace \(browser.replaceableVolume?.title ?? "") With",
                                             defaultButtonLabel: "Replace") else { return }
            await browser.replaceImage(with: url)
        }
    }
}
