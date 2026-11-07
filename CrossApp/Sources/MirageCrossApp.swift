import Foundation
import MirageKit
import SwiftCrossUI
// The backend module's App extension picks the backend.
#if os(Windows)
import WinAppSDK
import WinUIBackend
#else
import GtkBackend
#endif

extension View {
    /// Sets the app icon on the native window backing this scene.
    func mirageWindowIcon() -> some View {
        #if os(Windows)
        inspectWindow { window in
            guard
                let appWindow = window.appWindow,
                let icon = Bundle.module.url(forResource: "Mirage", withExtension: "ico")
            else { return }
            try? appWindow.setIcon(icon.path)
        }
        #else
        self
        #endif
    }
}

@main
struct MirageCrossApp: App {
    @State var model = AppModel()

    var body: some Scene {
        WindowGroup("Mirage") {
            HubView(model: model)
                .mirageWindowIcon()
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandMenu("Device") {
                Button("New Device…") { model.newDevice() }
                Divider()
                Button("Boot or Shut Down") {
                    guard let id = model.selection else { return }
                    model.state(of: id).isActive ? model.shutdown(id) : model.boot(id)
                }
                Button("Restart") { if let id = model.selection { model.restart(id) } }
                Button("Pause or Resume") {
                    guard let id = model.selection else { return }
                    let s = model.session(id)
                    Task { s.state == .paused ? await s.resume() : await s.pause() }
                }
            }
        }

        Window("Firmware Archives", id: "archives") {
            ArchiveWindow(model: model)
                .mirageWindowIcon()
        }
        .defaultSize(width: 980, height: 640)
        .defaultLaunchBehavior(.suppressed)

        Window("Device Profiles", id: "profiles") {
            ProfilesWindow(model: model)
                .mirageWindowIcon()
        }
        .defaultSize(width: 980, height: 700)
        .defaultLaunchBehavior(.suppressed)

        Window("Console", id: "console") {
            ConsoleWindow(model: model)
                .mirageWindowIcon()
        }
        .defaultSize(width: 900, height: 520)
        .defaultLaunchBehavior(.suppressed)

        Window("Files", id: "files") {
            FilesWindow(model: model)
                .mirageWindowIcon()
        }
        .defaultSize(width: 1000, height: 640)
        .defaultLaunchBehavior(.suppressed)

        Window("Settings", id: "settings") {
            SettingsView(model: model)
                .mirageWindowIcon()
        }
        .defaultSize(width: 620, height: 520)
        .defaultLaunchBehavior(.suppressed)
    }
}
