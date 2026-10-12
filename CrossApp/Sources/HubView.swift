import Foundation
import MirageKit
import SwiftCrossUI

/// The main window, like the macOS Device Hub: devices on the left, the
/// selected device in the middle, its details on the right.
struct HubView: View {
    var model: AppModel
    @State var showInspector = true
    @State var showConsole = false
    @State var showDeviceSettings = false
    @State var tab: InspectorTab = .info
    /// Points per panel pixel; nil fits the stage.
    @State var zoom: Double? = nil
    @Environment(\.openWindow) var openWindow

    var body: some View {
        NavigationSplitView {
            DeviceSidebar(model: model)
                .frame(minWidth: 240)
        } detail: {
            if let device = model.device(model.selection) {
                VStack(spacing: 0) {
                    DeviceToolbar(model: model, device: device, showConsole: $showConsole,
                                  showInspector: $showInspector, showSettings: $showDeviceSettings)
                    Divider()
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            StageView(model: model, device: device, zoom: $zoom)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if showConsole {
                                Divider()
                                ConsolePane(model: model, device: device)
                                    .frame(height: 280)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if showInspector {
                            Divider()
                            InspectorView(model: model, device: device, tab: $tab)
                                .frame(width: 350)
                                .frame(maxHeight: .infinity)
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Text("No Devices")
                } description: {
                    Text("Create a device from an official firmware package.")
                } actions: {
                    HStack {
                        Button("New Device…") { model.newDevice() }
                        Button("Browse Firmware Archives…") { openWindow(id: "archives") }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { model.showNewDevice }, set: { model.showNewDevice = $0 })) {
            NewDeviceView(model: model, initialFirmware: model.newDeviceFirmware)
        }
        .sheet(isPresented: $showDeviceSettings) {
            if let device = model.device(model.selection) {
                DeviceSettingsView(model: model, device: device)
            }
        }
        .alert(Binding(get: { model.alert.map { $0.message.isEmpty ? $0.title : "\($0.title)\n\n\($0.message)" } },
                       set: { if $0 == nil { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        }
    }
}

// MARK: - Sidebar

struct DeviceSidebar: View {
    var model: AppModel
    @State var search = ""
    @Environment(\.openWindow) var openWindow

    var body: some View {
        let shown = model.devices.filter { d in
            search.isEmpty || d.name.localizedCaseInsensitiveContains(search)
                || (model.firmware(d.firmwareID)?.version.contains(search) ?? false)
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("New Device") { model.newDevice() }
                Button("Firmware…") { openWindow(id: "archives") }
                Button("Profiles…") { openWindow(id: "profiles") }
            }
            TextField("Search", text: $search)
            ScrollView {
                List(shown, selection: Binding(get: { model.selection }, set: { model.selection = $0 })) { d in
                    DeviceRow(model: model, device: d)
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Text("\(model.runningCount) running")
                    .font(.caption)
                    .foregroundColor(.gray)
                Spacer()
                Button("Settings…") { openWindow(id: "settings") }
            }
        }
        .padding(10)
    }
}

struct DeviceRow: View {
    var model: AppModel
    let device: VirtualDevice

    var body: some View {
        let profile = model.profile(device.profileID)
        let state = model.state(of: device.id)
        let job = model.deviceJobs[device.id]
        HStack(spacing: 8) {
            StateDot(active: state.isActive, busy: job != nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).emphasized().lineLimit(1)
                Text(job?.title ?? (state.isActive ? state.title : profile?.name ?? device.profileID))
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            Spacer()
            if let job {
                ProgressView(value: job.progress).frame(width: 60)
            } else if let fw = model.firmware(device.firmwareID) {
                Text(fw.version).font(.caption).foregroundColor(.gray)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A coloured dot for a device's power state.
struct StateDot: View {
    let active: Bool
    var busy = false

    var body: some View {
        (busy ? Color.orange : active ? Color.green : Color.gray.opacity(0.5))
            .frame(width: 9, height: 9)
            .cornerRadius(5)
    }
}

// MARK: - Device toolbar

struct DeviceToolbar: View {
    @Environment(\.openWindow) var openWindow
    var model: AppModel
    let device: VirtualDevice
    @Binding var showConsole: Bool
    @Binding var showInspector: Bool
    @Binding var showSettings: Bool
    @State var confirmErase = false
    @Environment(\.revealFile) var revealFile

    var body: some View {
        let session = model.session(device.id)
        let active = session.state.isActive
        let profile = model.profile(device.profileID)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.headline)
                Text(model.firmware(device.firmwareID).map { "HyperOS \($0.version) · \(session.state.title)" } ?? session.state.title)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            Spacer()
            if active {
                Button("Shut Down") { model.shutdown(device.id) }
                    .disabled(session.state == .stopping)
            } else {
                Button("Boot") { model.boot(device.id) }
                    .disabled(model.deviceJobs[device.id] != nil)
            }
            Button(session.state == .paused ? "Resume" : "Pause") {
                Task { session.state == .paused ? await session.resume() : await session.pause() }
            }
            .disabled(session.state != .running && session.state != .paused)
            Menu("More") {
                Button("Restart") { model.restart(device.id) }.disabled(!active)
                Button("Force Quit") { session.forceQuit() }.disabled(!active)
                Divider()
                Button("Save Screenshot") { screenshot(session) }.disabled(!active)
                Button("Show Logs") { revealFile?(model.library.paths(for: device).logs) }
                Divider()
                Button("Erase All Content and Settings…") { confirmErase = true }.disabled(active)
            }
            if let profile {
                ForEach(profile.buttons) { button in
                    Button(button.title) { Task { await session.press(button.qcode) } }
                        .disabled(session.state != .running)
                        .help("Press \(button.title)")
                }
            }
            Divider().frame(height: 20)
            Button("Settings") { showSettings = true }
            Button(showConsole ? "Hide Console" : "Console") { showConsole.toggle() }
            Button("Files") { openWindow(id: "files") }
            Button(showInspector ? "Hide Inspector" : "Inspector") { showInspector.toggle() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .alert("Erase “\(device.name)”?", isPresented: $confirmErase) {
            Button("Erase") { model.eraseDevice(device.id) }
            Button("Cancel") {}
        }
    }

    private func screenshot(_ session: DeviceSession) {
        guard let png = session.screenshotPNG() else { return }
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
        let url = dir.appendingPathComponent("\(device.name) \(stamp).png")
        do {
            try png.write(to: url)
            model.report("Screenshot saved", url.path)
        } catch {
            model.report(error, "Couldn’t save the screenshot")
        }
    }
}
