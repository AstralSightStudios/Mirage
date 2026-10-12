import MirageKit
import SwiftCrossUI
// The backend module's App extension picks the backend.
#if os(Windows)
import WinUIBackend
#else
import GtkBackend
#endif

@main
struct MirageCrossApp: App {
    @State var model = AppModel()

    var body: some Scene {
        WindowGroup("Mirage") {
            VStack {
                Text("Mirage")
                ForEach(model.devices) { device in
                    Text(device.name)
                }
            }
            .padding()
        }
        .defaultSize(width: 1240, height: 820)
    }
}
