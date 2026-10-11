import MirageKit
import SwiftUI
import UniformTypeIdentifiers

struct NewDeviceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    var initialFirmware: String?

    @State private var firmwareID: String?
    @State private var profileID: String?
    @State private var name = ""
    @State private var binding = BindInfo.generate()
    @State private var options = RuntimeOptions()
    @State private var identity: FactoryIdentity?
    @State private var importing = false
    @State private var advanced = false

    var body: some View {
        let firmware = firmwareID.flatMap(model.firmware)
        let candidates = firmware.map { fw in model.profiles.filter { $0.runs(fw) } } ?? []
        let profile = candidates.first { $0.id == profileID } ?? candidates.first
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                firmwareList
                    .frame(width: 300)
                Divider()
                Form {
                    if let firmware, let profile {
                        Section {
                            HStack(spacing: 14) {
                                DeviceGlyph(profile: profile, size: 46, active: true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(firmware.marketingName).font(.headline)
                                    Text("HyperOS \(firmware.version) · \(profile.chip.uppercased()) · \(profile.storage.kindTitle)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            TextField("Name", text: $name, prompt: Text(firmware.marketingName))
                            if candidates.count > 1 {
                                Picker("Profile", selection: Binding(get: { profile.id }, set: { profileID = $0 })) {
                                    ForEach(candidates) { Text($0.name).tag($0.id) }
                                }
                            } else {
                                LabeledContent("Profile", value: profile.name)
                            }
                        }
                        Section {
                            Toggle("Bound to a phone", isOn: $binding.bound)
                            if binding.bound {
                                LabeledContent("AuthKey") {
                                    HStack {
                                        TextField("", text: $binding.authKey).font(.body.monospaced()).labelsHidden()
                                        Button { binding.authKey = BindInfo.randomKey() } label: { Image(systemName: "arrow.clockwise") }
                                            .buttonStyle(.borderless)
                                            .help("Generate")
                                    }
                                }
                            }
                        } header: { Text("Binding") } footer: {
                            Text(binding.bound
                                 ? "The device starts out already bound, so AstroBox can connect with this AuthKey. Use the key of an existing AstroBox setup to reuse it."
                                 : "The device starts in the setup wizard. Offline first-time binding isn’t possible with this firmware.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Section("Boot") {
                            Toggle("NuttX shell on the console", isOn: $options.shell)
                            Toggle("Bluetooth bridge for AstroBox", isOn: $options.bluetoothBridge)
                        }
                        if let id = identity {
                            Section("Factory Identity", isExpanded: $advanced) {
                                TextField("Device ID", text: Binding(get: { id.did }, set: { identity = id.withDID($0) }))
                                TextField("Serial", text: Binding(get: { id.serial }, set: { identity = id.withSerial($0) }))
                                TextField("Bluetooth", text: Binding(get: { id.bluetoothAddress }, set: { identity = id.withAddress($0) }))
                            }
                        }
                    } else {
                        ContentUnavailableView("Choose a Firmware", systemImage: "shippingbox",
                                               description: Text("Pick an official firmware package on the left, import one, or download one from MiWear Firmware Archives."))
                    }
                }
                .formStyle(.grouped)
                .onChange(of: firmwareID) { profileID = nil }
                .task(id: profile?.id) {
                    identity = profile.map { FactoryIdentity.generate(for: $0) }
                }
            }
            Divider()
            HStack {
                Button("Import Package…") { importing = true }
                Button("Firmware Archives…") {
                    openWindow(id: "archives")
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    guard let firmware, let profile else { return }
                    model.createDevice(name: name, firmware: firmware, profile: profile, binding: binding,
                                       options: options, identity: identity ?? FactoryIdentity.generate(for: profile))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(firmware == nil || profile == nil || (binding.bound && !BindInfo.isValidKey(binding.authKey)))
            }
            .padding()
        }
        .frame(width: 780, height: 540)
        .onAppear {
            firmwareID = initialFirmware ?? model.firmwares.first(where: { fw in model.profiles.contains { $0.runs(fw) } })?.id
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .data, .folder]) { r in
            if case .success(let url) = r { model.importFirmware(at: url) }
        }
    }

    private var firmwareList: some View {
        List(selection: $firmwareID) {
            let grouped = Dictionary(grouping: model.firmwares) { $0.marketingName }
            ForEach(grouped.keys.sorted(), id: \.self) { key in
                Section(key) {
                    ForEach(grouped[key]!) { fw in
                        let runs = model.profiles.contains { $0.runs(fw) }
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("HyperOS \(fw.version)")
                                Text(fw.product).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !runs {
                                Text("No profile").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .tag(fw.id)
                        .disabled(!runs)
                    }
                }
            }
            if !model.archive.importsInProgress.isEmpty {
                Section("Importing") {
                    ForEach(model.archive.importsInProgress, id: \.0) { path, t in
                        VStack(alignment: .leading) {
                            Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                            ProgressView(value: t.progress)
                        }
                    }
                }
            }
        }
        .overlay {
            if model.firmwares.isEmpty && model.archive.importsInProgress.isEmpty {
                ContentUnavailableView("No Firmware", systemImage: "shippingbox",
                                       description: Text("Import an official full OTA package or download one."))
            }
        }
    }
}

private extension FactoryIdentity {
    func withDID(_ s: String) -> FactoryIdentity { var c = self; c.did = s; return c }
    func withSerial(_ s: String) -> FactoryIdentity { var c = self; c.serial = s; return c }
    func withAddress(_ s: String) -> FactoryIdentity { var c = self; c.bluetoothAddress = s; return c }
}
