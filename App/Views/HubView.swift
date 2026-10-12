import MirageKit
import SwiftUI

/// The main window, modelled on Xcode's Device Hub: devices on the left,
/// the selected device in the middle, its details on the right.
struct HubView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("inspector") private var showInspector = true
    @SceneStorage("console") private var showConsole = false
    @SceneStorage("inspectorTab") private var inspectorTab: InspectorTab = .info
    @State private var zoom: ZoomMode = .natural
    @State private var scaleBox = ScaleBox()
    @AppStorage("consoleHeight") private var consoleHeight: Double = 280
    @State private var showSettings = false
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            DeviceSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .inspector(isPresented: $showInspector) {
            Group {
                if let d = model.device(model.selection) {
                    InspectorView(device: d, tab: $inspectorTab)
                } else {
                    Color.clear
                }
            }
            .inspectorColumnWidth(min: 290, ideal: 330, max: 440)
            .toolbar {
                ToolbarSpacer(.flexible, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showSettings = true } label: { Label("Device Settings", systemImage: "slider.horizontal.3") }
                        .disabled(model.selection == nil)
                    Button { showConsole.toggle() } label: { Label("Console", systemImage: "doc.text") }
                        .disabled(model.selection == nil)
                        .help("Toggle NSH Console")
                    Button { if let id = model.selection { openWindow(id: "files", value: id) } } label: {
                        Label("Files", systemImage: "folder")
                    }
                    .disabled(model.selection == nil)
                    .help("Browse the device's files")
                    Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                }
            }
        }
        .sheet(isPresented: $model.showNewDevice) {
            NewDeviceSheet(initialFirmware: model.newDeviceFirmware)
        }
        .sheet(isPresented: $showSettings) {
            if let d = model.device(model.selection) { DeviceSettingsSheet(device: d) }
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: a.message.isEmpty ? nil : Text(a.message))
        }
        .focusedSceneValue(\.hubActions, HubActions(showConsole: $showConsole, zoom: $zoom))
    }

    @ViewBuilder
    private var detail: some View {
        if let d = model.device(model.selection) {
            VStack(spacing: 0) {
                DeviceStage(device: d, zoom: $zoom, scaleBox: scaleBox)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showConsole {
                    DrawerHandle(height: $consoleHeight)
                    ConsolePane(device: d)
                        .frame(height: consoleHeight)
                }
            }
            // Keep the split column's minimum independent of the console drawer.
            // Otherwise its hosting controller can feed changing minima back into layout.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .navigationTitle(d.name)
            .navigationSubtitle(model.firmware(d.firmwareID).map { "HyperOS \($0.version)" } ?? "")
            .toolbar {
                DeviceToolbar(device: d, showConsole: $showConsole)
            }
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
        } else {
            ContentUnavailableView {
                Label("No Devices", systemImage: "applewatch.slash")
            } description: {
                Text("Create a device from an official firmware package.")
            } actions: {
                Button("New Device…") { model.newDevice() }
                Button("Browse Firmware Archives…") { openWindow(id: "archives") }
            }
        }
    }
}

/// Divider above the console; drag to resize it.
private struct DrawerHandle: View {
    @Binding var height: Double
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if start == nil { start = height }
                    height = min(700, max(140, (start ?? height) - v.translation.height))
                }
                .onEnded { _ in start = nil })
    }
}

struct HubActions {
    var showConsole: Binding<Bool>
    var zoom: Binding<ZoomMode>
}

extension FocusedValues {
    @Entry var hubActions: HubActions?
}

private struct DeviceToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    @Binding var showConsole: Bool

    var body: some ToolbarContent {
        let session = model.session(device.id)
        let profile = model.profile(device.profileID)
        let active = session.state.isActive

        ToolbarItemGroup {
            if let profile {
                ForEach(profile.buttons) { button in
                    Button {
                        Task { await session.press(button.qcode) }
                    } label: {
                        Label(button.title, systemImage: button.symbol)
                    }
                    .help("Press \(button.title)")
                    .disabled(session.state != .running)
                }
            }
            Button { screenshot(session) } label: { Label("Screenshot", systemImage: "camera") }
                .help("Save Screenshot")
                .disabled(!active)
            Button {
                showConsole.toggle()
            } label: {
                Label("Console", systemImage: "terminal")
            }
            .help("Toggle NSH Console")
        }

        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            if active {
                Button { model.shutdown(device.id) } label: { Label("Shut Down", systemImage: "stop.fill") }
                    .help("Shut Down")
                    .disabled(session.state == .stopping)
            } else {
                Button { model.boot(device.id) } label: { Label("Boot", systemImage: "play.fill") }
                    .help("Boot")
                    .disabled(model.deviceJobs[device.id] != nil)
            }
            Menu {
                Button("Restart") { model.restart(device.id) }.disabled(!active)
                if session.state == .paused {
                    Button("Resume") { Task { await session.resume() } }
                } else {
                    Button("Pause") { Task { await session.pause() } }.disabled(session.state != .running)
                }
                Button("Force Quit") { session.forceQuit() }.disabled(!active)
                Divider()
                Button("Copy QEMU Command Line") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.commandLine ?? "", forType: .string)
                }
                .disabled(session.commandLine == nil)
                Button("Show Logs in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.library.paths(for: device).logs])
                }
                Divider()
                Button("Erase All Content and Settings…") { model.eraseDevice(device.id) }.disabled(active)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }

    }

    private func screenshot(_ session: DeviceSession) {
        guard let png = session.screenshotPNG() else { return }
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".")
        let url = dir.appendingPathComponent("\(device.name) \(stamp).png")
        do {
            try png.write(to: url)
            NSSound(named: "Grab")?.play()
        } catch {
            model.report(error, "Couldn’t save the screenshot")
        }
    }
}

