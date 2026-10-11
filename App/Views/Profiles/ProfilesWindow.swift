import MirageKit
import SwiftUI

/// Device profiles: built-in boards and user variants of them.
struct ProfilesWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var boards: [String] = []

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Built In") {
                    ForEach(model.profiles.filter(\.builtin)) { row($0) }
                }
                let custom = model.profiles.filter { !$0.builtin }
                if !custom.isEmpty {
                    Section("Custom") {
                        ForEach(custom) { row($0) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .toolbar {
                ToolbarItem {
                    Menu {
                        ForEach(model.profiles) { p in
                            Button("Based on \(p.name)") { duplicate(p) }
                        }
                    } label: { Label("New Profile", systemImage: "plus") }
                }
            }
        } detail: {
            if let p = model.profile(selection ?? "") {
                ProfileEditor(profile: p, boards: boards, onDuplicate: { duplicate(p) })
                    .id(p.id)
            } else {
                ContentUnavailableView("Select a Profile", systemImage: "cpu")
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            if selection == nil { selection = model.profiles.first?.id }
            Task.detached {
                let b = QEMULocator.locate().map(QEMULocator.boards) ?? []
                await MainActor.run { boards = b }
            }
        }
    }

    private func row(_ p: DeviceProfile) -> some View {
        HStack(spacing: 10) {
            DeviceGlyph(profile: p, size: 28, active: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).lineLimit(1)
                Text("\(p.id) · \(p.chip)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if p.builtin { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tertiary) }
        }
        .tag(p.id)
    }

    private func duplicate(_ p: DeviceProfile) {
        var c = p
        var n = 1
        repeat {
            c.id = "\(p.id)-custom\(n == 1 ? "" : String(n))"
            n += 1
        } while model.profile(c.id) != nil
        c.name = "\(p.name) (Custom)"
        c.builtin = false
        model.saveProfile(c)
        selection = c.id
    }
}

private struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    let profile: DeviceProfile
    let boards: [String]
    let onDuplicate: () -> Void
    @State private var p: DeviceProfile
    @State private var prefixes = ""
    @State private var confirmDelete = false

    init(profile: DeviceProfile, boards: [String], onDuplicate: @escaping () -> Void) {
        self.profile = profile
        self.boards = boards
        self.onDuplicate = onDuplicate
        _p = State(initialValue: profile)
        _prefixes = State(initialValue: profile.productPrefixes.joined(separator: ", "))
    }

    var body: some View {
        let locked = profile.builtin
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                DeviceChrome(profile: p, scale: 0.32) { Color.black }
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.name).font(.title2.weight(.semibold))
                    Text(p.notes.isEmpty ? "\(p.chip) · board \(p.qemuBoard)" : p.notes)
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if locked {
                        HStack {
                            Text("Built-in profiles mirror the boards in qemu-miwear.").font(.caption).foregroundStyle(.secondary)
                            Button("Duplicate to Customize", action: onDuplicate).controlSize(.small)
                        }
                    }
                }
                Spacer()
            }
            .padding(20)
            Divider()
            Form {
                Section("Identity") {
                    TextField("Name", text: $p.name)
                    LabeledContent("Identifier", value: p.id)
                    Picker("Family", selection: $p.family) {
                        ForEach(DeviceProfile.Family.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField("Firmware products", text: $prefixes, prompt: Text("miwear.watch.p67, …"))
                    ColorPicker("Accent", selection: Binding(get: { Color(hex: p.accent) ?? .gray }, set: { p.accent = $0.hexString }))
                    TextField("Notes", text: $p.notes, axis: .vertical).lineLimit(1...3)
                }
                Section("Emulator") {
                    TextField("Chip (CHIP=)", text: $p.chip)
                    if boards.isEmpty {
                        TextField("QEMU board", text: $p.qemuBoard)
                    } else {
                        Picker("QEMU board", selection: $p.qemuBoard) {
                            ForEach(Array(Set(boards + [p.qemuBoard])).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Stepper("Console UART: \(p.consoleUART)", value: $p.consoleUART, in: 0...7)
                    Stepper("UARTs: \(p.uartCount)", value: $p.uartCount, in: 1...8)
                }
                Section("Display") {
                    HStack {
                        TextField("Width", value: $p.screen.width, format: .number)
                        Text("×")
                        TextField("Height", value: $p.screen.height, format: .number)
                    }
                    Picker("Shape", selection: $p.screen.shape) {
                        Text("Rounded Rectangle").tag(DeviceProfile.Screen.Shape.roundedRect)
                        Text("Circle").tag(DeviceProfile.Screen.Shape.circle)
                    }
                    if p.screen.shape == .roundedRect {
                        LabeledContent("Corner radius") {
                            Slider(value: $p.screen.cornerRadius, in: 0...Double(min(p.screen.width, p.screen.height) / 2))
                        }
                    }
                }
                Section("Hardware Buttons") {
                    ForEach($p.buttons) { $b in
                        HStack {
                            TextField("Title", text: $b.title)
                            TextField("QEMU key", text: $b.qcode).frame(width: 90).font(.body.monospaced())
                            Picker("", selection: $b.placement) {
                                Text("Crown").tag(DeviceProfile.HardwareButton.Placement.crown)
                                Text("Right, upper").tag(DeviceProfile.HardwareButton.Placement.rightUpper)
                                Text("Right, lower").tag(DeviceProfile.HardwareButton.Placement.rightLower)
                                Text("Left").tag(DeviceProfile.HardwareButton.Placement.left)
                            }
                            .labelsHidden()
                            .frame(width: 130)
                            Button { p.buttons.removeAll { $0.id == b.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Button") {
                        p.buttons.append(.init(id: UUID().uuidString, title: "Button", qcode: "home",
                                               placement: .rightLower, symbol: "button.horizontal.top.press"))
                    }
                    Text("The key codes the board’s gpio-keys device listens for (hw/arm/bes_board.c).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                StorageEditor(storage: $p.storage)
                Section("Generated Identities") {
                    TextField("Device ID prefix", text: $p.defaults.didPrefix)
                    TextField("Serial prefix", text: $p.defaults.psnPrefix)
                }
            }
            .formStyle(.grouped)
            .disabled(locked)
            if !locked {
                Divider()
                HStack {
                    Button("Delete Profile…", role: .destructive) { confirmDelete = true }
                    Spacer()
                    Button("Revert") { p = profile; prefixes = profile.productPrefixes.joined(separator: ", ") }
                    Button("Save") {
                        var q = p
                        q.productPrefixes = prefixes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        model.saveProfile(q)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(12)
            }
        }
        .confirmationDialog("Delete \(p.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteProfile(p.id) }
        }
    }
}

private struct StorageEditor: View {
    @Binding var storage: StorageLayout

    var body: some View {
        Section("Storage") {
            Toggle("Persistent boot NOR (flash-image)", isOn: $storage.mainNOR)
            Toggle("Sensor hub NOR", isOn: Binding(get: { storage.sensorNORSize != nil },
                                                  set: { storage.sensorNORSize = $0 ? 0x80_0000 : nil }))
            Picker("Mass storage", selection: Binding(get: { storage.nand != nil ? 1 : storage.emmc != nil ? 2 : 0 }, set: { v in
                storage.nand = v == 1 ? (storage.nand ?? DeviceProfile.p67.storage.nand) : nil
                storage.emmc = v == 2 ? (storage.emmc ?? DeviceProfile.q63.storage.emmc) : nil
            })) {
                Text("None").tag(0)
                Text("SPI NAND").tag(1)
                Text("eMMC").tag(2)
            }
            if let nand = Binding($storage.nand) {
                TextField("Resource image", text: nand.resourceImage)
                HStack {
                    TextField("Blocks", value: nand.blocks, format: .number)
                    TextField("Pages/block", value: nand.pagesPerBlock, format: .number)
                    TextField("Page", value: nand.pageSize, format: .number)
                    TextField("OOB", value: nand.oobSize, format: .number)
                }
                .font(.callout)
            }
            if let emmc = Binding($storage.emmc) {
                Stepper("Size: \(emmc.wrappedValue.sizeGiB) GiB", value: emmc.sizeGiB, in: 1...64)
                TextField("romfs partitions", text: Binding(get: { emmc.wrappedValue.romfs.joined(separator: ", ") }, set: {
                    emmc.wrappedValue.romfs = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }), axis: .vertical)
                .font(.callout.monospaced())
                ForEach(emmc.blank) { $b in
                    HStack {
                        TextField("Partition", text: $b.name).font(.callout.monospaced())
                        TextField("MiB", value: $b.mib, format: .number).frame(width: 80)
                        Text("MiB").foregroundStyle(.secondary)
                    }
                }
            }
        }
        Section("Factory Partition (littlefs)") {
            Picker("Flash", selection: $storage.factory.flash) {
                ForEach(FactoryPartition.Flash.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField("Offset", value: $storage.factory.offset, format: .number)
            HStack {
                TextField("Block size", value: $storage.factory.blockSize, format: .number)
                TextField("Blocks", value: $storage.factory.blockCount, format: .number)
                TextField("I/O size", value: $storage.factory.ioSize, format: .number)
            }
            Picker("On-disk version", selection: $storage.factory.diskVersion) {
                Text("2.0").tag(UInt32(0x0002_0000))
                Text("2.1").tag(UInt32(0x0002_0001))
            }
        }
    }
}

extension EMMCSpec.Blank: Identifiable {
    public var id: String { name }
}
