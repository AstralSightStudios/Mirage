import MirageKit
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case info = "Info", apps = "Apps", storage = "Storage", binding = "Binding"
    var id: String { rawValue }
}

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    @Binding var tab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            ScrollView {
                Group {
                    switch tab {
                    case .info: InfoTab(device: device)
                    case .apps: AppsTab(device: device)
                    case .storage: StorageTab(device: device)
                    case .binding: BindingTab(device: device)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Building blocks (Device Hub style grouped rows)

struct InspectorSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            VStack(spacing: 0) {
                Group(subviews: content()) { subs in
                    ForEach(subs.indices, id: \.self) { i in
                        subs[i]
                        if i < subs.count - 1 { Divider() }
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.top, 10)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var mono = false
    var copyable = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            Text(value.isEmpty ? "—" : value)
                .foregroundStyle(.secondary)
                .font(mono ? .body.monospaced() : .body)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if copyable && !value.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: { Image(systemName: "doc.on.doc").font(.caption) }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
        .padding(.vertical, 9)
    }
}

// MARK: - Info

private struct InfoTab: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    @State private var name = ""
    @State private var confirmDelete = false

    var body: some View {
        let profile = model.profile(device.profileID)
        let fw = model.firmware(device.firmwareID)
        let session = model.session(device.id)
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection {
                HStack {
                    Text("Name")
                    Spacer()
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .onSubmit {
                            var d = device
                            d.name = name.trimmingCharacters(in: .whitespaces)
                            if !d.name.isEmpty { model.update(d) }
                        }
                }
                .padding(.vertical, 9)
                InfoRow(label: "Model", value: profile?.name ?? device.profileID)
                InfoRow(label: "OS", value: fw.map { "HyperOS \($0.version)" } ?? "Missing firmware")
            }
            InspectorSection {
                InfoRow(label: "Product", value: fw?.product ?? "")
                InfoRow(label: "Chip", value: profile?.chip.uppercased() ?? "")
                InfoRow(label: "Display", value: profile.map { "\($0.screen.width) × \($0.screen.height)\($0.screen.shape == .circle ? " round" : "")" } ?? "")
                InfoRow(label: "Storage", value: profile?.storage.kindTitle ?? "")
                InfoRow(label: "Device ID", value: device.identity.did, mono: true, copyable: true)
                InfoRow(label: "Serial Number", value: device.identity.serial, mono: true, copyable: true)
                InfoRow(label: "Bluetooth", value: device.identity.bluetoothAddress, mono: true, copyable: true)
                InfoRow(label: "Identifier", value: device.id.uuidString, mono: true, copyable: true)
            }
            InspectorSection(title: "Runtime") {
                InfoRow(label: "State", value: session.state.title)
                if let pid = session.pid { InfoRow(label: "QEMU Process", value: "\(pid)", mono: true) }
                if let port = session.bluetoothPort {
                    InfoRow(label: "Bluetooth Bridge", value: "127.0.0.1:\(port)", mono: true, copyable: true)
                }
                InfoRow(label: "Shell", value: shellText(session.shell))
                InfoRow(label: "Last Booted", value: device.lastBootedAt.map(Format.relative) ?? "Never")
                InfoRow(label: "Created", value: Format.date(device.createdAt))
            }
            if let fw, let profile {
                FirmwareSwitcher(device: device, profile: profile, current: fw)
            }
            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.library.deviceDirectory(device.id)])
                }
                Spacer()
                Button("Duplicate") { model.duplicateDevice(device.id) }
                    .disabled(session.state.isActive)
                Button("Delete…", role: .destructive) { confirmDelete = true }
                    .disabled(session.state.isActive)
            }
            .controlSize(.small)
            .padding(.top, 14)
        }
        .onAppear { name = device.name }
        .onChange(of: device.id) { name = device.name }
        .confirmationDialog("Delete “\(device.name)”?", isPresented: $confirmDelete) {
            Button("Delete Device", role: .destructive) { model.deleteDevice(device.id) }
        } message: {
            Text("Its storage images, logs and companion pairing data are moved out of the library and deleted.")
        }
    }

    private func shellText(_ s: DeviceSession.ShellStatus) -> String {
        switch s {
        case .disabled: return device.options.shell ? "Starts at boot" : "Off"
        case .injecting: return "Starting…"
        case .ready(let pid): return "NSH (task \(pid))"
        case .failed(let m): return "Failed: \(m)"
        case .unavailable: return "Unavailable"
        }
    }
}

