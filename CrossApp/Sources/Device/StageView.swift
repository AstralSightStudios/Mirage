import Foundation
import MirageKit
import SwiftCrossUI

/// The selected device's screen: live while booted, otherwise its power
/// state, a Boot button and storage jobs.
struct StageView: View {
    var model: AppModel
    let device: VirtualDevice
    /// Points per panel pixel; nil fits the stage.
    @Binding var zoom: Double?

    var body: some View {
        if let profile = model.profile(device.profileID) {
            let session = model.session(device.id)
            let panelW = Double(profile.screen.width)
            let panelH = Double(profile.screen.height)
            let scale = zoom ?? 1.0
            let w = max(64, Int(panelW * scale))
            let h = max(64, Int(panelH * scale))
            VStack(spacing: 12) {
                Spacer()
                ZStack {
                    Color.black
                    content(profile: profile, session: session, width: w, height: h)
                }
                .frame(width: w, height: h)
                .cornerRadius(profile.screen.shape == .circle ? w / 2 : Int(profile.screen.cornerRadius * scale))
                Text("\(profile.name) · \(profile.screen.width) × \(profile.screen.height)")
                    .font(.caption)
                    .foregroundColor(.gray)
                HStack(spacing: 6) {
                    Button("−") { zoom = max(0.5, scale - 0.25) }
                    Text("\(Int((scale * 100).rounded()))%").font(.caption).frame(width: 46)
                    Button("+") { zoom = min(3.0, scale + 0.25) }
                    Button("1:1") { zoom = 1.0 }
                    Button("1.5×") { zoom = 1.5 }
                    Button("2×") { zoom = 2.0 }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Text("Unknown Device Profile")
            } description: {
                Text("“\(device.profileID)” is not in Device Profiles.")
            }
        }
    }

    @ViewBuilder
    private func content(profile: DeviceProfile, session: DeviceSession, width: Int, height: Int) -> some View {
        if session.state.isActive {
            ZStack {
                DeviceScreen(session: session, profile: profile, width: width, height: height)
                if session.screenSize == nil || session.state == .launching {
                    Text(session.state == .launching ? "Starting…" : "Connecting…").foregroundColor(.white)
                } else if session.state == .paused {
                    Text("Paused").foregroundColor(.white)
                } else if session.state == .stopping {
                    Text("Shutting down…").foregroundColor(.white)
                }
            }
        } else if let job = model.deviceJobs[device.id] {
            VStack(spacing: 8) {
                Text(job.title).foregroundColor(.white)
                ProgressView(value: job.progress).frame(width: max(80, width - 40))
                Text(job.detail).font(.caption).foregroundColor(.gray).lineLimit(1)
            }
        } else {
            VStack(spacing: 10) {
                Text("Shut Down").foregroundColor(.gray)
                Button("Boot") { model.boot(device.id) }
            }
        }
    }
}
