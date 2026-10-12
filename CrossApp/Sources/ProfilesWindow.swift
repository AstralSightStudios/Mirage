import Foundation
import MirageKit
import SwiftCrossUI

/// Device profiles: built-in boards and user variants of them.
struct ProfilesWindow: View {
    var model: AppModel
    @State var selection: String?

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    List(model.profiles, selection: $selection) { p in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name + (p.builtin ? "" : " (custom)")).lineLimit(1)
                            Footnote("\(p.id) · \(p.chip)")
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                Menu("New Profile") {
                    ForEach(model.profiles) { p in
                        Button("Based on \(p.name)") { duplicate(p) }
                    }
                }
            }
            .padding(10)
            .frame(minWidth: 250)
        } detail: {
            if let p = model.profile(selection ?? "") {
                ProfileEditor(model: model, profile: p, onDuplicate: { duplicate(p) })
            } else {
                ContentUnavailableView {
                    Text("Select a Profile")
                }
            }
        }
        .onAppear {
            if selection == nil { selection = model.profiles.first?.id }
        }
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
    var model: AppModel
    let profile: DeviceProfile
    let onDuplicate: () -> Void
    @State var p: DeviceProfile?
    @State var prefixes = ""
    @State var confirmDelete = false

    var body: some View {
        let locked = profile.builtin
        let edited = Binding(get: { p ?? profile }, set: { p = $0 })
        let current = p ?? profile
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(current.name).font(.title2)
                    Footnote(current.notes.isEmpty ? "\(current.chip) · board \(current.qemuBoard)" : current.notes)
                    if locked {
                        HStack {
                            Footnote("Built-in profiles mirror the boards in qemu-miwear.")
                            Button("Duplicate to Customize") { onDuplicate() }
                        }
                    }
                    InspectorSection("Identity") {
                        field("Name", edited.name)
                        InfoRow(label: "Identifier", value: current.id)
                        HStack {
                            Text("Family")
                            Picker(of: DeviceProfile.Family.allCases.map(\.title), selection: Binding(
                                get: { current.family.title },
                                set: { t in if let f = DeviceProfile.Family.allCases.first(where: { $0.title == t }) { p = with(current) { $0.family = f } } }))
                        }
                        field("Firmware products", $prefixes)
                        field("Accent (hex)", edited.accent)
                        field("Notes", edited.notes)
                    }
                    InspectorSection("Emulator") {
                        field("Chip (CHIP=)", edited.chip)
                        field("QEMU board", edited.qemuBoard)
                        numberField("Console UART", edited.consoleUART)
                        numberField("UARTs", edited.uartCount)
                    }
                    InspectorSection("Display") {
                        numberField("Width", edited.screen.width)
                        numberField("Height", edited.screen.height)
                        Toggle("Round screen", isOn: Binding(get: { current.screen.shape == .circle },
                                                             set: { round in p = with(current) { $0.screen.shape = round ? .circle : .roundedRect } }))
                        if current.screen.shape == .roundedRect {
                            HStack {
                                Text("Corner radius")
                                TextField("0", value: edited.screen.cornerRadius).frame(width: 90)
                            }
                        }
                    }
                    InspectorSection("Hardware Buttons") {
                        ForEach(current.buttons) { b in
                            HStack {
                                Text(b.title)
                                Spacer()
                                Text(b.qcode).foregroundColor(.gray)
                                Text(b.placement.rawValue).foregroundColor(.gray)
                                Button("Remove") { p = with(current) { $0.buttons.removeAll { $0.id == b.id } } }
                            }
                        }
                        Button("Add Button") {
                            p = with(current) {
                                $0.buttons.append(.init(id: UUID().uuidString, title: "Button", qcode: "home",
                                                        placement: .rightLower, symbol: "button.horizontal.top.press"))
                            }
                        }
                        Footnote("The key codes the board’s gpio-keys device listens for (hw/arm/bes_board.c).")
                    }
                    InspectorSection("Storage") {
                        Toggle("Persistent boot NOR (flash-image)", isOn: edited.storage.mainNOR)
                        Toggle("Sensor hub NOR", isOn: Binding(get: { current.storage.sensorNORSize != nil },
                                                              set: { on in p = with(current) { $0.storage.sensorNORSize = on ? 0x80_0000 : nil } }))
                        InfoRow(label: "Mass storage", value: current.storage.kindTitle)
                        if current.storage.emmc != nil {
                            HStack {
                                Text("eMMC size (GiB)")
                                TextField("8", value: Binding(get: { current.storage.emmc?.sizeGiB ?? 8 },
                                                              set: { v in p = with(current) { $0.storage.emmc?.sizeGiB = max(1, min(64, v)) } }))
                                    .frame(width: 90)
                            }
                        }
                    }
                    InspectorSection("Generated Identities") {
                        field("Device ID prefix", edited.defaults.didPrefix)
                        field("Serial prefix", edited.defaults.psnPrefix)
                    }
                }
                .padding(16)
                .disabled(locked)
            }
            if !locked {
                Divider()
                HStack {
                    Button("Delete Profile…") { confirmDelete = true }
                    Spacer()
                    Button("Revert") { reset() }
                    Button("Save") {
                        var q = current
                        q.productPrefixes = prefixes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        model.saveProfile(q)
                        p = nil
                    }
                }
                .padding(12)
            }
        }
        .onAppear { reset() }
        .onChange(of: profile.id) { reset() }
        .alert("Delete \(current.name)?", isPresented: $confirmDelete) {
            Button("Delete") { model.deleteProfile(current.id) }
            Button("Cancel") {}
        }
    }

    private func reset() {
        p = nil
        prefixes = profile.productPrefixes.joined(separator: ", ")
    }

    private func with(_ base: DeviceProfile, _ f: (inout DeviceProfile) -> Void) -> DeviceProfile {
        var c = base
        f(&c)
        return c
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, text: text).frame(width: 260)
        }
    }

    private func numberField(_ title: String, _ value: Binding<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value).frame(width: 90)
        }
    }
}
