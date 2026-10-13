import AppKit
import MirageKit
import SwiftUI

/// Every device on the workspace at once: drag a title bar or case to
/// move, the corner to resize, the empty canvas to select several; two
/// fingers scroll the canvas, pinch zooms it. Snapping lines devices up as
/// they move; the Arrange menu and the fixed layouts do the rest.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var marquee: CGRect?

    var body: some View {
        let ws = model.workspace
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                background(ws)
                ForEach(ws.tiles) { tile in
                    if let device = model.device(tile.id), let profile = model.profile(device.profileID) {
                        let p = ws.placement(of: tile)
                        WorkspaceTileView(device: device, profile: profile, placement: p)
                            .frame(width: p.frame.width, height: p.frame.height)
                            .position(x: p.frame.midX, y: p.frame.midY)
                            .zIndex(zIndex(tile.id, ws))
                    }
                }
                guides(ws)
                    .allowsHitTesting(false)
                    .zIndex(10_000)
                if let marquee {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.10))
                        .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
                        .frame(width: marquee.width, height: marquee.height)
                        .position(x: marquee.midX, y: marquee.midY)
                        .allowsHitTesting(false)
                        .zIndex(10_001)
                }
                if ws.tiles.isEmpty {
                    empty.frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .coordinateSpace(.named(WorkspaceView.space))
            .clipped()
            .onAppear {
                ws.viewport = proxy.size
                ws.backingScale = NSScreen.main?.backingScaleFactor ?? 2
            }
            .onChange(of: proxy.size) { _, s in ws.viewport = s }
        }
        .onChange(of: model.sessions.values.filter { $0.state.isActive }.map(\.deviceID)) { _, running in
            guard ws.autoAdd else { return }
            for id in running where !ws.contains(id) { ws.add(id) }
        }
        .onAppear {
            guard ws.autoAdd else { return }
            for (id, s) in model.sessions where s.state.isActive && !ws.contains(id) { ws.add(id) }
        }
    }

    static let space = "workspace"

    private func zIndex(_ id: UUID, _ ws: WorkspaceModel) -> Double {
        if ws.floating?.id == id { return 9_000 }
        if ws.front == id { return 8_000 }
        return Double(ws.tiles.firstIndex { $0.id == id } ?? 0)
    }

    private func background(_ ws: WorkspaceModel) -> some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor).opacity(0.35)
            if ws.showGrid && ws.layout == .free {
                Canvas { ctx, size in
                    let step = WorkspaceModel.gridStep * 4 * ws.zoom
                    guard step >= 12 else { return }
                    let ox = ws.offset.width.truncatingRemainder(dividingBy: step)
                    let oy = ws.offset.height.truncatingRemainder(dividingBy: step)
                    var x = ox
                    while x < size.width {
                        var y = oy
                        while y < size.height {
                            ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                                     with: .color(.secondary.opacity(0.35)))
                            y += step
                        }
                        x += step
                    }
                }
            }
            WorkspaceEventBridge(
                onScroll: { d in ws.pan(by: d) },
                onMagnify: { factor, p in if ws.layout == .free { ws.zoom(by: factor, around: p) } })
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(WorkspaceView.space))
                .onChanged { v in
                    let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                   width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                    marquee = r
                    ws.select(in: r, extend: NSEvent.modifierFlags.contains(.shift))
                }
                .onEnded { _ in marquee = nil }
        )
        .onTapGesture { ws.selection = [] }
    }

    private func guides(_ ws: WorkspaceModel) -> some View {
        Canvas { ctx, _ in
            for g in ws.guides {
                var path = Path()
                switch g.axis {
                case .vertical:
                    let a = ws.canvasToView(CGPoint(x: g.position, y: g.span.lowerBound))
                    let b = ws.canvasToView(CGPoint(x: g.position, y: g.span.upperBound))
                    path.move(to: CGPoint(x: a.x, y: a.y - 8))
                    path.addLine(to: CGPoint(x: b.x, y: b.y + 8))
                case .horizontal:
                    let a = ws.canvasToView(CGPoint(x: g.span.lowerBound, y: g.position))
                    let b = ws.canvasToView(CGPoint(x: g.span.upperBound, y: g.position))
                    path.move(to: CGPoint(x: a.x - 8, y: a.y))
                    path.addLine(to: CGPoint(x: b.x + 8, y: b.y))
                }
                ctx.stroke(path, with: .color(.pink), lineWidth: 1)
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Empty Workspace", systemImage: "rectangle.3.group")
        } description: {
            Text("Devices appear here when they boot. Right-click a device in the sidebar and choose Show in Workspace to add one that isn’t running.")
        } actions: {
            Button("Add Running Devices") {
                for (id, s) in model.sessions where s.state.isActive { model.workspace.add(id) }
            }
        }
    }
}

