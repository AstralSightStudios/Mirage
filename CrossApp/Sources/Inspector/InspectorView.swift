import Foundation
import MirageKit
import SwiftCrossUI

enum InspectorTab: String, CaseIterable {
    case info = "Info", apps = "Apps", storage = "Storage", binding = "Binding"
}

struct InspectorView: View {
    var model: AppModel
    let device: VirtualDevice
    @Binding var tab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            TabBar(tabs: InspectorTab.allCases, selection: $tab)
                .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .info: InfoTab(model: model, device: device)
                    case .apps: AppsTab(model: model, device: device)
                    case .storage: StorageTab(model: model, device: device)
                    case .binding: BindingTab(model: model, device: device)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Info

struct InfoTab: View {
    var model: AppModel
    let device: VirtualDevice
    @State var name = ""
    @State var nameFor: UUID?
    @State var confirmDelete = false
    @State var switchTo: Firmware?
    @Environment(\.revealFile) var revealFile

    var body: some View {
        let profile = model.profile(device.profileID)
        let fw = model.firmware(device.firmwareID)
        let session = model.session(device.id)
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection {
                HStack {
                    Text("Name")
                    TextField("Name", text: $name)
                        .onSubmit(perform: rename)
                    Button("Rename") { rename() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == device.name)
                }
                InfoRow(label: "Model", value: profile?.name ?? device.profileID)
                InfoRow(label: "OS", value: fw.map { "HyperOS \($0.version)" } ?? "Missing firmware")
            }
            InspectorSection {
                InfoRow(label: "Product", value: fw?.product ?? "")
                InfoRow(label: "Chip", value: profile?.chip.uppercased() ?? "")
                InfoRow(label: "Display", value: profile.map { "\($0.screen.width) × \($0.screen.height)\($0.screen.shape == .circle ? " round" : "")" } ?? "")
                InfoRow(label: "Storage", value: profile?.storage.kindTitle ?? "")
                InfoRow(label: "Device ID", value: device.identity.did)
                InfoRow(label: "Serial Number", value: device.identity.serial)
                InfoRow(label: "Bluetooth", value: device.identity.bluetoothAddress)
                InfoRow(label: "Identifier", value: device.id.uuidString)
            }
            InspectorSection("Runtime") {
                InfoRow(label: "State", value: session.state.title)
                if let pid = session.pid { InfoRow(label: "QEMU Process", value: "\(pid)") }
                if let port = session.bluetoothPort {
                    InfoRow(label: "Bluetooth Bridge", value: "127.0.0.1:\(port)")
                }
                InfoRow(label: "Shell", value: model.shellText(session.shell, device: device))
                InfoRow(label: "Last Booted", value: device.lastBootedAt.map(Format.relative) ?? "Never")
                InfoRow(label: "Created", value: Format.date(device.createdAt))
                if let cmd = session.commandLine {
                    Text(cmd).font(.caption).foregroundColor(.gray).lineLimit(6).textSelectionEnabled()
                }
            }
            if let fw, let profile {
                let others = model.firmwares.filter { profile.runs($0) && $0.id != fw.id }
                InspectorSection("Firmware") {
                    InfoRow(label: "Installed", value: fw.id)
                    if others.isEmpty {
                        Footnote("No other firmware for \(profile.name) in the library.")
                    } else {
                        Menu("Install Other Version") {
                            ForEach(others) { other in
                                Button("\(other.marketingName) \(other.version)") { switchTo = other }
                            }
                        }
                        .disabled(session.state.isActive || model.deviceJobs[device.id] != nil)
                    }
                }
            }
            HStack {
                Button("Show Files") { revealFile?(model.library.deviceDirectory(device.id)) }
                Spacer()
                Button("Duplicate") { model.duplicateDevice(device.id) }
                    .disabled(session.state.isActive)
                Button("Delete…") { confirmDelete = true }
                    .disabled(session.state.isActive)
            }
            .padding(.top, 14)
        }
        .onAppear { sync() }
        .onChange(of: device.id) { sync() }
        .alert("Delete “\(device.name)”? Its storage images, logs and pairing data are deleted.", isPresented: $confirmDelete) {
            Button("Delete Device") { model.deleteDevice(device.id) }
            Button("Cancel") {}
        }
        .alert(Binding(get: { switchTo.map { "Install \($0.version)? The firmware partitions are rewritten; user data survives when the new images fit." } },
                       set: { if $0 == nil { switchTo = nil } })) {
            Button("Install") { if let fw = switchTo { model.switchFirmware(device.id, to: fw) }; switchTo = nil }
            Button("Cancel") { switchTo = nil }
        }
    }

    private func sync() {
        name = device.name
        nameFor = device.id
    }

    private func rename() {
        var d = device
        d.name = name.trimmingCharacters(in: .whitespaces)
        if !d.name.isEmpty, d.name != device.name { model.update(d) }
    }
}

// MARK: - Storage

struct StorageTab: View {
    var model: AppModel
    let device: VirtualDevice
    @State var factory: [FactoryIdentity.Property] = []
    @State var factoryError: String?
    @State var partitions: [ImageBuilder.GPTPartition] = []
    @State var confirmErase = false
    @Environment(\.revealFile) var revealFile

    var body: some View {
        let profile = model.profile(device.profileID)
        let images = profile.map { DeviceStorage(library: model.library).images(of: device, profile: $0) } ?? []
        let active = model.state(of: device.id).isActive
        VStack(alignment: .leading, spacing: 0) {
            if let job = model.deviceJobs[device.id] {
                InspectorSection {
                    Text(job.title)
                    ProgressView(value: job.progress)
                    Footnote(job.detail)
                }
            }
            InspectorSection("Images") {
                ForEach(images) { img in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(img.role.title)
                            Spacer()
                            if img.exists {
                                Text(Format.bytes(img.size)).foregroundColor(.gray)
                                Button("Show") { revealFile?(img.url) }
                            } else {
                                Text("Missing").foregroundColor(.orange)
                            }
                        }
                        Footnote(img.role.detail + (img.allocated < img.size && img.exists ? " · \(Format.bytes(img.allocated)) on disk (sparse)" : ""))
                    }
                }
            }
            if let fwID = device.storage.contentFirmwareID {
                InspectorSection {
                    InfoRow(label: "Content From", value: fwID)
                    InfoRow(label: "Built", value: device.storage.builtAt.map(Format.relative) ?? "—")
                }
            }
            if !partitions.isEmpty {
                InspectorSection("eMMC Partitions") {
                    ForEach(partitions, id: \.name) { p in
                        InfoRow(label: p.name, value: Format.bytes(Int64(p.size)))
                    }
                }
            }
            InspectorSection("Factory Data (/misc/factory.prop)") {
                if let factoryError { Footnote(factoryError) }
                ForEach(factory) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Footnote(p.key)
                        Text(p.value).textSelectionEnabled()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Button("Erase All Content and Settings…") { confirmErase = true }
                    .disabled(active || model.deviceJobs[device.id] != nil)
                Footnote("Rebuilds every image from the firmware. The device keeps its identity and binding keys.")
            }
            .padding(.top, 14)
        }
        .task(id: "\(device.id)\(device.storage.builtAt?.timeIntervalSince1970 ?? 0)\(active)") { load() }
        .alert("Erase “\(device.name)”? All data on the device is lost.", isPresented: $confirmErase) {
            Button("Erase") { model.eraseDevice(device.id) }
            Button("Cancel") {}
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
        partitions = (try? ImageBuilder.readGPT(model.library.paths(for: device).emmc)) ?? []
    }
}
