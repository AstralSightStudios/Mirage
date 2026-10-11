import MirageKit
import SwiftUI

/// Proportions of a device's case around its panel, in panel pixels.
struct ChromeGeometry {
    let profile: DeviceProfile

    var screen: CGSize { CGSize(width: profile.screen.width, height: profile.screen.height) }

    /// Case size, without straps / lugs.
    var body: CGSize {
        switch profile.family {
        case .watch:
            let d = max(screen.width, screen.height) * 1.2
            return CGSize(width: d, height: d)
        case .band:
            return CGSize(width: screen.width + screen.width * 0.2, height: screen.height + screen.width * 0.2)
        }
    }

    /// Everything drawn, including straps and buttons.
    var total: CGSize {
        switch profile.family {
        case .watch: return CGSize(width: body.width * 1.12, height: body.height * 1.5)
        case .band: return CGSize(width: body.width * 1.08, height: body.height * 1.34)
        }
    }

    var screenCorner: CGFloat {
        profile.screen.shape == .circle ? min(screen.width, screen.height) / 2 : profile.screen.cornerRadius
    }
}

/// The device drawn around its screen, with clickable hardware buttons.
struct DeviceChrome<Screen: View>: View {
    let profile: DeviceProfile
    /// Points per panel pixel.
    let scale: CGFloat
    var onButton: ((DeviceProfile.HardwareButton, Bool) -> Void)?
    @ViewBuilder var screen: () -> Screen

    private var geo: ChromeGeometry { ChromeGeometry(profile: profile) }
    private var accent: Color { Color(hex: profile.accent) ?? .gray }

    var body: some View {
        let g = geo
        let body = CGSize(width: g.body.width * scale, height: g.body.height * scale)
        let screenSize = CGSize(width: g.screen.width * scale, height: g.screen.height * scale)
        ZStack {
            straps(body: body)
            // buttons sit under the case so only their outer half shows
            buttons(body: body)
            caseShape(body: body)
            screen()
                .frame(width: screenSize.width, height: screenSize.height)
                .clipShape(screenShape(screenSize))
                .overlay(screenShape(screenSize).stroke(.black.opacity(0.9), lineWidth: max(1, 2 * scale)))
        }
        .frame(width: g.total.width * scale, height: g.total.height * scale)
    }

    private func screenShape(_ size: CGSize) -> AnyShape {
        if profile.screen.shape == .circle {
            return AnyShape(Circle())
        }
        return AnyShape(RoundedRectangle(cornerRadius: profile.screen.cornerRadius * scale, style: .continuous))
    }

    @ViewBuilder
    private func caseShape(body: CGSize) -> some View {
        let metal = LinearGradient(colors: [Color(white: 0.36), Color(white: 0.16), Color(white: 0.26)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
        switch profile.family {
        case .watch:
            ZStack {
                Circle().fill(metal)
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .black.opacity(0.5)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: max(1, 3 * scale))
                Circle().fill(Color.black).padding(body.width * 0.035)
            }
            .frame(width: body.width, height: body.height)
            .shadow(color: .black.opacity(0.45), radius: 18 * scale, y: 8 * scale)
        case .band:
            let r = (profile.screen.cornerRadius + geo.screen.width * 0.1) * scale
            ZStack {
                RoundedRectangle(cornerRadius: r, style: .continuous).fill(metal)
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .black.opacity(0.5)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: max(1, 3 * scale))
                RoundedRectangle(cornerRadius: r * 0.82, style: .continuous).fill(Color.black)
                    .padding(geo.screen.width * 0.045 * scale)
            }
            .frame(width: body.width, height: body.height)
            .shadow(color: .black.opacity(0.45), radius: 18 * scale, y: 8 * scale)
        }
    }

