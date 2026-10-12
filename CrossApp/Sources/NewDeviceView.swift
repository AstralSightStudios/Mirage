import Foundation
import MirageKit
import SwiftCrossUI

struct NewDeviceView: View {
    var model: AppModel
    var initialFirmware: String?
    @State var firmwareID: String?
    @State var profileID: String?
    @State var name = ""
    @State var binding = BindInfo.generate()
    @State var options = RuntimeOptions()
    @State var identity: FactoryIdentity?
    @State var identityFor: String?
    @Environment(\.dismiss) var dismiss
    @Environment(\.openWindow) var openWindow
    @Environment(\.chooseFile) var chooseFile

    var body: some View {
        let firmware = firmwareID.flatMap(model.firmware)
        let candidates = firmware.map { fw in model.profiles.filter { $0.runs(fw) } } ?? []
        let profile = candidates.first { $0.id == profileID } ?? candidates.first
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                firmwareList
                    .frame(width: 300)
                    .frame(maxHeight: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let firmware, let profile {
                            Text(firmware.marketingName).font(.headline)
                            Footnote("HyperOS \(firmware.version) · \(profile.chip.uppercased()) · \(profile.storage.kindTitle)")
                            HStack {
                                Text("Name")
                                TextField(firmware.marketingName, text: $name)
                            }
                            if candidates.count > 1 {
                                HStack {
                                    Text("Profile")
                                    Picker(of: candidates.map(\.name), selection: Binding(
                                        get: { profile.name },
                                        set: { n in profileID = candidates.first { $0.name == n }?.id }))
                                }
                            } else {
                                InfoRow(label: "Profile", value: profile.name)
                            }
                            InspectorSection("Binding") {
                                Toggle("Bound to a phone", isOn: $binding.bound)
                                if binding.bound {
                                    HStack {
                                        Text("AuthKey")
                                        TextField("32 hex digits", text: $binding.authKey)
                                        Button("Generate") { binding.authKey = BindInfo.randomKey() }
                                    }
                                }
                                Footnote(binding.bound
                                         ? "The device starts out already bound, so a companion app can connect with this AuthKey."
                                         : "The device starts in the setup wizard. Offline first-time binding isn’t possible with this firmware.")
                            }
                            InspectorSection("Boot") {
                                Toggle("NuttX shell on the console", isOn: $options.shell)
                                Toggle("Bluetooth bridge for companion apps", isOn: $options.bluetoothBridge)
                            }
                            if let id = identity {
                                InspectorSection("Factory Identity") {
                                    identityRow("Device ID", Binding(get: { id.did }, set: { v in identity?.did = v }))
                                    identityRow("Serial", Binding(get: { id.serial }, set: { v in identity?.serial = v }))
                                    identityRow("Bluetooth", Binding(get: { id.bluetoothAddress }, set: { v in identity?.bluetoothAddress = v }))
                                }
                            }
                        } else {
                            Text("Choose a Firmware").font(.headline)
                            Footnote("Pick an official firmware package on the left, import one, or download one from MiWear Firmware Archives.")
                        }
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button("Import Package…") { importPackage() }
                Button("Firmware Archives…") {
                    openWindow(id: "archives")
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    guard let firmware, let profile else { return }
                    model.createDevice(name: name, firmware: firmware, profile: profile, binding: binding,
                                       options: options, identity: identity ?? FactoryIdentity.generate(for: profile))
                    dismiss()
                }
                .disabled(firmware == nil || profile == nil || (binding.bound && !BindInfo.isValidKey(binding.authKey)))
            }
            .padding(12)
        }
        .frame(width: 780, height: 560)
        .onAppear {
            firmwareID = initialFirmware ?? model.firmwares.first(where: { fw in model.profiles.contains { $0.runs(fw) } })?.id
        }
        .onChange(of: profile?.id ?? "", initial: true) {
            // a fresh identity for each profile, like the macOS sheet
            guard identityFor != profile?.id else { return }
            identityFor = profile?.id
            identity = profile.map { FactoryIdentity.generate(for: $0) }
        }
    }

    private var firmwareList: some View {
        let runnable = model.firmwares.filter { fw in model.profiles.contains { $0.runs(fw) } }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Firmware").font(.headline).padding(.horizontal, 10).padding(.top, 10)
            ScrollView {
                List(runnable, selection: Binding(get: { firmwareID }, set: { firmwareID = $0; profileID = nil })) { fw in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(fw.marketingName) · HyperOS \(fw.version)")
                        Footnote(fw.product)
                    }
                }
            }
            if model.firmwares.count > runnable.count {
                Footnote("\(model.firmwares.count - runnable.count) firmware package(s) have no device profile.")
                    .padding(.horizontal, 10)
            }
            ForEach(model.archive.importsInProgress.map { ImportRow(path: $0.0, transfer: $0.1) }) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: row.path).lastPathComponent).lineLimit(1)
                    ProgressView(value: row.transfer.progress)
                }
                .padding(.horizontal, 10)
            }
        }
    }

    private func identityRow(_ title: String, _ text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, text: text).frame(width: 220)
        }
    }

    private func importPackage() {
        Task {
            guard let url = await chooseFile(title: "Import Firmware Package", defaultButtonLabel: "Import",
                                             allowSelectingDirectories: true) else { return }
            model.importFirmware(at: url)
        }
    }
}

/// An import in progress, for ForEach.
struct ImportRow: Identifiable {
    var id: String { path }
    let path: String
    let transfer: ArchiveModel.Transfer
}