// MARK: - Sidebar

struct DeviceSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @AppStorage("sidebarFamily") private var family = "all"

    var body: some View {
        @Bindable var model = model
        let shown = model.devices.filter { d in
            (search.isEmpty || d.name.localizedCaseInsensitiveContains(search)
                || (model.firmware(d.firmwareID)?.version.contains(search) ?? false))
                && (family == "all" || model.profile(d.profileID)?.family.rawValue == family)
        }
        let running = shown.filter { model.state(of: $0.id).isActive }
        let idle = shown.filter { !model.state(of: $0.id).isActive }
        List(selection: $model.selection) {
            if !running.isEmpty {
                Section("Running") {
                    ForEach(running) { DeviceRow(device: $0).tag($0.id) }
                }
            }
            Section("Available") {
                ForEach(idle) { DeviceRow(device: $0).tag($0.id) }
            }
        }
        .searchable(text: $search, placement: .sidebar)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let d = model.device(id) {
                let active = model.state(of: id).isActive
                Button(active ? "Shut Down" : "Boot") { active ? model.shutdown(id) : model.boot(id) }
                Button("Duplicate") { model.duplicateDevice(id) }.disabled(active)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.library.deviceDirectory(d.id)]) }
                Divider()
                Button("Delete", role: .destructive) { model.deleteDevice(id) }.disabled(active)
            }
        } primaryAction: { ids in
            if let id = ids.first, !model.state(of: id).isActive { model.boot(id) }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.newDevice() } label: { Label("New Device", systemImage: "plus") }
                    .help("New Device")
                Menu {
                    Picker("Show", selection: $family) {
                        Text("All Devices").tag("all")
                        Text("Bands").tag(DeviceProfile.Family.band.rawValue)
                        Text("Watches").tag(DeviceProfile.Family.watch.rawValue)
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Firmware Archives…") { openWindow(id: "archives") }
                    Button("Device Profiles…") { openWindow(id: "profiles") }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease")
                }
            }
        }
    }
}

private struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice

    var body: some View {
        let profile = model.profile(device.profileID)
        let state = model.state(of: device.id)
        let job = model.deviceJobs[device.id]
        HStack(spacing: 10) {
            DeviceGlyph(profile: profile, size: 32, active: state.isActive)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(job?.title ?? (state.isActive ? state.title : profile?.name ?? device.profileID))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let job {
                ProgressView(value: job.progress).progressViewStyle(.circular).controlSize(.small)
            } else if let fw = model.firmware(device.firmwareID) {
                Text(fw.version).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Device settings

struct DeviceSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let device: VirtualDevice
    @State private var options = RuntimeOptions()
    @State private var extra = ""
    @State private var traces = ""
    @State private var port = ""

    var body: some View {
        let session = model.session(device.id)
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Toggle(isOn: $options.shell) {
                        Text("NuttX shell on the console")
                        Text("Starts the firmware’s own `sh` builtin at boot through the gdbstub, like a debug probe. The firmware is not modified.")
                    }
                    Toggle(isOn: $options.bluetoothBridge) {
                        Text("Bluetooth bridge")
                        Text("Serves the band’s radio as a standard HCI controller over TCP, for companion apps.")
                    }
                    if options.bluetoothBridge {
                        TextField("Port", text: $port, prompt: Text("Automatic"))
                            .help("Leave empty to pick a free port at every boot.")
                    }
                } header: { Text("Boot") }
                Section {
                    TextField("Log items (-d)", text: $options.debugLog, prompt: Text("e.g. guest_errors,unimp"))
                    TextField("Trace events (-trace)", text: $traces, prompt: Text("e.g. bes_btss_*, one per line"), axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Extra QEMU arguments", text: $extra, prompt: Text("one argument per line"), axis: .vertical)
                        .lineLimit(2...6)
                        .font(.body.monospaced())
                } header: { Text("Debugging") } footer: {
                    Text("Applied at the next boot. Logs go to the device’s Logs folder.").font(.caption).foregroundStyle(.secondary)
                }
                if let cmd = session.commandLine {
                    Section("Last Command Line") {
                        Text(cmd).font(.caption.monospaced()).textSelection(.enabled).lineLimit(8)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var d = device
                    var o = options
                    o.extraArguments = extra.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    o.traceEvents = traces.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    o.bluetoothPort = Int(port) ?? 0
                    d.options = o
                    model.update(d)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
        .onAppear {
            options = device.options
            extra = device.options.extraArguments.joined(separator: "\n")
            traces = device.options.traceEvents.joined(separator: "\n")
            port = device.options.bluetoothPort > 0 ? String(device.options.bluetoothPort) : ""
        }
    }
}
