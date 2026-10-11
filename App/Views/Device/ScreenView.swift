import AppKit
import MirageKit
import SwiftUI

/// The emulator's panel: VNC frames in a layer, the pointer as a finger.
/// A two-finger trackpad scroll drags the finger too, so lists scroll and
/// pages swipe like on the device.
struct ScreenView: NSViewRepresentable {
    let session: DeviceSession
    let profile: DeviceProfile

    func makeNSView(context: Context) -> ScreenNSView {
        let v = ScreenNSView()
        v.attach(session, profile: profile)
        return v
    }

    func updateNSView(_ v: ScreenNSView, context: Context) {
        if v.session !== session || v.profile != profile {
            v.attach(session, profile: profile)
        }
    }

    static func dismantleNSView(_ v: ScreenNSView, coordinator: ()) {
        v.detach()
    }
}

final class ScreenNSView: NSView {
    private(set) weak var session: DeviceSession?
    private(set) var profile: DeviceProfile?
    private var token: UUID?
    private let content = CALayer()
    private var panel = CGSize(width: 1, height: 1)
    private var fingerDown = false
    private var scrollPoint: CGPoint?
    private var lastFrame = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        content.contentsGravity = .resize
        content.magnificationFilter = .linear
        content.minificationFilter = .trilinear
        content.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(content)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    func attach(_ s: DeviceSession, profile: DeviceProfile) {
        detach()
        session = s
        self.profile = profile
        panel = CGSize(width: profile.screen.width, height: profile.screen.height)
        MainActor.assumeIsolated {
            token = s.observeFrames { [weak self] frame in self?.show(frame) }
        }
        needsLayout = true
    }

    func detach() {
        if let token, let session {
            MainActor.assumeIsolated { session.removeObserver(token) }
        }
        token = nil
        content.contents = nil
    }

    private func show(_ frame: VNCClient.Frame) {
        guard frame.sequence != lastFrame || content.contents == nil else { return }
        lastFrame = frame.sequence
        panel = CGSize(width: frame.width, height: frame.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = DeviceSession.cgImage(frame)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    // MARK: Touch

    private func panelPoint(_ event: NSEvent) -> (Int, Int) {
        let p = convert(event.locationInWindow, from: nil)
        return panelPoint(p)
    }

    private func panelPoint(_ p: CGPoint) -> (Int, Int) {
        let x = Int((p.x / max(bounds.width, 1)) * panel.width)
        let y = Int((p.y / max(bounds.height, 1)) * panel.height)
        return (max(0, min(Int(panel.width) - 1, x)), max(0, min(Int(panel.height) - 1, y)))
    }

    private func touch(_ pt: (Int, Int), down: Bool) {
        guard let session else { return }
        MainActor.assumeIsolated { session.touch(x: pt.0, y: pt.1, down: down) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        fingerDown = true
        touch(panelPoint(event), down: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard fingerDown else { return }
        touch(panelPoint(event), down: true)
    }

    override func mouseUp(with event: NSEvent) {
        fingerDown = false
        touch(panelPoint(event), down: false)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase == [] else { return }
        if event.phase.contains(.began) {
            scrollPoint = convert(event.locationInWindow, from: nil)
            if let p = scrollPoint { touch(panelPoint(p), down: true) }
            return
        }
        guard var p = scrollPoint else { return }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            touch(panelPoint(p), down: false)
            scrollPoint = nil
            return
        }
        p.x += event.scrollingDeltaX
        p.y += event.scrollingDeltaY
        scrollPoint = p
        touch(panelPoint(p), down: true)
    }

    // MARK: Keys: hardware buttons from the keyboard

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat, let qcode = qcode(for: event) else { return super.keyDown(with: event) }
        hardware(qcode, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let qcode = qcode(for: event) else { return super.keyUp(with: event) }
        hardware(qcode, down: false)
    }

    private func qcode(for event: NSEvent) -> String? {
        guard let profile, !profile.buttons.isEmpty else { return nil }
        let codes = Set(profile.buttons.map(\.qcode))
        switch event.keyCode {
        case 115: return codes.contains("home") ? "home" : nil       // Home
        case 121: return codes.contains("pgdn") ? "pgdn" : nil       // Page Down
        case 116: return codes.contains("pgup") ? "pgup" : nil       // Page Up
        default: return nil
        }
    }

    private func hardware(_ qcode: String, down: Bool) {
        guard let session else { return }
        Task { @MainActor in await session.button(qcode, down: down) }
    }
}
