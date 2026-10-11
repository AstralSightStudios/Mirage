import MirageKit
import SwiftUI

/// Proportions of a device's card around its panel, in panel pixels.
struct ChromeGeometry {
    let profile: DeviceProfile

    var screen: CGSize { CGSize(width: profile.screen.width, height: profile.screen.height) }

    /// Slim, delicate panel pixel padding for the liquid glass card around the screen.
    var cardPadding: CGFloat {
        max(8, min(screen.width, screen.height) * 0.025)
    }

    /// Card size in panel pixels.
    var card: CGSize {
        CGSize(width: screen.width + cardPadding * 2, height: screen.height + cardPadding * 2)
    }

    /// Extra width allocated for the independent button column (in panel pixels).
    var buttonColumnWidth: CGFloat {
        profile.buttons.isEmpty ? 0 : 105
    }

    /// Total bounding size in panel pixels for stage fit calculation.
    var total: CGSize {
        CGSize(width: card.width + buttonColumnWidth * 2, height: card.height)
    }

    var screenCorner: CGFloat {
        profile.screen.shape == .circle ? min(screen.width, screen.height) / 2 : profile.screen.cornerRadius
    }
}

/// Reserves equal space on both sides of the panel, with the dock only on the right.
/// The screen and its caption share the stage's center, regardless of dock width.
private struct ScreenCenteredLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let panel = subviews[0].sizeThatFits(.unspecified)
        guard subviews.count > 1 else { return panel }
        let dock = subviews[1].sizeThatFits(.unspecified)
        return CGSize(width: panel.width + 2 * (spacing + dock.width),
                      height: max(panel.height, dock.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let panel = subviews[0].sizeThatFits(.unspecified)
        subviews[0].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(panel))
        if subviews.count > 1 {
            let dock = subviews[1].sizeThatFits(.unspecified)
            subviews[1].place(at: CGPoint(x: bounds.midX + panel.width / 2 + spacing,
                                         y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(dock))
        }
    }
}

/// The device screen encased in a modern liquid glass card, with an independent
/// vertical column of hardware buttons.
struct DeviceChrome<Screen: View>: View {
    let profile: DeviceProfile
    /// Points per panel pixel.
    let scale: CGFloat
    var onButton: ((DeviceProfile.HardwareButton, Bool) -> Void)?
    @ViewBuilder var screen: () -> Screen

    private var geo: ChromeGeometry { ChromeGeometry(profile: profile) }
    private var accent: Color { Color(hex: profile.accent) ?? .blue }

    var body: some View {
        let g = geo
        let screenSize = CGSize(width: g.screen.width * scale, height: g.screen.height * scale)
        let padding = max(8, g.cardPadding * scale)

        ScreenCenteredLayout(spacing: max(12, 16 * scale)) {
            // Liquid glass card enclosing the screen with thin padding
            glassScreenCard(screenSize: screenSize, padding: padding)

            // Independent vertical column of buttons
            if !profile.buttons.isEmpty {
                HardwareButtonColumn(buttons: profile.buttons, accent: accent, scale: scale) { button, down in
                    onButton?(button, down)
                }
            }
        }
    }

    @ViewBuilder
    private func glassScreenCard(screenSize: CGSize, padding: CGFloat) -> some View {
        if profile.screen.shape == .circle {
            let cardDiameter = screenSize.width + padding * 2
            ZStack {
                // Outer liquid glass halo follows circle shape
                Circle()
                    .fill(Color(white: 0.08).opacity(0.72))
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.12), location: 0.0),
                                .init(color: .white.opacity(0.02), location: 0.35),
                                .init(color: .clear, location: 0.65),
                                .init(color: .black.opacity(0.20), location: 1.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.36), location: 0.0),
                                .init(color: .white.opacity(0.10), location: 0.30),
                                .init(color: .white.opacity(0.03), location: 0.70),
                                .init(color: .white.opacity(0.22), location: 1.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: max(0.8, 1.0 * scale)
                    )

                // Screen view inside
                screen()
                    .frame(width: screenSize.width, height: screenSize.height)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: max(0.5, 0.8 * scale)))
                    .shadow(color: .black.opacity(0.50), radius: 6 * scale, y: 2 * scale)
            }
            .frame(width: cardDiameter, height: cardDiameter)
            .shadow(color: .black.opacity(0.35), radius: max(8, 16 * scale), x: 0, y: max(4, 8 * scale))
            .shadow(color: .black.opacity(0.12), radius: max(2, 4 * scale), x: 0, y: max(1, 2 * scale))
        } else {
            // Concentric rounded rectangle follows device corner radius + padding
            let cardRadius = (profile.screen.cornerRadius * scale) + padding
            let cardShape = RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
            let cardWidth = screenSize.width + padding * 2
            let cardHeight = screenSize.height + padding * 2

            ZStack {
                cardShape
                    .fill(Color(white: 0.08).opacity(0.72))
                cardShape
                    .fill(.ultraThinMaterial)
                cardShape
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.12), location: 0.0),
                                .init(color: .white.opacity(0.02), location: 0.35),
                                .init(color: .clear, location: 0.65),
                                .init(color: .black.opacity(0.20), location: 1.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                cardShape
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.36), location: 0.0),
                                .init(color: .white.opacity(0.10), location: 0.30),
                                .init(color: .white.opacity(0.03), location: 0.70),
                                .init(color: .white.opacity(0.22), location: 1.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: max(0.8, 1.0 * scale)
                    )

                let r = profile.screen.cornerRadius * scale
                screen()
                    .frame(width: screenSize.width, height: screenSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: max(0.5, 0.8 * scale)))
                    .shadow(color: .black.opacity(0.50), radius: 6 * scale, y: 2 * scale)
            }
            .frame(width: cardWidth, height: cardHeight)
            .shadow(color: .black.opacity(0.35), radius: max(8, 16 * scale), x: 0, y: max(4, 8 * scale))
            .shadow(color: .black.opacity(0.12), radius: max(2, 4 * scale), x: 0, y: max(1, 2 * scale))
        }
    }
}

