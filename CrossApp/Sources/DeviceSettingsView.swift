import Foundation
import MirageKit
import SwiftCrossUI

/// Boot and debugging options of a device, applied at its next boot.
struct DeviceSettingsView: View {
    var model: AppModel
    let device: VirtualDevice
    @State var options = RuntimeOptions()
    @State var extra = ""
    @State var traces = ""
    @State var port = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        let session = model.session(device.id)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(device.name) Settings").font(.headline)
                    InspectorSection("Boot") {
                        Toggle("NuttX shell on the console", isOn: $options.shell)
                        Footnote("Starts the firmware’s own sh builtin at boot through the gdbstub, like a debug probe. The firmware is not modified.")
                        Toggle("Bluetooth bridge", isOn: $options.bluetoothBridge)
                        Footnote("Serves the band’s radio as a standard HCI controller over TCP, for companion apps.")
                        if options.bluetoothBridge {
                            HStack {
                                Text("Port")
                                TextField("Automatic", text: $port).frame(width: 120)
                            }
                        }
                    }
                    InspectorSection("Debugging") {
                        HStack {
                            Text("Log items (-d)")
                            TextField("e.g. guest_errors,unimp", text: $options.debugLog)
                        }
                        Text("Trace events (-trace), one per line")
                        TextEditor(text: $traces).frame(height: 60)
                        Text("Extra QEMU arguments, one per line")
                        TextEditor(text: $extra).frame(height: 90)
                        Footnote("Applied at the next boot. Logs go to the device’s Logs folder.")
                    }
                    if let cmd = session.commandLine {
                        InspectorSection("Last Command Line") {
                            Text(cmd).font(.caption).textSelectionEnabled()
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var d = device
                    var o = options
                    o.extraArguments = extra.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    o.traceEvents = traces.split(whereSeparator: { $0 == "\n" || $0 == "," })
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    o.bluetoothPort = Int(port) ?? 0
                    d.options = o
                    model.update(d)
                    dismiss()
                }
            }
            .padding(12)
        }
        .frame(width: 540, height: 600)
        .onAppear {
            options = device.options
            extra = device.options.extraArguments.joined(separator: "\n")
            traces = device.options.traceEvents.joined(separator: "\n")
            port = device.options.bluetoothPort > 0 ? String(device.options.bluetoothPort) : ""
        }
    }
}
