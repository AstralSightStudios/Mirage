import Foundation
import MirageKit
import Observation

/// How the workspace places its devices.
enum WorkspaceLayout: String, Codable, CaseIterable, Identifiable {
    /// Wherever they were dragged, at the size they were given.
    case free
    /// Fixed splits: the window is divided and every device fills its share.
    case row, column, grid, focus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Freeform"
        case .row: return "Side by Side"
        case .column: return "Stacked"
        case .grid: return "Grid"
        case .focus: return "Focus"
        }
    }

    var symbol: String {
        switch self {
        case .free: return "square.on.square.dashed"
        case .row: return "rectangle.split.3x1"
        case .column: return "rectangle.split.1x2"
        case .grid: return "square.grid.2x2"
        case .focus: return "rectangle.lefthalf.inset.filled"
        }
    }
}

/// One device on the workspace canvas (free layout coordinates).
struct WorkspaceTile: Codable, Equatable, Identifiable {
    var id: UUID
    /// Centre in canvas points.
    var center: CGPoint
    /// Points per panel pixel at canvas zoom 1.
    var scale: CGFloat
}

/// Everything the workspace remembers between launches.
struct WorkspaceState: Codable, Equatable {
    /// Tile order is the order of the fixed layouts.
    var tiles: [WorkspaceTile] = []
    var layout: WorkspaceLayout = .free
    var snapping = true
    var showGrid = true
    /// Devices join the workspace when they boot.
    var autoAdd = true
    var zoom: CGFloat = 1
    var offset: CGSize = .zero
}

/// A snapping guide in canvas coordinates: a vertical line at `position`
/// (x) or a horizontal one (y), drawn over `span`.
struct WorkspaceGuide: Equatable, Hashable {
    enum Axis { case vertical, horizontal }
    var axis: Axis
    var position: CGFloat
    var span: ClosedRange<CGFloat>
}

enum WorkspaceAlignment {
    case left, centerX, right, top, centerY, bottom
}

/// The multi-device workspace: which devices it shows, where and how big,
/// and the arranging operations (snapping, align, distribute, layouts).
@MainActor
@Observable
final class WorkspaceModel {
    private(set) var state = WorkspaceState()
    /// Tiles picked for align / distribute (and moved together).
    var selection: Set<UUID> = []
    /// Guides of the drag in progress.
    private(set) var guides: [WorkspaceGuide] = []
    /// The tile being dragged in a fixed layout, and its offset in view points.
    private(set) var floating: (id: UUID, offset: CGSize)?
    /// Last tile touched; drawn above the others.
    private(set) var front: UUID?
    /// Size of the canvas view.
    var viewport = CGSize(width: 900, height: 600)
    /// Screen pixels per point of the display showing the canvas.
    var backingScale: CGFloat = 2

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var key = "workspace"
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var drag: DragSession?

    static let header: CGFloat = 30
    static let gap: CGFloat = 28
    static let margin: CGFloat = 24
    static let snapDistance: CGFloat = 7
    static let gridStep: CGFloat = 16

    private struct DragSession {
        var ids: [UUID]
        var startCenters: [UUID: CGPoint]
        var startScale: CGFloat = 1
        var startRect: CGRect = .zero
    }

    // MARK: Persistence

    func load(libraryRoot: URL) {
        key = "workspace:" + libraryRoot.standardizedFileURL.path
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(WorkspaceState.self, from: data) {
            state = s
        } else {
            state = WorkspaceState()
        }
        selection = []
        prune()
    }

