import Foundation
import MirageKit
import SwiftCrossUI

struct SettingsView: View {
    var model: AppModel
    @State var tab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable {
        case general = "General", emulator = "Emulator", archives = "Archives"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TabBar(tabs: SettingsTab.allCases, selection: $tab).padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    switch tab {
                    case .general: GeneralSettings(model: model)
                    case .emulator: EmulatorSettings()
                    case .archives: ArchiveSettings()
                    }
                }
                .padding(16)
            }
        }
    }
}

private struct GeneralSettings: View {
    var model: AppModel
    @Environment(\.chooseFile) var chooseFile
    @Environment(\.revealFile) var revealFile

    var body: some View {
        InspectorSection("Library") {
            Text(model.library.root.path).textSelectionEnabled()
            HStack {
                Button("Show Files") { revealFile?(model.library.root) }
                Button("Choose…") {
                    Task {
                        guard let url = await chooseFile(title: "Choose the Mirage Library", defaultButtonLabel: "Choose",
                                                         allowSelectingFiles: false, allowSelectingDirectories: true) else { return }
                        model.setLibraryRoot(url)
                    }
                }
            }
            Footnote("Firmware, devices and their storage images live here. eMMC images are sparse but can grow to several GB each, so pick a volume with room.")
        }
        InspectorSection("Quitting") {
            Footnote("Devices keep running in the background when Mirage quits; Mirage and miragectl reattach to them. Shut them down from the hub.")
        }
    }
}

private struct EmulatorSettings: View {
    @State var custom = MirageLibrary.defaults.string(forKey: QEMULocator.overrideKey) ?? ""
    @State var version = ""
    @State var boards: [String] = []
    @State var candidates = QEMULocator.candidates()

    var body: some View {
        let located = QEMULocator.locate()
        InspectorSection("QEMU") {
            ForEach(candidates) { c in
                VStack(alignment: .leading, spacing: 1) {
                    Text((c.exists ? (c.url == located ? "● " : "○ ") : "✕ ") + c.title)
                    Footnote(c.url.path)
                }
            }
            HStack {
                TextField("Custom qemu-system-arm path", text: $custom)
                Button("Apply") {
                    MirageLibrary.defaults.set(custom, forKey: QEMULocator.overrideKey)
                    candidates = QEMULocator.candidates()
                    load()
                }
            }
            if !version.isEmpty {
                InfoRow(label: "Version", value: version)
                Text("Boards: " + boards.joined(separator: ", ")).font(.caption).foregroundColor(.gray)
            }
        }
        .onAppear { load() }
    }

    private func load() {
        Task {
            let info = await Task.detached { () -> (String, [String])? in
                guard let q = QEMULocator.locate() else { return nil }
                return (QEMULocator.version(of: q) ?? "?", QEMULocator.boards(of: q))
            }.value
            version = info?.0 ?? ""
            boards = info?.1 ?? []
        }
    }
}

private struct ArchiveSettings: View {
    @State var token = MirageLibrary.defaults.string(forKey: FirmwareArchiveClient.tokenKey) ?? ""

    var body: some View {
        InspectorSection("MiWear Firmware Archives") {
            InfoRow(label: "Repository", value: FirmwareArchiveClient.repository)
            HStack {
                Text("GitHub token")
                SecureField("Optional", text: $token)
                Button("Save") { MirageLibrary.defaults.set(token, forKey: FirmwareArchiveClient.tokenKey) }
            }
            Footnote("Releases are listed through the GitHub API, which allows 60 requests an hour without a token. Any token works (no scopes needed). Downloads don’t count against the limit.")
        }
    }
}
