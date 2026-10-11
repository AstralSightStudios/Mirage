import MirageKit
import SwiftUI

/// AuthKey and the rest of the band's binding state, plus its factory
/// identity. Written into the factory partition (persist.miwear_* and
/// ro.factory.*), so they survive erases and are what companion apps need.
struct BindingTab: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    @State private var draft: VirtualDevice?
    @State private var revealKeys = false

    var body: some View {
        let d = draft ?? device
        let changed = draft != nil && draft != device
        let active = model.state(of: device.id).isActive
        let pending = ImageBuilder.factoryProperties(identity: device.identity, binding: device.binding) != device.storage.factoryProperties
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection {
                Toggle(isOn: bind(\.binding.bound)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bound to a phone")
                        Text(d.binding.bound ? "Boots past setup; A companion app connects with the AuthKey."
                                             : "Boots into the setup wizard, unbound.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.vertical, 8)
            }
            if d.binding.bound {
                InspectorSection(title: "AuthKey") {
                    KeyField(title: "AuthKey", text: bind(\.binding.authKey), reveal: true)
                    HStack {
                        Button("Generate New Key") { update { $0.binding.authKey = BindInfo.randomKey() } }
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(d.binding.authKey, forType: .string)
                        }
                    }
                    .controlSize(.small)
                    .padding(.vertical, 8)
                }
                Text("The band’s persist.miwear_token_key. Companion apps (and Mirage’s Apps tab) authenticate with it; a new key means pairing again.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 4)
                InspectorSection(title: "Bind Keys") {
                    TextRow(title: "User ID", text: bind(\.binding.userID))
                    KeyField(title: "Beacon Key", text: bind(\.binding.beaconKey), reveal: revealKeys)
                    KeyField(title: "IR Key", text: bind(\.binding.irKey), reveal: revealKeys)
                    TextRow(title: "Sequence", text: bind(\.binding.seqnum))
                    HStack {
                        Toggle("Show keys", isOn: $revealKeys).toggleStyle(.checkbox)
                        Spacer()
                        Button("Regenerate") {
                            update {
                                $0.binding.beaconKey = BindInfo.randomKey()
                                $0.binding.irKey = BindInfo.randomKey()
                            }
                        }
                    }
                    .controlSize(.small)
                    .padding(.vertical, 8)
                }
            }
            InspectorSection(title: "Factory Identity") {
                TextRow(title: "Device ID", text: bind(\.identity.did))
                TextRow(title: "Serial", text: bind(\.identity.serial))
                TextRow(title: "Bluetooth", text: bind(\.identity.bluetoothAddress))
                HStack {
                    Spacer()
                    Button("Generate New Identity") {
                        if let p = model.profile(device.profileID) {
                            update { $0.identity = FactoryIdentity.generate(for: p).with(extra: $0.identity.extra) }
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 8)
            }
            ExtraProperties(props: bind(\.identity.extra))
            if let error = validation(d) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).padding(.top, 10)
            }
            HStack {
                if changed {
                    Button("Revert") { draft = nil }
                }
                Spacer()
                Button(active ? "Save for Next Boot" : "Save") {
                    guard let draft else { return }
                    model.update(draft, rewriteFactory: true)
                    self.draft = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(!changed || validation(d) != nil)
            }
            .padding(.top, 14)
            if pending && !changed {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                    Text(active ? "Changes are written into the factory partition after the device shuts down."
                                : "The factory partition is out of date.")
                    Spacer()
                    if !active { Button("Write Now") { model.applyPendingFactory(device.id) }.controlSize(.small) }
                }
                .font(.caption)
                .padding(.top, 8)
            }
        }
        .onChange(of: device.id) { draft = nil }
        .onChange(of: model.state(of: device.id)) { _, s in
            if s == .stopped { model.applyPendingFactory(device.id) }
        }
    }

    private func bind<T>(_ kp: WritableKeyPath<VirtualDevice, T>) -> Binding<T> {
        Binding(get: { (draft ?? device)[keyPath: kp] }, set: { v in update { $0[keyPath: kp] = v } })
    }

    private func update(_ f: (inout VirtualDevice) -> Void) {
        var d = draft ?? device
        f(&d)
        draft = d
    }

    private func validation(_ d: VirtualDevice) -> String? {
        do {
            try d.identity.validate()
            try d.binding.validate()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private struct TextRow: View {
    let title: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 9)
    }
}

private struct KeyField: View {
    let title: String
    @Binding var text: String
    var reveal: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Group {
                if reveal {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.callout.monospaced())
            .foregroundStyle(BindInfo.isValidKey(text) ? Color.secondary : Color.orange)
        }
        .padding(.vertical, 9)
    }
}

private struct ExtraProperties: View {
    @Binding var props: [FactoryIdentity.Property]
    @State private var key = ""
    @State private var value = ""

    var body: some View {
        InspectorSection(title: "Extra Factory Properties") {
            ForEach(props) { p in
                HStack {
                    Text(p.key).font(.callout.monospaced())
                    Spacer()
                    Text(p.value).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Button { props.removeAll { $0.key == p.key } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 6)
            }
            HStack {
                TextField("key", text: $key).font(.callout.monospaced())
                TextField("value", text: $value).font(.callout.monospaced())
                Button {
                    let k = key.trimmingCharacters(in: .whitespaces)
                    guard !k.isEmpty else { return }
                    props.removeAll { $0.key == k }
                    props.append(.init(key: k, value: value))
                    key = ""
                    value = ""
                } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.vertical, 8)
        }
    }
}

extension FactoryIdentity {
    func with(extra: [Property]) -> FactoryIdentity {
        var c = self
        c.extra = extra
        return c
    }
}