    private func update(_ change: (inout WorkspaceState) -> Void) {
        var s = state
        change(&s)
        guard s != state else { return }
        state = s
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let key = key
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            if let data = try? JSONEncoder().encode(self.state) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    /// Drops tiles of devices that no longer exist.
    func prune() {
        guard let app else { return }
        let ids = Set(app.devices.map(\.id))
        if state.tiles.contains(where: { !ids.contains($0.id) }) {
            update { $0.tiles.removeAll { !ids.contains($0.id) } }
        }
        selection = selection.filter { ids.contains($0) }
    }

    // MARK: Settings

    var layout: WorkspaceLayout {
        get { state.layout }
        set {
            guard newValue != state.layout else { return }
            // Leaving a fixed split for freeform keeps what was on screen.
            if newValue == .free && state.layout != .free { adoptFixedFrames() }
            update { $0.layout = newValue }
        }
    }

    var snapping: Bool {
        get { state.snapping }
        set { update { $0.snapping = newValue } }
    }

    var showGrid: Bool {
        get { state.showGrid }
        set { update { $0.showGrid = newValue } }
    }

    var autoAdd: Bool {
        get { state.autoAdd }
        set { update { $0.autoAdd = newValue } }
    }

    var zoom: CGFloat { state.zoom }
    var offset: CGSize { state.offset }
    var tiles: [WorkspaceTile] { state.tiles }

    func contains(_ id: UUID) -> Bool { state.tiles.contains { $0.id == id } }

    // MARK: Geometry

    private func profile(_ id: UUID) -> DeviceProfile? {
        guard let app, let d = app.device(id) else { return nil }
        return app.profile(d.profileID)
    }

    /// The device's case at scale 1, in points (panel pixels). Workspace
    /// tiles carry their hardware buttons in the title bar.
    func baseSize(_ id: UUID) -> CGSize {
        guard let p = profile(id) else { return CGSize(width: 240, height: 320) }
        return ChromeGeometry(profile: p).card
    }

    /// The title bar keeps its size on screen whatever the zoom; this is
    /// its height in canvas points.
    private var headerC: CGFloat { Self.header / state.zoom }

    /// The tile's size in canvas points: its case plus the title bar.
    func size(of tile: WorkspaceTile) -> CGSize {
        let b = baseSize(tile.id)
        return CGSize(width: b.width * tile.scale, height: b.height * tile.scale + headerC)
    }

    func rect(of tile: WorkspaceTile) -> CGRect {
        let s = size(of: tile)
        return CGRect(x: tile.center.x - s.width / 2, y: tile.center.y - s.height / 2,
                      width: s.width, height: s.height)
    }

    private func tile(_ id: UUID) -> WorkspaceTile? { state.tiles.first { $0.id == id } }

    func canvasToView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * state.zoom + state.offset.width, y: p.y * state.zoom + state.offset.height)
    }

    func viewToCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - state.offset.width) / state.zoom, y: (p.y - state.offset.height) / state.zoom)
    }

    /// Where a tile is drawn: its frame in view points and the case scale.
    struct Placement {
        var frame: CGRect
        var scale: CGFloat
    }

    func placement(of tile: WorkspaceTile) -> Placement {
        if state.layout == .free {
            let r = rect(of: tile)
            let origin = canvasToView(r.origin)
            var frame = CGRect(origin: origin, size: CGSize(width: r.width * state.zoom,
                                                            height: r.height * state.zoom))
            if let f = floating, f.id == tile.id { frame = frame.offsetBy(dx: f.offset.width, dy: f.offset.height) }
            return Placement(frame: frame, scale: tile.scale * state.zoom)
        }
        let frames = fixedFrames()
        var p = frames[tile.id] ?? Placement(frame: .zero, scale: 0.3)
        if let f = floating, f.id == tile.id { p.frame = p.frame.offsetBy(dx: f.offset.width, dy: f.offset.height) }
        return p
    }

    /// The cells of the fixed layouts, in view points.
    func fixedCells(count n: Int) -> [CGRect] {
        guard n > 0 else { return [] }
        let area = CGRect(origin: .zero, size: viewport).insetBy(dx: Self.margin, dy: Self.margin)
        let g = Self.gap / 2
        func split(_ r: CGRect, cols: Int, rows: Int) -> [CGRect] {
            let w = r.width / CGFloat(cols), h = r.height / CGFloat(rows)
            return (0..<(cols * rows)).map { i in
                CGRect(x: r.minX + CGFloat(i % cols) * w, y: r.minY + CGFloat(i / cols) * h, width: w, height: h)
                    .insetBy(dx: g, dy: g)
            }
        }
        switch state.layout {
        case .free, .row:
            return split(area, cols: n, rows: 1)
        case .column:
            return split(area, cols: 1, rows: n)
        case .grid:
            let ids = state.tiles.map(\.id)
            var best: (cols: Int, score: CGFloat) = (1, 0)
            for cols in 1...n {
                let rows = Int(ceil(Double(n) / Double(cols)))
                let cells = split(area, cols: cols, rows: rows)
                let score = zip(ids, cells).map { fitScale(id: $0.0, in: $0.1) }.min() ?? 0
                if score > best.score { best = (cols, score) }
            }
            return Array(split(area, cols: best.cols, rows: Int(ceil(Double(n) / Double(best.cols)))).prefix(n))
        case .focus:
            if n == 1 { return [area.insetBy(dx: g, dy: g)] }
            let mainWidth = area.width * 0.68
            let main = CGRect(x: area.minX, y: area.minY, width: mainWidth, height: area.height).insetBy(dx: g, dy: g)
            let side = CGRect(x: area.minX + mainWidth, y: area.minY, width: area.width - mainWidth, height: area.height)
            return [main] + split(side, cols: 1, rows: n - 1)
        }
    }

    private func fitScale(id: UUID, in cell: CGRect) -> CGFloat {
        let b = baseSize(id)
        return max(0.08, min((cell.width) / b.width, (cell.height - Self.header) / b.height, 4))
    }

    func fixedFrames() -> [UUID: Placement] {
        let ids = state.tiles.map(\.id)
        var out: [UUID: Placement] = [:]
        for (id, cell) in zip(ids, fixedCells(count: ids.count)) {
            let s = fitScale(id: id, in: cell)
            let b = baseSize(id)
            let size = CGSize(width: b.width * s, height: b.height * s + Self.header)
            out[id] = Placement(frame: CGRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2,
                                              width: size.width, height: size.height), scale: s)
        }
        return out
    }

    /// Turns the fixed split on screen into freeform positions.
    private func adoptFixedFrames() {
        let frames = fixedFrames()
        update { s in
            s.zoom = 1
            s.offset = .zero
            for i in s.tiles.indices {
                if let p = frames[s.tiles[i].id] {
                    s.tiles[i].scale = p.scale
                    s.tiles[i].center = CGPoint(x: p.frame.midX, y: p.frame.midY)
                }
            }
        }
    }

    // MARK: Membership

    /// Puts a device on the workspace, next to the others.
    func add(_ id: UUID) {
        guard !contains(id), profile(id) != nil else { return }
        let base = baseSize(id)
        var scale: CGFloat = 0.5
        var center = viewToCanvas(CGPoint(x: viewport.width / 2, y: viewport.height / 2))
        if let last = state.tiles.max(by: { rect(of: $0).maxX < rect(of: $1).maxX }) {
            let r = rect(of: last)
            // as tall as its neighbour, to its right
            scale = max(0.15, (r.height - headerC) / base.height)
            let w = base.width * scale
            center = CGPoint(x: r.maxX + Self.gap + w / 2, y: r.midY)
        } else {
            let fit = min((viewport.width - 2 * Self.margin) / base.width,
                          (viewport.height - 2 * Self.margin - Self.header) / base.height) / state.zoom
            scale = max(0.15, min(0.55, fit))
        }
        update { $0.tiles.append(WorkspaceTile(id: id, center: center, scale: scale)) }
        front = id
        // keep every device in view
        if state.layout == .free, let t = tile(id) {
            let r = rect(of: t)
            let a = canvasToView(r.origin), b = canvasToView(CGPoint(x: r.maxX, y: r.maxY))
            if a.x < 0 || a.y < 0 || b.x > viewport.width || b.y > viewport.height { fitAll() }
        }
    }

    func remove(_ ids: Set<UUID>) {
        update { $0.tiles.removeAll { ids.contains($0.id) } }
        selection.subtract(ids)
    }

    func toggle(_ id: UUID) {
        contains(id) ? remove([id]) : add(id)
    }

    // MARK: Selection

    func click(_ id: UUID, extend: Bool) {
        front = id
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if !selection.contains(id) {
            selection = [id]
        }
        app?.selection = id
    }

    func select(in viewRect: CGRect, extend: Bool) {
        let hit = Set(state.tiles.filter { placement(of: $0).frame.intersects(viewRect) }.map(\.id))
        selection = extend ? selection.union(hit) : hit
    }

    /// The tiles an arrange command acts on: the selection, else all.
    private var targets: [UUID] {
        let sel = state.tiles.map(\.id).filter { selection.contains($0) }
        return sel.count >= 2 ? sel : state.tiles.map(\.id)
    }

    // MARK: Dragging

    func beginMove(_ id: UUID) {
        front = id
        let ids = selection.contains(id) ? state.tiles.map(\.id).filter { selection.contains($0) } : [id]
        drag = DragSession(ids: ids, startCenters: Dictionary(uniqueKeysWithValues: ids.compactMap { i in tile(i).map { (i, $0.center) } }))
    }

    /// `translation` in view points; `free` = snapping off for this move (⌘ held).
    func move(_ id: UUID, translation: CGSize, noSnap: Bool) {
        if drag == nil { beginMove(id) }
        guard let drag else { return }
        if state.layout != .free {
            floating = (id, translation)
            return
        }
        var dx = translation.width / state.zoom
        var dy = translation.height / state.zoom
        guides = []
        if state.snapping && !noSnap, let lead = tile(id), let start = drag.startCenters[id] {
            var moved = lead
            moved.center = CGPoint(x: start.x + dx, y: start.y + dy)
            let (adjust, g) = snap(rect(of: moved), excluding: Set(drag.ids))
            dx += adjust.width
            dy += adjust.height
            guides = g
        }
        update { s in
            for i in s.tiles.indices {
                if let c = drag.startCenters[s.tiles[i].id] {
                    s.tiles[i].center = CGPoint(x: c.x + dx, y: c.y + dy)
                }
            }
        }
    }

    func endMove(_ id: UUID, at viewPoint: CGPoint?) {
        defer {
            drag = nil
            guides = []
            floating = nil
        }
        guard state.layout != .free, let viewPoint else { return }
        // fixed layouts: drop on another cell to swap places
        let cells = fixedCells(count: state.tiles.count)
        guard let target = cells.firstIndex(where: { $0.contains(viewPoint) }),
              let from = state.tiles.firstIndex(where: { $0.id == id }), target != from else { return }
        update { $0.tiles.swapAt(from, target) }
    }

    func beginResize(_ id: UUID) {
        front = id
        guard let t = tile(id) else { return }
        drag = DragSession(ids: [id], startCenters: [id: t.center], startScale: t.scale, startRect: rect(of: t))
    }

    /// Bottom-right corner drag; the top-left corner stays put.
    func resize(_ id: UUID, translation: CGSize, noSnap: Bool) {
        if drag == nil { beginResize(id) }
        guard let drag, state.layout == .free else { return }
        let base = baseSize(id)
        let r = drag.startRect
        let caseW = r.width, caseH = r.height - headerC
        // follow whichever axis the pointer moved more, keeping the aspect
        let sx = (caseW + translation.width / state.zoom) / caseW
        let sy = (caseH + translation.height / state.zoom) / caseH
        var scale = max(0.08, min(4, drag.startScale * max(sx, sy)))
        guides = []
        if state.snapping && !noSnap {
            let (s, g) = snapResize(id: id, origin: r.origin, base: base, scale: scale)
            scale = s
            guides = g
        }
        let size = CGSize(width: base.width * scale, height: base.height * scale + headerC)
        update { s in
            if let i = s.tiles.firstIndex(where: { $0.id == id }) {
                s.tiles[i].scale = scale
                s.tiles[i].center = CGPoint(x: r.minX + size.width / 2, y: r.minY + size.height / 2)
            }
        }
    }

    func endResize() {
        drag = nil
        guides = []
    }

    // MARK: Snapping

    /// The nudge that lines `r` up with another tile's edge or centre, and
    /// the guides that show it.
    private func snap(_ r: CGRect, excluding: Set<UUID>) -> (CGSize, [WorkspaceGuide]) {
        let others = state.tiles.filter { !excluding.contains($0.id) }.map(rect(of:))
        let limit = Self.snapDistance / state.zoom
        var best: (dx: CGFloat, dist: CGFloat, x: CGFloat, other: CGRect)?
        var bestY: (dy: CGFloat, dist: CGFloat, y: CGFloat, other: CGRect)?
        let mine = [r.minX, r.midX, r.maxX]
        let mineY = [r.minY, r.midY, r.maxY, r.minY + headerC]
        for o in others {
            for m in mine {
                for t in [o.minX, o.midX, o.maxX] where abs(t - m) <= limit && abs(t - m) < (best?.dist ?? .infinity) {
                    best = (t - m, abs(t - m), t, o)
                }
            }
            // keep a tidy gap to the neighbour on either side
            for (m, t) in [(r.minX, o.maxX + Self.gap), (r.maxX, o.minX - Self.gap)]
                where abs(t - m) <= limit && abs(t - m) < (best?.dist ?? .infinity) {
                best = (t - m, abs(t - m), m == r.minX ? o.maxX : o.minX, o)
            }
            for m in mineY {
                for t in [o.minY, o.midY, o.maxY, o.minY + headerC] where abs(t - m) <= limit && abs(t - m) < (bestY?.dist ?? .infinity) {
                    bestY = (t - m, abs(t - m), t, o)
                }
            }
            for (m, t) in [(r.minY, o.maxY + Self.gap), (r.maxY, o.minY - Self.gap)]
                where abs(t - m) <= limit && abs(t - m) < (bestY?.dist ?? .infinity) {
                bestY = (t - m, abs(t - m), m == r.minY ? o.maxY : o.minY, o)
            }
        }
        var dx: CGFloat = 0, dy: CGFloat = 0
        if let best { dx = best.dx }
        else if state.showGrid { dx = (r.minX / Self.gridStep).rounded() * Self.gridStep - r.minX }
        if let bestY { dy = bestY.dy }
        else if state.showGrid { dy = (r.minY / Self.gridStep).rounded() * Self.gridStep - r.minY }
        let moved = r.offsetBy(dx: dx, dy: dy)
        var guides: [WorkspaceGuide] = []
        if let best {
            guides.append(WorkspaceGuide(axis: .vertical, position: best.x,
                                         span: min(moved.minY, best.other.minY)...max(moved.maxY, best.other.maxY)))
        }
        if let bestY {
            guides.append(WorkspaceGuide(axis: .horizontal, position: bestY.y,
                                         span: min(moved.minX, bestY.other.minX)...max(moved.maxX, bestY.other.maxX)))
        }
        return (CGSize(width: dx, height: dy), guides)
    }

    /// Resize snapping: same height as another tile, or right / bottom edge
    /// on another tile's edge.
    private func snapResize(id: UUID, origin: CGPoint, base: CGSize, scale: CGFloat) -> (CGFloat, [WorkspaceGuide]) {
        let others = state.tiles.filter { $0.id != id }.map(rect(of:))
        let limit = Self.snapDistance / state.zoom
        let w = base.width * scale, h = base.height * scale + headerC
        var best: (scale: CGFloat, dist: CGFloat, guide: WorkspaceGuide)?
        func consider(_ s: CGFloat, _ dist: CGFloat, _ g: WorkspaceGuide) {
            if dist <= limit && dist < (best?.dist ?? .infinity) && s > 0.05 { best = (s, dist, g) }
        }
        for o in others {
            // equal height
            consider((o.height - headerC) / base.height, abs(o.height - h),
                     WorkspaceGuide(axis: .horizontal, position: origin.y + o.height,
                                    span: min(origin.x, o.minX)...max(origin.x + w, o.maxX)))
            for t in [o.minY, o.midY, o.maxY] {
                consider((t - origin.y - headerC) / base.height, abs(origin.y + h - t),
                         WorkspaceGuide(axis: .horizontal, position: t,
                                        span: min(origin.x, o.minX)...max(origin.x + w, o.maxX)))
            }
            for t in [o.minX - Self.gap, o.minX, o.midX, o.maxX] {
                consider((t - origin.x) / base.width, abs(origin.x + w - t),
                         WorkspaceGuide(axis: .vertical, position: t,
                                        span: min(origin.y, o.minY)...max(origin.y + h, o.maxY)))
            }
        }
        // pixel accurate: one panel pixel per screen pixel
        let pixel = 1 / backingScale / state.zoom
        if abs(pixel - scale) * base.width <= limit {
            return (pixel, [])
        }
        guard let best else { return (scale, []) }
        return (best.scale, [best.guide])
    }

    // MARK: Canvas

    func pan(by d: CGSize) {
        update { $0.offset.width += d.width; $0.offset.height += d.height }
    }

    /// Zooms the canvas about a view point.
    func zoom(by factor: CGFloat, around p: CGPoint) {
        let z = max(0.1, min(4, state.zoom * factor))
        let c = viewToCanvas(p)
        update { s in
            s.zoom = z
            s.offset = CGSize(width: p.x - c.x * z, height: p.y - c.y * z)
        }
    }

    func resetZoom() {
        zoom(by: 1 / state.zoom, around: CGPoint(x: viewport.width / 2, y: viewport.height / 2))
    }

    /// Zooms and scrolls so every tile is in view.
    func fitAll() {
        guard state.layout == .free, !state.tiles.isEmpty else { return }
        let box = state.tiles.map(rect(of:)).reduce(CGRect.null) { $0.union($1) }
        let avail = CGSize(width: viewport.width - 2 * Self.margin, height: viewport.height - 2 * Self.margin)
        let z = max(0.1, min(2, avail.width / box.width, avail.height / box.height))
        update { s in
            s.zoom = z
            s.offset = CGSize(width: viewport.width / 2 - box.midX * z, height: viewport.height / 2 - box.midY * z)
        }
    }

    // MARK: Arranging

    private func setRects(_ change: (inout [UUID: CGRect]) -> Void) {
        var rects = Dictionary(uniqueKeysWithValues: state.tiles.map { ($0.id, rect(of: $0)) })
        change(&rects)
        update { s in
            for i in s.tiles.indices {
                if let r = rects[s.tiles[i].id] {
                    s.tiles[i].center = CGPoint(x: r.midX, y: r.midY)
                }
            }
        }
    }

    func align(_ a: WorkspaceAlignment) {
        enterFree()
        let ids = targets
        let rs = ids.compactMap { tile($0).map(rect(of:)) }
        guard rs.count >= 2 else { return }
        let box = rs.reduce(CGRect.null) { $0.union($1) }
        setRects { rects in
            for id in ids {
                guard var r = rects[id] else { continue }
                switch a {
                case .left: r.origin.x = box.minX
                case .centerX: r.origin.x = box.midX - r.width / 2
                case .right: r.origin.x = box.maxX - r.width
                case .top: r.origin.y = box.minY
                case .centerY: r.origin.y = box.midY - r.height / 2
                case .bottom: r.origin.y = box.maxY - r.height
                }
                rects[id] = r
            }
        }
    }

    /// Equal gaps between the targets, keeping the outermost two in place.
    func distribute(horizontally: Bool) {
        enterFree()
        let ids = targets.sorted { a, b in
            let ra = tile(a).map(rect(of:)) ?? .zero, rb = tile(b).map(rect(of:)) ?? .zero
            return horizontally ? ra.midX < rb.midX : ra.midY < rb.midY
        }
        guard ids.count >= 3 else { return arrange(horizontally: horizontally) }
        let rs = ids.compactMap { tile($0).map(rect(of:)) }
        let total = rs.reduce(0) { $0 + (horizontally ? $1.width : $1.height) }
        let span = horizontally ? rs.last!.maxX - rs.first!.minX : rs.last!.maxY - rs.first!.minY
        let gap = (span - total) / CGFloat(rs.count - 1)
        setRects { rects in
            var pos = horizontally ? rs.first!.minX : rs.first!.minY
            for id in ids {
                guard var r = rects[id] else { continue }
                if horizontally { r.origin.x = pos; pos += r.width + gap } else { r.origin.y = pos; pos += r.height + gap }
                rects[id] = r
            }
        }
    }

    /// Gives the targets the height of the first one picked (or the
    /// tallest), so different devices line up.
    func matchSize() {
        enterFree()
        let ids = targets
        guard let ref = (front.flatMap { f in ids.contains(f) ? f : nil } ?? ids.first).flatMap(tile) else { return }
        let height = rect(of: ref).height - headerC
        let header = headerC
        update { s in
            for i in s.tiles.indices where ids.contains(s.tiles[i].id) {
                let r = self.rect(of: s.tiles[i])
                let b = self.baseSize(s.tiles[i].id)
                s.tiles[i].scale = max(0.08, height / b.height)
                // keep the top-left corner
                let size = CGSize(width: b.width * s.tiles[i].scale, height: height + header)
                s.tiles[i].center = CGPoint(x: r.minX + size.width / 2, y: r.minY + size.height / 2)
            }
        }
    }

    /// A row (or column) in the current left-to-right order, evenly gapped,
    /// middles aligned.
    func arrange(horizontally: Bool) {
        enterFree()
        let ids = targets.sorted { a, b in
            let ra = tile(a).map(rect(of:)) ?? .zero, rb = tile(b).map(rect(of:)) ?? .zero
            return horizontally ? ra.minX < rb.minX : ra.minY < rb.minY
        }
        let rs = ids.compactMap { tile($0).map(rect(of:)) }
        guard let first = rs.first else { return }
        let box = rs.reduce(CGRect.null) { $0.union($1) }
        setRects { rects in
            var pos = horizontally ? first.minX : first.minY
            for id in ids {
                guard var r = rects[id] else { continue }
                if horizontally {
                    r.origin = CGPoint(x: pos, y: box.midY - r.height / 2)
                    pos += r.width + Self.gap
                } else {
                    r.origin = CGPoint(x: box.midX - r.width / 2, y: pos)
                    pos += r.height + Self.gap
                }
                rects[id] = r
            }
        }
    }

    /// Every device the same height, in rows that fill the visible canvas:
    /// the tallest height at which they all wrap into it.
    func tidy() {
        enterFree()
        let ids = targets
        guard !ids.isEmpty else { return }
        let header = headerC
        let width = (viewport.width - 2 * Self.margin) / state.zoom
        let height = (viewport.height - 2 * Self.margin) / state.zoom
        let aspects = ids.map { id -> CGFloat in let b = baseSize(id); return b.width / b.height }
        // rows needed at case height h, and their total height
        func fits(_ h: CGFloat) -> Bool {
            var x: CGFloat = 0, rows = 1
            for a in aspects {
                let w = a * h
                if x > 0 && x + w > width { rows += 1; x = 0 }
                x += w + Self.gap
            }
            return CGFloat(rows) * (h + header) + CGFloat(rows - 1) * Self.gap <= height
        }
        var lo: CGFloat = 40, hi = max(40, height - header)
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if fits(mid) { lo = mid } else { hi = mid }
        }
        let caseHeight = lo
        update { s in
            for i in s.tiles.indices where ids.contains(s.tiles[i].id) {
                s.tiles[i].scale = max(0.08, caseHeight / self.baseSize(s.tiles[i].id).height)
            }
        }
        let origin = viewToCanvas(CGPoint(x: Self.margin, y: Self.margin))
        setRects { rects in
            var x = origin.x, y = origin.y
            for id in ids {
                guard var r = rects[id] else { continue }
                if x > origin.x && x + r.width > origin.x + width {
                    x = origin.x
                    y += caseHeight + header + Self.gap
                }
                r.origin = CGPoint(x: x, y: y)
                x += r.width + Self.gap
                rects[id] = r
            }
        }
    }

    /// Arranging commands work on freeform positions.
    private func enterFree() {
        if state.layout != .free { layout = .free }
    }

    /// Nudges the selection with the arrow keys.
    func nudge(dx: CGFloat, dy: CGFloat) {
        guard state.layout == .free else { return }
        let ids = selection
        update { s in
            for i in s.tiles.indices where ids.contains(s.tiles[i].id) {
                s.tiles[i].center.x += dx
                s.tiles[i].center.y += dy
            }
        }
    }
}
