import MirageKit
import SwiftUI
import UniformTypeIdentifiers

/// Watchfaces and quick apps on the device, through the companion core over the
/// emulator's Bluetooth bridge.
struct AppsTab: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    @State private var importing = false
    @State private var dropTargeted = false
    @State private var showLog = false

    var body: some View {
        let ab = model.astrobox
        let session = model.session(device.id)
        let connected = ab.isConnected(device.id)
        VStack(alignment: .leading, spacing: 0) {
            if !ab.isAvailable {
                Unavailable(icon: "shippingbox", title: "Companion core not built",
                            text: "Build it with Scripts/build-companion-core.sh, then rebuild Mirage, to manage watchfaces and quick apps.")
            } else if !device.binding.bound {
                Unavailable(icon: "link.badge.plus", title: "Device not bound",
                            text: "The companion core connects to bound devices. Turn on “Bound to a phone” in Binding.")
            } else if !device.options.bluetoothBridge {
                Unavailable(icon: "antenna.radiowaves.left.and.right.slash", title: "Bluetooth bridge off",
                            text: "Enable the Bluetooth bridge in Device Settings.")
            } else if !session.state.isActive {
                Unavailable(icon: "power", title: "Device not running",
                            text: "Boot the device, then connect the companion core to it.")
            } else {
                connection(ab: ab, session: session, connected: connected)
                if connected {
                    installSection(ab: ab)
                    watchfaces(ab: ab)
                    quickApps(ab: ab)
                }
                if let err = ab.lastError, ab.deviceID == device.id {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).padding(.top, 10).textSelection(.enabled)
                }
                DisclosureGroup("Companion Log", isExpanded: $showLog) {
                    ScrollView {
                        Text(ab.log.suffix(300).joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 180)
                }
                .font(.callout)
                .padding(.top, 14)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.types, allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { install(urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard connected else { return false }
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in install([url]) } }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted && connected {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
            }
        }
    }

    static let types: [UTType] = [UTType(filenameExtension: "rpk") ?? .data, UTType(filenameExtension: "mwz") ?? .data, UTType(filenameExtension: "canopus") ?? .data, .data]

    private func install(_ urls: [URL]) {
        for url in urls {
            guard let kind = AstroBoxService.Kind.of(url) else {
                model.report("Unsupported file", "\(url.lastPathComponent): install .rpk quick apps, Canopus packages (.canopus), or watchface packages (.bin, .mwz).")
                continue
            }
            let access = url.startAccessingSecurityScopedResource()
            Task {
                await model.astrobox.install(url, kind: kind)
                if access { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    @ViewBuilder
    private func connection(ab: AstroBoxService, session: DeviceSession, connected: Bool) -> some View {
        InspectorSection(title: "Companion") {
            HStack(spacing: 10) {
                Image(systemName: connected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                    .foregroundStyle(connected ? .green : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    if connected, let info = ab.info {
                        Text(info.name.isEmpty ? "Connected" : info.name)
                        Text("\(info.model) · \(info.firmwareVersion)").font(.caption).foregroundStyle(.secondary)
                    } else if ab.state == .connecting && ab.deviceID == device.id {
                        Text("Connecting…")
                        Text("Confirm the pairing request on the device the first time.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Not connected")
                        Text(ab.deviceID != nil && ab.deviceID != device.id && ab.state == .connected
                             ? "Connected to another device" : "Bluetooth bridge 127.0.0.1:\(session.bluetoothPort.map(String.init) ?? "—")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if connected {
                    Button("Disconnect") { Task { await ab.disconnect() } }.controlSize(.small)
                } else if ab.state == .connecting && ab.deviceID == device.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Connect") {
                        guard let port = session.bluetoothPort else { return }
                        Task {
                            await ab.connect(device: device, port: port,
                                             stateDirectory: model.library.paths(for: device).astrobox)
                        }
                    }
                    .controlSize(.small)
                    .disabled(session.bluetoothPort == nil || session.state != .running)
                }
            }
            .padding(.vertical, 10)
            if connected, let info = ab.info {
                InfoRow(label: "Serial Number", value: info.serialNumber, mono: true)
                InfoRow(label: "Firmware", value: info.firmwareVersion)
                if let b = info.battery { InfoRow(label: "Battery", value: "\(b)%") }
            }
        }
    }

    @ViewBuilder
    private func installSection(ab: AstroBoxService) -> some View {
        InspectorSection {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install")
                    Text("Drop .canopus, .rpk quick apps, or watchface packages here").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose…") { importing = true }.controlSize(.small)
            }
            .padding(.vertical, 9)
            ForEach(ab.installs) { i in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(i.file).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(Int(i.progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    ProgressView(value: i.progress)
                    Text(i.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func watchfaces(ab: AstroBoxService) -> some View {
        InspectorSection(title: "Watchfaces") {
            if ab.watchfaces.isEmpty {
                Text(ab.loadingApps ? "Loading…" : "None").foregroundStyle(.secondary).padding(.vertical, 9)
            }
            ForEach(ab.watchfaces) { w in
                HStack {
                    Image(systemName: w.current ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(w.current ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(w.name).lineLimit(1)
                        Text(w.id).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Menu {
                        Button("Use") { Task { await ab.setWatchface(w.id) } }.disabled(w.current)
                        Button("Remove", role: .destructive) { Task { await ab.removeWatchface(w.id) } }.disabled(!w.canRemove)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func quickApps(ab: AstroBoxService) -> some View {
        InspectorSection(title: "Quick Apps") {
            if ab.quickApps.isEmpty {
                Text(ab.loadingApps ? "Loading…" : "None").foregroundStyle(.secondary).padding(.vertical, 9)
            }
            ForEach(ab.quickApps) { app in
                HStack {
                    Image(systemName: "app.dashed").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name.isEmpty ? app.packageName : app.name).lineLimit(1)
                        Text([app.packageName, app.version].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Menu {
                        Button("Open") { Task { await ab.launch(app) } }
                        Button("Remove", role: .destructive) { Task { await ab.remove(app) } }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.vertical, 6)
            }
        }
        HStack {
            Spacer()
            Button { Task { await ab.refreshApps() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .controlSize(.small)
                .disabled(ab.loadingApps)
        }
        .padding(.top, 8)
    }
}

private struct Unavailable: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(.init(text)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
