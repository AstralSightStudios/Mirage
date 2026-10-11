import AppKit
import MirageKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct MirageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Mirage", id: "hub") {
            HubView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1240, height: 820)
        .commands { MirageCommands(model: model) }

        Window("Firmware Archives", id: "archives") {
            ArchiveWindow().environment(model)
        }
        .defaultSize(width: 980, height: 640)
        .keyboardShortcut("a", modifiers: [.command, .shift])

        Window("Device Profiles", id: "profiles") {
            ProfilesWindow().environment(model)
        }
        .defaultSize(width: 980, height: 700)

        WindowGroup("Console", id: "console", for: UUID.self) { $id in
            if let id, let d = model.device(id) {
                ConsolePane(device: d, poppedOut: true)
                    .environment(model)
                    .navigationTitle("\(d.name) — Console")
                    .frame(minWidth: 560, minHeight: 300)
            }
        }
        .defaultSize(width: 900, height: 520)

        Settings {
            SettingsView().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, UserDefaults.standard.object(forKey: "shutdownOnQuit") as? Bool ?? true else { return .terminateNow }
        let running = MainActor.assumeIsolated { model.runningCount }
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running == 1 ? "A device is running" : "\(running) devices are running"
        alert.informativeText = "Shut them down before quitting? Devices left running keep going in the background, and Mirage reattaches to them next time."
        alert.addButton(withTitle: "Shut Down and Quit")
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                await model.shutdownAll()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls { model?.importFirmware(at: url) }
        }
    }
}

struct MirageCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.hubActions) private var hub

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Device…") { model.newDevice() }.keyboardShortcut("n")
            Button("Import Firmware Package…") { importPackage() }.keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandMenu("Device") {
            let id = model.selection
            let session = id.map { model.session($0) }
            let active = session?.state.isActive ?? false
            Button(active ? "Shut Down" : "Boot") {
                guard let id else { return }
                active ? model.shutdown(id) : model.boot(id)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(id == nil)
            Button("Restart") { if let id { model.restart(id) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!active)
            Button(session?.state == .paused ? "Resume" : "Pause") {
                guard let session else { return }
                Task { session.state == .paused ? await session.resume() : await session.pause() }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!active)
            Divider()
            if let id, let profile = model.device(id).flatMap({ model.profile($0.profileID) }) {
                ForEach(profile.buttons) { b in
                    Button("Press \(b.title)") { Task { await session?.press(b.qcode) } }
                        .disabled(session?.state != .running)
                }
                if !profile.buttons.isEmpty { Divider() }
            }
            Button("Show Console") { hub?.showConsole.wrappedValue.toggle() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Zoom to Fit") { hub?.zoom.wrappedValue = .fit }
                .keyboardShortcut("0")
            Button("Pixel Accurate") { hub?.zoom.wrappedValue = .scale(1 / (NSScreen.main?.backingScaleFactor ?? 2)) }
                .keyboardShortcut("1")
            Divider()
            Button("Erase All Content and Settings…") { if let id { model.eraseDevice(id) } }
                .disabled(id == nil || active)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Firmware Archives") { openWindow(id: "archives") }
            Button("Device Profiles") { openWindow(id: "profiles") }
        }
    }

    private func importPackage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose official full OTA packages (.zip / .bin) or unpacked folders"
        if panel.runModal() == .OK {
            for url in panel.urls { model.importFirmware(at: url) }
        }
    }
}