/// One device on the canvas: a title bar over its case.
private struct WorkspaceTileView: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    let profile: DeviceProfile
    let placement: WorkspaceModel.Placement
    // A drag SwiftUI cancels never reaches onEnded; these reset either way.
    @GestureState private var moving = false
    @GestureState private var resizing = false
    @State private var lastPoint: CGPoint?

    var body: some View {
        let ws = model.workspace
        let session = model.session(device.id)
        let selected = ws.selection.contains(device.id)
        let focused = model.selection == device.id
        VStack(spacing: 0) {
            titleBar(session: session, focused: focused)
                .frame(height: WorkspaceModel.header)
            DeviceChrome(profile: profile, scale: placement.scale, onButton: { button, down in
                Task { await session.button(button.qcode, down: down) }
            }, showsButtons: false) {
                ScreenContent(device: device, profile: profile, session: session) {
                    ws.click(device.id, extend: false)
                }
            }
            .frame(width: placement.frame.width, height: max(0, placement.frame.height - WorkspaceModel.header))
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.07) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : (focused ? Color.secondary.opacity(0.35) : .clear),
                              lineWidth: selected ? 2 : 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            if ws.layout == .free {
                ResizeHandle()
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(WorkspaceView.space))
                            .updating($resizing) { _, s, _ in s = true }
                            .onChanged { v in
                                ws.resize(device.id, translation: v.translation,
                                          noSnap: NSEvent.modifierFlags.contains(.command))
                            }
                            .onEnded { _ in ws.endResize() }
                    )
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(WorkspaceView.space))
                .updating($moving) { _, s, _ in s = true }
                .onChanged { v in
                    lastPoint = v.location
                    if !ws.selection.contains(device.id) && !NSEvent.modifierFlags.contains(.shift) {
                        ws.click(device.id, extend: false)
                    }
                    ws.move(device.id, translation: v.translation, noSnap: NSEvent.modifierFlags.contains(.command))
                }
                .onEnded { v in ws.endMove(device.id, at: v.location) }
        )
        .onChange(of: moving) { _, now in
            if !now {
                ws.endMove(device.id, at: lastPoint)
                lastPoint = nil
            }
        }
        .onChange(of: resizing) { _, now in
            if !now { ws.endResize() }
        }
        .simultaneousGesture(TapGesture().onEnded {
            let m = NSEvent.modifierFlags
            ws.click(device.id, extend: m.contains(.shift) || m.contains(.command))
        })
        .contextMenu { menu(session) }
    }

    private func titleBar(session: DeviceSession, focused: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            titleBarContent(session: session, focused: focused, compact: false, fixedName: true)
            titleBarContent(session: session, focused: focused, compact: true, fixedName: true)
            titleBarContent(session: session, focused: focused, compact: true, fixedName: false)
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(.bar.opacity(focused ? 0.9 : 0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 2)
    }

    /// Name, hardware keys, battery and power; `compact` leaves the
    /// battery out, `fixedName: false` lets the name shorten.
    private func titleBarContent(session: DeviceSession, focused: Bool, compact: Bool,
                                 fixedName: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color(session.state))
                .frame(width: 7, height: 7)
            Text(device.name)
                .font(.callout.weight(focused ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: fixedName, vertical: false)
                .help(device.name)
            Spacer(minLength: 4)
            ForEach(profile.buttons) { b in
                Button {
                    Task { await session.press(b.qcode) }
                } label: {
                    Image(systemName: b.symbol)
                }
                .help("Press \(b.title)")
                .disabled(session.state != .running)
            }
            if !compact, let b = session.battery, session.state.isActive {
                Image(systemName: BatteryControl.symbol(level: b.level, charging: b.charging))
                    .foregroundStyle(.secondary)
                    .help("\(b.level)%\(b.charging ? ", charging" : "")")
            }
            Button {
                session.state.isActive ? model.shutdown(device.id) : model.boot(device.id)
            } label: {
                Image(systemName: session.state.isActive ? "stop.fill" : "play.fill")
            }
            .help(session.state.isActive ? "Shut Down" : "Boot")
            .disabled(session.state == .stopping || model.deviceJobs[device.id] != nil)
            Button {
                model.workspace.remove([device.id])
            } label: {
                Image(systemName: "xmark")
            }
            .help("Remove from Workspace (keeps running)")
        }
    }

    @ViewBuilder
    private func menu(_ session: DeviceSession) -> some View {
        Button(session.state.isActive ? "Shut Down" : "Boot") {
            session.state.isActive ? model.shutdown(device.id) : model.boot(device.id)
        }
        Button("Restart") { model.restart(device.id) }.disabled(!session.state.isActive)
        Divider()
        Button("Bring to Front") { model.workspace.click(device.id, extend: false) }
        Button("Remove from Workspace") { model.workspace.remove([device.id]) }
    }

    private func color(_ s: DeviceSession.State) -> Color {
        switch s {
        case .running: return .green
        case .paused: return .yellow
        case .stopped: return .secondary.opacity(0.5)
        default: return .orange
        }
    }
}

private struct ResizeHandle: View {
    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .background(.bar, in: Circle())
            .overlay(Circle().strokeBorder(.separator))
            .padding(1)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.frameResize(position: .bottomRight, directions: .all).push()
                } else {
                    NSCursor.pop()
                }
            }
            .help("Drag to resize (⌘ turns snapping off)")
    }
}

/// Two-finger scrolls and pinches over the empty canvas pan and zoom it;
/// over a device screen they stay touches.
private struct WorkspaceEventBridge: NSViewRepresentable {
    var onScroll: (CGSize) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> BridgeView {
        let v = BridgeView()
        v.onScroll = onScroll
        v.onMagnify = onMagnify
        return v
    }

    func updateNSView(_ v: BridgeView, context: Context) {
        v.onScroll = onScroll
        v.onMagnify = onMagnify
    }

    final class BridgeView: NSView {
        var onScroll: ((CGSize) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                // a device screen under the pointer takes its own gestures
                var hit = window.contentView?.hitTest(event.locationInWindow)
                while let h = hit {
                    if h is ScreenNSView { return event }
                    hit = h.superview
                }
                switch event.type {
                case .scrollWheel:
                    let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                    self.onScroll?(CGSize(width: event.scrollingDeltaX * k, height: event.scrollingDeltaY * k))
                case .magnify:
                    self.onMagnify?(1 + event.magnification, p)
                default:
                    return event
                }
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