/// Independent vertical column of hardware buttons.
struct HardwareButtonColumn: View {
    let buttons: [DeviceProfile.HardwareButton]
    let accent: Color
    let scale: CGFloat
    let onPress: (DeviceProfile.HardwareButton, Bool) -> Void

    var body: some View {
        VStack(spacing: max(8, 12 * scale)) {
            Text("BUTTONS")
                .font(.system(size: max(8, 9 * scale), weight: .bold, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.7))
                .tracking(1.4)
                .padding(.top, 2)

            ForEach(buttons) { button in
                HardwareButtonView(button: button, accent: accent, scale: scale) { down in
                    onPress(button, down)
                }
            }
        }
        .padding(.horizontal, max(8, 10 * scale))
        .padding(.vertical, max(10, 14 * scale))
        .background {
            let dockShape = RoundedRectangle(cornerRadius: max(16, 20 * scale), style: .continuous)
            ZStack {
                dockShape.fill(Color(white: 0.10).opacity(0.80))
                dockShape.fill(.ultraThinMaterial)
            }
            .overlay {
                dockShape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.28), .white.opacity(0.06), .white.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
        }
        .shadow(color: .black.opacity(0.35), radius: max(10, 16 * scale), y: max(4, 8 * scale))
    }
}

/// A tactile glass button representing a hardware button or crown.
/// Hold to keep it pressed.
struct HardwareButtonView: View {
    let button: DeviceProfile.HardwareButton
    let accent: Color
    let scale: CGFloat
    let onPress: (Bool) -> Void

    @State private var pressed = false
    @State private var hovered = false

    var body: some View {
        let btnWidth = max(52, 64 * scale)
        let btnHeight = max(46, 54 * scale)
        let btnShape = RoundedRectangle(cornerRadius: max(10, 14 * scale), style: .continuous)

        VStack(spacing: 3) {
            ZStack {
                // Glass background with active accent glow
                btnShape
                    .fill(pressed ? accent.opacity(0.35) : (hovered ? Color.white.opacity(0.14) : Color.white.opacity(0.07)))
                    .overlay {
                        btnShape.strokeBorder(
                            pressed ? accent.opacity(0.85) : (hovered ? Color.white.opacity(0.35) : Color.white.opacity(0.16)),
                            lineWidth: pressed ? 1.5 : 1
                        )
                    }
                    .frame(width: btnWidth, height: btnHeight)
                    .shadow(color: pressed ? accent.opacity(0.45) : .clear, radius: 8)

                VStack(spacing: max(2, 3 * scale)) {
                    Image(systemName: iconName)
                        .font(.system(size: max(15, 19 * scale), weight: .semibold))
                        .foregroundStyle(pressed ? accent : (hovered ? .white : .white.opacity(0.88)))

                    Text(button.title)
                        .font(.system(size: max(8, 10 * scale), weight: .medium))
                        .foregroundStyle(pressed ? accent : (hovered ? .white : .secondary))
                        .lineLimit(1)
                }
            }
            .scaleEffect(pressed ? 0.92 : (hovered ? 1.03 : 1.0))
            .animation(.spring(response: 0.18, dampingFraction: 0.65), value: pressed)
            .animation(.easeInOut(duration: 0.12), value: hovered)

            // Keyboard shortcut tag
            if let hint = shortcutHint {
                Text(hint)
                    .font(.system(size: max(7, 8.5 * scale), weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        pressed = true
                        onPress(true)
                    }
                }
                .onEnded { _ in
                    pressed = false
                    onPress(false)
                }
        )
        .help("\(button.title) · Hold to keep pressed\(shortcutHint.map { " · Shortcut: \($0)" } ?? "")")
        .accessibilityLabel(button.title)
        .accessibilityAddTraits(.isButton)
    }

    private var iconName: String {
        switch button.placement {
        case .crown:
            return "digitalcrown.horizontal.press"
        case .rightUpper:
            return "house.fill"
        case .rightLower:
            return "button.horizontal.top.press"
        case .left:
            return "arrow.turn.up.left"
        }
    }

    private var shortcutHint: String? {
        switch button.qcode {
        case "home": return "Home"
        case "pgdn": return "PgDn"
        case "pgup": return "PgUp"
        default: return nil
        }
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
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(active ? accent.opacity(0.25) : Color.white.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .strokeBorder(active ? accent.opacity(0.55) : Color.white.opacity(0.12), lineWidth: 1)
                }
            Group {
                if profile?.family == .band {
                    RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                        .fill(Color.black)
                        .overlay(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                            .strokeBorder(active ? accent : Color(white: 0.55), lineWidth: 1))
                        .frame(width: size * 0.42, height: size * 0.62)
                } else {
                    Circle()
                        .fill(Color.black)
                        .overlay(Circle().strokeBorder(active ? accent : Color(white: 0.55), lineWidth: 1))
                        .frame(width: size * 0.58, height: size * 0.58)
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
