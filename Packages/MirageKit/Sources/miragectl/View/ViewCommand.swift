import Foundation
import MirageKit

/// `miragectl view`: the panel in the terminal, the mouse as the finger.
/// Frames are drawn on one thread and input is read on another; both only
/// reach the session through the main actor. Returns when the user quits or
/// the device shuts down.
@MainActor
func view(_ s: DeviceSession, profile: DeviceProfile?, title: String, halfBlocks: Bool) async throws {
    let terminal = try Terminal.enter(halfBlocks: halfBlocks)
    terminal.setTitle("Mirage · \(title)")
    let renderer: ScreenRenderer = terminal.graphics == .halfBlocks
        ? BlockRenderer(terminal, screen: profile?.screen)
        : KittyRenderer(terminal, screen: profile?.screen)
    let slot = FrameSlot()
    let placement = Locked<Placement?>(nil)
    let quit = Locked(false)
    let token = s.observeFrames { slot.put($0) }

    let rendered = Locked(false)
    let render = Thread {
        var last: VNCClient.Frame?
        var lastSequence = -1
        while true {
            let (next, closed) = slot.wait(timeout: 0.1)
            if closed { break }
            if let next { last = next }
            guard let f = last else { continue }
            if let p = renderer.draw(f, in: terminal.size, fresh: f.sequence != lastSequence) { placement.value = p }
            lastSequence = f.sequence
        }
        rendered.value = true
    }
    render.name = "render"
    render.start()

    let input = TouchInput(terminal, session: s, buttons: Set(profile?.buttons.map(\.qcode) ?? []),
                           placement: placement)
    let read = Thread {
        input.run(until: quit)
        quit.value = true
    }
    read.name = "input"
    read.start()

    // Frames and touches go through the main queue, which runs while this waits
    while !quit.value && s.state.isActive {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    quit.value = true
    s.removeObserver(token)
    slot.close()
    while !rendered.value {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    // The input thread lifts a finger left down within one poll
    try? await Task.sleep(nanoseconds: 60_000_000)
    terminal.leave()
}

/// The newest frame, handed from the main actor to the render thread.
final class FrameSlot: @unchecked Sendable {
    private let condition = NSCondition()
    private var frame: VNCClient.Frame?
    private var closed = false

    func put(_ f: VNCClient.Frame) {
        condition.lock()
        frame = f
        condition.signal()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    /// The frame put since the last call, nil if none came within `timeout`.
    func wait(timeout: TimeInterval) -> (frame: VNCClient.Frame?, closed: Bool) {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while frame == nil && !closed {
            if !condition.wait(until: deadline) { break }
        }
        defer { frame = nil }
        return (frame, closed)
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        _value = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            _value = newValue
            lock.unlock()
        }
    }
}

/// Terminal mouse and keys as the finger and the hardware buttons: left
/// drag touches, the wheel swipes, right click swipes back from the left
/// edge, middle click and Home press the crown, Page Up/Down the side keys.
/// Runs on its own thread.
final class TouchInput: @unchecked Sendable {
    private let terminal: Terminal
    private let session: DeviceSession
    /// Button qcodes the device has
    private let buttons: Set<String>
    private let placement: Locked<Placement?>
    private var parser = InputParser()
    /// Placement at touch down, so that a gesture stays consistent
    private var touching: Placement?
    /// Finger of a wheel swipe, in panel pixels
    private var scroll: (placement: Placement, x: Double, y: Double, last: Date)?
    private var lastSent: (x: Int, y: Int, down: Bool, time: Date)?
    /// Hardware key presses, one after the other (on the main actor)
    private var pressing: Task<Void, Never>?

    init(_ terminal: Terminal, session: DeviceSession, buttons: Set<String>, placement: Locked<Placement?>) {
        self.terminal = terminal
        self.session = session
        self.buttons = buttons
        self.placement = placement
    }

    func run(until quit: Locked<Bool>) {
        defer { lift() }
        while !quit.value {
            guard let bytes = terminal.input.take(timeout: 0.03) else { return }
            for event in bytes.isEmpty ? parser.flush() : parser.feed(bytes) {
                if !handle(event) { return }
            }
            // A wheel swipe ends when the wheel stops
            if let s = scroll, Date().timeIntervalSince(s.last) > 0.15 {
                send(Int(s.x), Int(s.y), down: false, force: true)
                scroll = nil
            }
        }
    }

    /// False to quit.
    private func handle(_ event: InputEvent) -> Bool {
        switch event {
        case .key(.char("q"), let m) where m.ctrl && !m.alt:
            return false
        case .key(.home, _):
            press("home")
        case .key(.pageUp, _):
            press("pgup")
        case .key(.pageDown, _):
            press("pgdn")
        case .key:
            break
        case .mouse(let kind, let x, let y):
            guard let p = placement.value else { break }
            let (px, py) = terminalPixel(x, y)
            mouse(kind, p, px, py)
        }
        return true
    }

    private func terminalPixel(_ x: Int, _ y: Int) -> (Double, Double) {
        if terminal.pixelMouse { return (Double(x) + 0.5, Double(y) + 0.5) }
        let size = terminal.size
        return ((Double(x) + 0.5) * Double(size.cellWidth), (Double(y) + 0.5) * Double(size.cellHeight))
    }

    private func mouse(_ kind: MouseKind, _ p: Placement, _ px: Double, _ py: Double) {
        switch kind {
        case .press(.left):
            let (x, y, inside) = p.map(px, py)
            guard inside, scroll == nil else { return }
            touching = p
            send(x, y, down: true, force: true)
        case .drag(.left):
            guard let t = touching else { return }
            let (x, y, _) = t.map(px, py)
            send(x, y, down: true)
        case .release(.left):
            guard let t = touching else { return }
            touching = nil
            let (x, y, _) = t.map(px, py)
            send(x, y, down: false, force: true)
        case .press(.right):
            guard touching == nil, scroll == nil else { return }
            back(p)
        case .press(.middle):
            press("home")
        case .scroll(let dx, let dy):
            guard touching == nil else { return }
            if scroll == nil {
                let (x, y, inside) = p.map(px, py)
                guard inside else { return }
                scroll = (p, Double(x), Double(y), Date())
                send(x, y, down: true, force: true)
            }
            guard var s = scroll else { return }
            // The content follows the wheel, so the finger moves against it
            let step = Double(min(s.placement.panelWidth, s.placement.panelHeight)) / 16
            s.x = min(max(s.x - Double(dx) * step, 0), Double(s.placement.panelWidth - 1))
            s.y = min(max(s.y + Double(dy) * step, 0), Double(s.placement.panelHeight - 1))
            s.last = Date()
            scroll = s
            send(Int(s.x), Int(s.y), down: true, force: true)
        default:
            break
        }
    }

    /// Back, as on the device: a swipe from the left edge.
    private func back(_ p: Placement) {
        let y = p.panelHeight / 2, to = p.panelWidth * 3 / 5, steps = 8
        for i in 0...steps {
            send(i * to / steps, y, down: true, force: true)
            Thread.sleep(forTimeInterval: 0.016)
        }
        send(to, y, down: false, force: true)
    }

    /// Lifts a finger left down when input ends.
    private func lift() {
        guard touching != nil || scroll != nil, let l = lastSent else { return }
        send(l.x, l.y, down: false, force: true)
        touching = nil
        scroll = nil
    }

    private func send(_ x: Int, _ y: Int, down: Bool, force: Bool = false) {
        let now = Date()
        if let l = lastSent, l.down == down {
            if l.x == x && l.y == y { return }
            // Throttle movement to ~90Hz, like the app's screen view
            if !force && now.timeIntervalSince(l.time) < 0.011 { return }
        }
        lastSent = (x, y, down, now)
        let session = session
        DispatchQueue.main.async {
            MainActor.assumeIsolated { session.touch(x: x, y: y, down: down) }
        }
    }

    private func press(_ qcode: String) {
        guard buttons.contains(qcode) else { return }
        let session = session
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                let previous = pressing
                pressing = Task { @MainActor in
                    await previous?.value
                    await session.press(qcode)
                }
            }
        }
    }
}
