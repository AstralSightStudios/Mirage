import GtkBackend
import MirageKit
import SwiftCrossUI

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
