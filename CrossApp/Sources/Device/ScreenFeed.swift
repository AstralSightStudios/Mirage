import Foundation
import MirageKit

/// What the native screen views share: frames from a session and the
/// pointer as a finger, in panel pixels.
@MainActor
final class ScreenFeed {
    private(set) weak var session: DeviceSession?
    private var token: UUID?
    private var lastSequence = -1
    private var lastPoint: (x: Int, y: Int)?
    private var fingerDown = false
    private var lastMove = Date.distantPast
    private(set) var panel = (width: 1, height: 1)

    /// Called on the main thread with every new frame.
    var onFrame: ((VNCClient.Frame) -> Void)?

    func attach(_ s: DeviceSession, panel: (width: Int, height: Int)) {
        guard session !== s else { return }
        detach()
        session = s
        self.panel = panel
        token = s.observeFrames { [weak self] frame in self?.deliver(frame) }
    }

    func detach() {
        if let token, let session { session.removeObserver(token) }
        token = nil
        session = nil
        lastSequence = -1
        lastPoint = nil
        fingerDown = false
    }

    private func deliver(_ frame: VNCClient.Frame) {
        guard frame.sequence != lastSequence else { return }
        lastSequence = frame.sequence
        panel = (frame.width, frame.height)
        onFrame?(frame)
    }

    /// A pointer position in a view of `viewSize` points.
    func touch(x: Double, y: Double, viewWidth: Double, viewHeight: Double, down: Bool) {
        guard let session else { return }
        let px = Int(x / max(viewWidth, 1) * Double(panel.width))
        let py = Int(y / max(viewHeight, 1) * Double(panel.height))
        let pt = (x: max(0, min(panel.width - 1, px)), y: max(0, min(panel.height - 1, py)))
        if down != fingerDown {
            // presses and releases always go out immediately
            fingerDown = down
            lastPoint = pt
            lastMove = Date()
            session.touch(x: pt.x, y: pt.y, down: down)
            return
        }
        guard down, pt.x != lastPoint?.x || pt.y != lastPoint?.y else { return }
        // moves at ~90 Hz, so the firmware's touch queue keeps up
        let now = Date()
        guard now.timeIntervalSince(lastMove) >= 0.011 else { return }
        lastPoint = pt
        lastMove = now
        session.touch(x: pt.x, y: pt.y, down: true)
    }

    /// Home / Page Up / Page Down press the profile's hardware buttons.
    func key(_ qcode: String, down: Bool, profile: DeviceProfile) {
        guard let session, profile.buttons.contains(where: { $0.qcode == qcode }) else { return }
        Task { await session.button(qcode, down: down) }
    }
}