private struct FirmwareSwitcher: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    let profile: DeviceProfile
    let current: Firmware
    @State private var target: Firmware?

    var body: some View {
        let others = model.firmwares.filter { profile.runs($0) && $0.id != current.id }
        InspectorSection(title: "Firmware") {
            InfoRow(label: "Installed", value: current.id, mono: true)
            HStack {
                Menu("Install Other Version") {
                    if others.isEmpty {
                        Text("No other firmware for \(profile.name) in the library")
                    }
                    ForEach(others) { fw in
                        Button("\(fw.marketingName) \(fw.version)") { target = fw }
                    }
                }
                .fixedSize()
                Spacer()
            }
            .padding(.vertical, 8)
            .disabled(model.state(of: device.id).isActive || model.deviceJobs[device.id] != nil)
        }
        .confirmationDialog("Install \(target?.version ?? "")?", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }), presenting: target) { fw in
            Button("Install \(fw.version)") { model.switchFirmware(device.id, to: fw) }
        } message: { _ in
            Text("The firmware partitions are rewritten in place; user data survives when the new images fit the existing layout.")
        }
    }
}

// MARK: - Storage

private struct StorageTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let device: VirtualDevice
    @State private var factory: [FactoryIdentity.Property] = []
    @State private var factoryError: String?
    @State private var partitions: [ImageBuilder.GPTPartition] = []
    @State private var confirmErase = false

    var body: some View {
        let profile = model.profile(device.profileID)
        let images = profile.map { DeviceStorage(library: model.library).images(of: device, profile: $0) } ?? []
        let active = model.state(of: device.id).isActive
        VStack(alignment: .leading, spacing: 0) {
            if let job = model.deviceJobs[device.id] {
                InspectorSection {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(job.title).font(.callout.weight(.medium))
                        ProgressView(value: job.progress)
                        Text(job.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Button("Browse Files…") { openWindow(id: "files", value: device.id) }
                Text(active ? "Opens the running device's file tree through its shell."
                     : "Opens /data and the romfs partitions straight from the storage images.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 10)
            InspectorSection(title: "Images") {
                ForEach(images) { img in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(img.role.title)
                            Spacer()
                            if img.exists {
                                Text(Format.bytes(img.size)).foregroundStyle(.secondary)
                                Button { NSWorkspace.shared.activateFileViewerSelecting([img.url]) } label: {
                                    Image(systemName: "magnifyingglass.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Show in Finder")
                            } else {
                                Text("Missing").foregroundStyle(.orange)
                            }
                        }
                        Text(img.role.detail + (img.allocated < img.size && img.exists ? " · \(Format.bytes(img.allocated)) on disk (sparse)" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
            if let fwID = device.storage.contentFirmwareID {
                InspectorSection {
                    InfoRow(label: "Content From", value: fwID, mono: true)
                    InfoRow(label: "Built", value: device.storage.builtAt.map(Format.relative) ?? "—")
                }
            }
            if !partitions.isEmpty {
                InspectorSection(title: "eMMC Partitions") {
                    ForEach(partitions, id: \.name) { p in
                        HStack {
                            Text(p.name).font(.callout.monospaced())
                            Spacer()
                            Text(Format.bytes(Int64(p.size))).foregroundStyle(.secondary).font(.callout)
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
            InspectorSection(title: "Factory Data (/misc/factory.prop)") {
                if let factoryError {
                    Text(factoryError).font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach(factory) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.key).font(.caption).foregroundStyle(.secondary)
                        Text(p.value).font(.callout.monospaced()).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Button("Erase All Content and Settings…") { confirmErase = true }
                    .disabled(active || model.deviceJobs[device.id] != nil)
                Text("Rebuilds every image from the firmware. The device keeps its identity and binding keys.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 14)
        }
        .task(id: "\(device.id)\(device.storage.builtAt?.timeIntervalSince1970 ?? 0)\(active)") { load() }
        .confirmationDialog("Erase “\(device.name)”?", isPresented: $confirmErase) {
            Button("Erase", role: .destructive) { model.eraseDevice(device.id) }
        } message: {
            Text("All data on the device is lost: /data, settings, installed watchfaces and apps.")
        }
    }

    private func load() {
        let storage = DeviceStorage(library: model.library)
        do {
            factory = try storage.readFactory(of: device)
            factoryError = nil
        } catch {
            factory = []
            factoryError = error.localizedDescription
        }
        let paths = model.library.paths(for: device)
        partitions = (try? ImageBuilder.readGPT(paths.emmc)) ?? []
    }
}
