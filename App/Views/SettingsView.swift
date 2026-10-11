import MirageKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            EmulatorSettings().tabItem { Label("Emulator", systemImage: "cpu") }
            ArchiveSettings().tabItem { Label("Archives", systemImage: "shippingbox") }
        }
        .frame(width: 560, height: 380)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var choosing = false
    @AppStorage("shutdownOnQuit") private var shutdownOnQuit = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Library") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(model.library.root.path).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
                            .textSelection(.enabled)
                        HStack {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.library.root]) }
                            Button("Choose…") { choosing = true }
                        }
                        .controlSize(.small)
                    }
                }
            } footer: {
                Text("Firmware, devices and their storage images live here. eMMC images are sparse but can grow to several GB each, so pick a volume with room.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Shut down running devices when Mirage quits", isOn: $shutdownOnQuit)
            } footer: {
                Text("Devices left running keep going in the background; Mirage and miragectl reattach to them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { model.setLibraryRoot(url) }
        }
    }
}

private struct EmulatorSettings: View {
    @State private var custom = MirageLibrary.defaults.string(forKey: QEMULocator.overrideKey) ?? ""
    @State private var info: (version: String, boards: [String])?
    @State private var candidates = QEMULocator.candidates()

    var body: some View {
        Form {
            Section("QEMU") {
                ForEach(candidates) { c in
                    HStack {
                        Image(systemName: c.exists ? (c.url == QEMULocator.locate() ? "checkmark.circle.fill" : "circle") : "xmark.circle")
                            .foregroundStyle(c.exists ? (c.url == QEMULocator.locate() ? Color.green : Color.secondary) : Color.red.opacity(0.6))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.title)
                            Text(c.url.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                HStack {
                    TextField("Custom qemu-system-arm", text: $custom, prompt: Text("/path/to/qemu-system-arm"))
                    Button("Apply") {
                        MirageLibrary.defaults.set(custom, forKey: QEMULocator.overrideKey)
                        candidates = QEMULocator.candidates()
                        load()
                    }
                }
                if let info {
                    LabeledContent("Version", value: info.version)
                    LabeledContent("Boards", value: info.boards.joined(separator: ", "))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func load() {
        Task.detached {
            guard let q = QEMULocator.locate() else { return }
            let v = QEMULocator.version(of: q) ?? "?"
            let b = QEMULocator.boards(of: q)
            await MainActor.run { info = (v, b) }
        }
    }
}

private struct ArchiveSettings: View {
    @State private var token = MirageLibrary.defaults.string(forKey: FirmwareArchiveClient.tokenKey) ?? ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Repository", value: FirmwareArchiveClient.repository)
                SecureField("GitHub token", text: $token, prompt: Text("Optional"))
                    .onSubmit(save)
                    .onChange(of: token) { save() }
            } footer: {
                Text("Releases are listed through the GitHub API, which allows 60 requests an hour without a token. Any token works (no scopes needed). Downloads don’t count against the limit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        MirageLibrary.defaults.set(token, forKey: FirmwareArchiveClient.tokenKey)
    }
}
