import MirageKit
import SwiftUI

/// The emulated battery: charge and charger plug, live on a running device
/// and remembered for its next boot.
struct BatteryControl: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    @State private var level: Double = Double(BatteryState.defaultLevel)
    @State private var charging = false
    @State private var editing = false

    var body: some View {
        let session = model.session(device.id)
        let profile = model.profile(device.profileID)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: BatteryControl.symbol(level: Int(level), charging: charging))
                    .font(.title2)
                    .foregroundStyle(charging ? .green : (level <= 20 ? .red : .primary))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Battery").font(.headline)
                    Text(session.state.isActive ? "Applies now" : "Applies at the next boot")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(level))%")
                    .font(.title3.monospacedDigit().weight(.medium))
            }
            Slider(value: $level, in: 0...100, step: 1) {
                Text("Charge")
            } minimumValueLabel: {
                Text("0").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("100").font(.caption2).foregroundStyle(.secondary)
            } onEditingChanged: { active in
                editing = active
                if !active { apply() }
            }
            .labelsHidden()
            HStack(spacing: 6) {
                ForEach([5, 20, 50, 80, 100], id: \.self) { v in
                    Button("\(v)%") {
                        level = Double(v)
                        apply()
                    }
                    .controlSize(.small)
                }
            }
            Toggle(isOn: Binding(get: { charging }, set: { charging = $0; apply() })) {
                Text("Charger connected")
            }
            .toggleStyle(.switch)
            Text(note(profile))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
        .task(id: session.battery) { load(session) }
        .onAppear { load(session) }
    }

    private func load(_ session: DeviceSession) {
        guard !editing else { return }
        let b = session.battery ?? device.options.battery ?? BatteryState()
        level = Double(b.level)
        charging = b.charging
    }

    private func apply() {
        let state = BatteryState(level: Int(level), charging: charging)
        let session = model.session(device.id)
        Task {
            do {
                try await session.setBattery(state)
                model.reload()
            } catch {
                model.report(error, "Couldn’t set the battery")
            }
        }
    }

    private func note(_ profile: DeviceProfile?) -> String {
        if profile?.chip == "best1700" {
            return "The watch reads its charge from a fuel gauge chip. Its charger chip isn’t emulated yet, so it always reports a charger connected, and the shown charge doesn’t drop while it does."
        }
        return "The firmware estimates the charge from the battery voltage and moves the shown level about 1% a minute (several minutes on some bands), as on a real device. Plugging in or out shows at once."
    }

    static func symbol(level: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Toolbar button that opens the battery control.
struct BatteryToolbarButton: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    @State private var shown = false

    var body: some View {
        let session = model.session(device.id)
        let b = session.battery ?? device.options.battery ?? BatteryState()
        Button { shown.toggle() } label: {
            Label("Battery \(b.level)%", systemImage: BatteryControl.symbol(level: b.level, charging: b.charging))
        }
        .help("Battery: \(b.level)%\(b.charging ? ", charging" : "")")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            BatteryControl(device: device).environment(model)
        }
    }
}