    @ViewBuilder
    private func straps(body: CGSize) -> some View {
        let strap = LinearGradient(colors: [accent.opacity(0.55), accent.opacity(0.32)], startPoint: .leading, endPoint: .trailing)
        switch profile.family {
        case .watch:
            VStack(spacing: 0) {
                UnevenRoundedRectangle(topLeadingRadius: body.width * 0.08, topTrailingRadius: body.width * 0.08)
                    .fill(strap)
                    .frame(width: body.width * 0.52, height: body.height * 0.42)
                Spacer(minLength: body.height * 0.66)
                UnevenRoundedRectangle(bottomLeadingRadius: body.width * 0.08, bottomTrailingRadius: body.width * 0.08)
                    .fill(strap)
                    .frame(width: body.width * 0.52, height: body.height * 0.42)
            }
            .frame(height: body.height * 1.5)
        case .band:
            VStack(spacing: 0) {
                UnevenRoundedRectangle(topLeadingRadius: body.width * 0.2, topTrailingRadius: body.width * 0.2)
                    .fill(strap)
                    .frame(width: body.width * 0.78, height: body.height * 0.3)
                Spacer(minLength: body.height * 0.74)
                UnevenRoundedRectangle(bottomLeadingRadius: body.width * 0.2, bottomTrailingRadius: body.width * 0.2)
                    .fill(strap)
                    .frame(width: body.width * 0.78, height: body.height * 0.3)
            }
            .frame(height: body.height * 1.34)
        }
    }

    @ViewBuilder
    private func buttons(body: CGSize) -> some View {
        ForEach(profile.buttons) { b in
            HardwareButtonView(button: b, scale: scale) { down in onButton?(b, down) }
                .offset(offset(for: b.placement, body: body))
        }
    }

    private func offset(for placement: DeviceProfile.HardwareButton.Placement, body: CGSize) -> CGSize {
        let r = body.width / 2 * 1.01
        func polar(_ deg: Double) -> CGSize {
            let a = deg * .pi / 180
            return CGSize(width: cos(a) * r, height: -sin(a) * r)
        }
        switch (profile.family, placement) {
        case (.watch, .crown): return polar(28)
        case (.watch, .rightUpper): return polar(40)
        case (.watch, .rightLower): return polar(-28)
        case (.watch, .left): return polar(180)
        case (.band, .crown), (.band, .rightUpper): return CGSize(width: body.width * 0.505, height: -body.height * 0.18)
        case (.band, .rightLower): return CGSize(width: body.width * 0.505, height: body.height * 0.12)
        case (.band, .left): return CGSize(width: -body.width * 0.505, height: 0)
        }
    }
}

/// A side button or crown. Hold to keep it pressed.
struct HardwareButtonView: View {
    let button: DeviceProfile.HardwareButton
    let scale: CGFloat
    let onPress: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        let isCrown = button.placement == .crown
        let w = (isCrown ? 30 : 16) * scale * 2.4
        let h = (isCrown ? 52 : 70) * scale * 1.4
        RoundedRectangle(cornerRadius: isCrown ? 6 * scale * 2 : w / 2, style: .continuous)
            .fill(LinearGradient(colors: pressed ? [Color(white: 0.2), Color(white: 0.3)] : [Color(white: 0.55), Color(white: 0.25)],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay {
                if isCrown {
                    VStack(spacing: max(1, 3 * scale)) {
                        ForEach(0..<5, id: \.self) { _ in
                            Rectangle().fill(.black.opacity(0.35)).frame(height: max(0.5, 1.5 * scale))
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .frame(width: max(8, w), height: max(14, h))
            .scaleEffect(pressed ? 0.94 : 1, anchor: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        pressed = true
                        onPress(true)
                    }
                }
                .onEnded { _ in
                    pressed = false
                    onPress(false)
                })
            .help("\(button.title) — hold to keep pressed")
            .accessibilityLabel(button.title)
            .accessibilityAddTraits(.isButton)
    }
}

/// Small device silhouette for lists.
struct DeviceGlyph: View {
    let profile: DeviceProfile?
    var size: CGFloat = 28
    var active = false

    var body: some View {
        let accent = profile.flatMap { Color(hex: $0.accent) } ?? .gray
        ZStack {
            Circle().fill(active ? accent.opacity(0.25) : Color.secondary.opacity(0.12))
            Group {
                if profile?.family == .band {
                    RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                        .fill(Color(white: 0.15))
                        .overlay(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                            .strokeBorder(Color(white: 0.55), lineWidth: 1))
                        .frame(width: size * 0.36, height: size * 0.56)
                } else {
                    ZStack {
                        Capsule().fill(accent.opacity(0.5)).frame(width: size * 0.28, height: size * 0.78)
                        Circle().fill(Color(white: 0.15))
                            .overlay(Circle().strokeBorder(Color(white: 0.55), lineWidth: 1))
                            .frame(width: size * 0.5, height: size * 0.5)
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
