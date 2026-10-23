import Foundation
import MirageKit
import SwiftCrossUI

/// Watchfaces and quick apps on the device, through the companion core over
/// the emulator's Bluetooth bridge.
struct AppsTab: View {
    var model: AppModel
    let device: VirtualDevice
    @State var showLog = false
    @Environment(\.chooseFile) var chooseFile

    var body: some View {
        let ab = model.astrobox
        let session = model.session(device.id)
        let connected = ab.isConnected(device.id)
        VStack(alignment: .leading, spacing: 0) {
            if !ab.isAvailable {
                unavailable("Companion core not built",
                            "This build of Mirage doesn’t include the companion core, so watchfaces and quick apps can’t be managed.")
            } else if !device.binding.bound {
                unavailable("Device not bound",
                            "The companion core connects to bound devices. Turn on “Bound to a phone” in Binding.")
            } else if !device.options.bluetoothBridge {
                unavailable("Bluetooth bridge off", "Enable the Bluetooth bridge in the device’s Settings.")
            } else if !session.state.isActive {
                unavailable("Device not running", "Boot the device, then connect the companion core to it.")
            } else {
                InspectorSection("Companion") {
                    HStack {
                        StateDot(active: connected, busy: ab.state == .connecting && ab.deviceID == device.id)
                        VStack(alignment: .leading, spacing: 1) {
                            if connected, let info = ab.info {
                                Text(info.name.isEmpty ? "Connected" : info.name)
                                Footnote("\(info.model) · \(info.firmwareVersion)")
                            } else if ab.state == .connecting && ab.deviceID == device.id {
                                Text("Connecting…")
                                Footnote("Confirm the pairing request on the device the first time.")
                            } else {
                                Text("Not connected")
                                Footnote(ab.deviceID != nil && ab.deviceID != device.id && ab.state == .connected
                                         ? "Connected to another device"
                                         : "Bluetooth bridge 127.0.0.1:\(session.bluetoothPort.map(String.init) ?? "—")")
                            }
                        }
                        Spacer()
                        if connected {
                            Button("Disconnect") { Task { await ab.disconnect() } }
                        } else if !(ab.state == .connecting && ab.deviceID == device.id) {
                            Button("Connect") {
                                guard let port = session.bluetoothPort else { return }
                                Task {
                                    await ab.connect(device: device, port: port,
                                                     stateDirectory: model.library.paths(for: device).astrobox)
                                }
                            }
                            .disabled(session.bluetoothPort == nil || session.state != .running)
                        }
                    }
                    if connected, let info = ab.info {
                        InfoRow(label: "Serial Number", value: info.serialNumber)
                        InfoRow(label: "Firmware", value: info.firmwareVersion)
                        if let b = info.battery { InfoRow(label: "Battery", value: "\(b)%") }
                    }
                }
                if connected {
                    InspectorSection {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Install")
                                Footnote(".canopus, .rpk quick apps, or watchface packages")
                            }
                            Spacer()
                            Button("Choose…") { choose() }
                        }
                        ForEach(ab.installs) { i in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(i.file).lineLimit(1)
                                    Spacer()
                                    Text("\(Int(i.progress * 100))%").foregroundColor(.gray)
                                }
                                ProgressView(value: i.progress)
                                Footnote(i.message)
                            }
                        }
                    }
                    InspectorSection("Watchfaces") {
                        if ab.watchfaces.isEmpty {
                            Text(ab.loadingApps ? "Loading…" : "None").foregroundColor(.gray)
                        }
                        ForEach(ab.watchfaces) { w in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((w.current ? "● " : "") + w.name).lineLimit(1)
                                    Footnote(w.id)
                                }
                                Spacer()
                                Menu("…") {
                                    Button("Use") { Task { await ab.setWatchface(w.id) } }.disabled(w.current)
                                    Button("Remove") { Task { await ab.removeWatchface(w.id) } }.disabled(!w.canRemove)
                                }
                            }
                        }
                    }
                    InspectorSection("Quick Apps") {
                        if ab.quickApps.isEmpty {
                            Text(ab.loadingApps ? "Loading…" : "None").foregroundColor(.gray)
                        }
                        ForEach(ab.quickApps) { app in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name.isEmpty ? app.packageName : app.name).lineLimit(1)
                                    Footnote([app.packageName, app.version].filter { !$0.isEmpty }.joined(separator: " · "))
                                }
                                Spacer()
                                Menu("…") {
                                    Button("Open") { Task { await ab.launch(app) } }
                                    Button("Remove") { Task { await ab.remove(app) } }
                                }
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Refresh") { Task { await ab.refreshApps() } }.disabled(ab.loadingApps)
                    }
                    .padding(.top, 8)
                }
                if let err = ab.lastError, ab.deviceID == device.id {
                    Text(err).font(.caption).foregroundColor(.orange).padding(.top, 10).textSelectionEnabled()
                }
                Toggle("Companion log", isOn: $showLog).padding(.top, 14)
                if showLog {
                    ScrollView {
                        Text(ab.log.suffix(300).joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelectionEnabled()
                    }
                    .frame(height: 180)
                }
            }
        }
    }

    private func choose() {
        Task {
            guard let url = await chooseFile(title: "Install on \(device.name)", defaultButtonLabel: "Install") else { return }
            guard let kind = AstroBoxService.Kind.of(url) else {
                model.report("Unsupported file", "\(url.lastPathComponent): install .rpk quick apps, Canopus packages (.canopus), or watchface packages (.bin, .mwz).")
                return
            }
            await model.astrobox.install(url, kind: kind)
        }
    }

    private func unavailable(_ title: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundColor(.gray).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
