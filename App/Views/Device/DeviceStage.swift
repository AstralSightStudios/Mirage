import MirageKit
import SwiftUI

/// The stage's fit scale, read by the zoom buttons. A plain reference so
/// updating it doesn't re-render the window (which would resize the stage
/// again).
final class ScaleBox {
    var fit: CGFloat = 1
}

enum ZoomMode: Equatable {
    case fit
    /// Points per panel pixel.
    case scale(CGFloat)

    func resolve(fit: CGFloat) -> CGFloat {
        switch self {
        case .fit: return fit
        case .scale(let s): return s
        }
    }
}

/// The selected device, drawn in its case: live screen when booted,
/// otherwise its power state and the Boot button.
struct DeviceStage: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    @Binding var zoom: ZoomMode
    let scaleBox: ScaleBox

    var body: some View {
        if let profile = model.profile(device.profileID) {
            let session = model.session(device.id)
            GeometryReader { proxy in
                let geo = ChromeGeometry(profile: profile)
                let fit = max(0.2, min((proxy.size.width - 48) / geo.total.width,
                                       (proxy.size.height - 150) / geo.total.height))
                let scale = zoom.resolve(fit: fit)
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 14) {
                        DeviceChrome(profile: profile, scale: scale, onButton: { button, down in
                            Task { await session.button(button.qcode, down: down) }
                        }) {
                            ScreenContent(device: device, profile: profile, session: session)
                        }
                        Caption(device: device, profile: profile, session: session)
                    }
                    .padding(.vertical, 20)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                }
                .scrollIndicators(zoom == .fit ? .never : .automatic)
                .onAppear { scaleBox.fit = fit }
                .onChange(of: fit) { _, f in scaleBox.fit = f }
            }
        } else {
            ContentUnavailableView("Unknown Device Profile",
                                   systemImage: "questionmark.square.dashed",
                                   description: Text("“\(device.profileID)” is not in Device Profiles."))
        }
    }
}

private struct ScreenContent: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    let profile: DeviceProfile
    let session: DeviceSession

    var body: some View {
        ZStack {
            Color.black
            if session.state.isActive {
                ScreenView(session: session, profile: profile)
                if session.screenSize == nil || session.state == .launching {
                    BootingOverlay(text: session.state == .launching ? "Starting…" : "Connecting…")
                }
                if session.state == .paused {
                    Color.black.opacity(0.45)
                    Image(systemName: "pause.circle.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.85))
                }
                if session.state == .stopping {
                    Color.black.opacity(0.55)
                    BootingOverlay(text: "Shutting down…")
                }
            } else if let job = model.deviceJobs[device.id] {
                VStack(spacing: 10) {
                    ProgressView(value: job.progress).progressViewStyle(.circular).controlSize(.large).tint(.white)
                    Text(job.title).font(.callout.weight(.medium))
                    Text(job.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding()
            } else {
                Image(systemName: "power")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.white.opacity(0.18))
            }
        }
    }
}

private struct BootingOverlay: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large).tint(.white)
            Text(text).font(.callout).foregroundStyle(.white.opacity(0.8))
        }
    }
}

private struct Caption: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    let profile: DeviceProfile
    let session: DeviceSession

    var body: some View {
        VStack(spacing: 6) {
            Text(device.name).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            Group {
                switch session.state {
                case .stopped:
                    if model.deviceJobs[device.id] == nil {
                        Button {
                            model.boot(device.id)
                        } label: {
                            Label("Boot", systemImage: "play.fill").padding(.horizontal, 10).padding(.vertical, 3)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .keyboardShortcut("b", modifiers: [.command])
                    }
                default:
                    StatusLine(session: session)
                }
            }
            .padding(.top, 6)
            if let err = session.lastError, session.state == .stopped {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .textSelection(.enabled)
            }
        }
    }

    private var subtitle: String {
        let fw = model.firmware(device.firmwareID)
        return "\(profile.name) · HyperOS \(fw?.version ?? "?")"
    }
}

struct StatusLine: View {
    let session: DeviceSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text(now: ctx.date)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var color: Color {
        switch session.state {
        case .running: return .green
        case .paused: return .yellow
        default: return .orange
        }
    }

    private func text(now: Date) -> String {
        var parts = [session.state.title]
        if let s = session.startedAt, session.state == .running || session.state == .paused {
            let t = Int(now.timeIntervalSince(s))
            parts.append(String(format: "%d:%02d", t / 60, t % 60))
        }
        switch session.shell {
        case .injecting: parts.append("starting shell")
        case .failed: parts.append("no shell")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}
