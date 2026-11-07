import CTerminal
import Foundation
import MirageKit

/// Where the panel shows on the terminal, in terminal pixels.
struct Placement: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var panelWidth: Int
    var panelHeight: Int

    /// Panel pixel at terminal pixel (px, py), clamped to the panel, and
    /// whether the point is on it.
    func map(_ px: Double, _ py: Double) -> (x: Int, y: Int, inside: Bool) {
        let rx = (px - x) / width, ry = (py - y) / height
        let inside = (0..<1).contains(rx) && (0..<1).contains(ry)
        let vx = Int((rx * Double(panelWidth)).rounded(.down))
        let vy = Int((ry * Double(panelHeight)).rounded(.down))
        return (min(max(vx, 0), panelWidth - 1), min(max(vy, 0), panelHeight - 1), inside)
    }
}

/// Used by the render thread only.
protocol ScreenRenderer: AnyObject, Sendable {
    /// Draws the frame if it is new or the layout changed. Returns the
    /// placement when it changed.
    func draw(_ frame: VNCClient.Frame, in size: Terminal.Size, fresh: Bool) -> Placement?
}

/// Coverage of the panel's glass per pixel, so that a round watch is round:
/// 255 inside, 0 outside the circle or rounded corners.
private func panelMask(width: Int, height: Int, screen: DeviceProfile.Screen?) -> [UInt8] {
    var mask = [UInt8](repeating: 255, count: width * height)
    guard let screen else { return mask }
    let w = Double(width), h = Double(height)
    let scale = w / Double(max(screen.width, 1))
    let r = screen.shape == .circle ? min(w, h) / 2 : min(screen.cornerRadius * scale, min(w, h) / 2)
    guard r > 0 else { return mask }
    for y in 0..<height {
        let cy = Double(y) + 0.5
        let dy = max(r - cy, cy - (h - r), 0)
        guard dy > 0 else { continue }
        for x in 0..<width {
            let cx = Double(x) + 0.5
            let dx = max(r - cx, cx - (w - r), 0)
            guard dx > 0 else { continue }
            let cover = min(max(r - (dx * dx + dy * dy).squareRoot() + 0.5, 0), 1)
            mask[y * width + x] = UInt8(cover * 255)
        }
    }
    return mask
}

private extension Array where Element == UInt8 {
    mutating func append(_ s: String) {
        append(contentsOf: s.utf8)
    }
}

// MARK: Kitty graphics

/// Draws frames with the kitty graphics protocol at the panel's resolution;
/// the terminal scales them. The image is padded with transparent pixels to
/// the aspect ratio of the cells it fills, so the panel keeps its own.
final class KittyRenderer: ScreenRenderer, @unchecked Sendable {
    private struct Layout: Equatable {
        var size: Terminal.Size
        var canvasWidth: Int
        var canvasHeight: Int
        var columns: Int
        var rows: Int
        var column: Int
        var row: Int
        var placement: Placement
    }

    private static let chunk = 4096

    private let terminal: Terminal
    private let screen: DeviceProfile.Screen?
    private var sharedMemory: Bool
    private var layout: Layout?
    private var mask: [UInt8] = []
    private var canvas: [UInt8] = []
    private var out: [UInt8] = []
    /// Image currently on screen, 0 if none
    private var imageID = 0
    private var shmSequence = 0

    init(_ terminal: Terminal, screen: DeviceProfile.Screen?) {
        self.terminal = terminal
        self.screen = screen
        sharedMemory = terminal.graphics == .kittySharedMemory
    }

    func draw(_ frame: VNCClient.Frame, in size: Terminal.Size, fresh: Bool) -> Placement? {
        let (vw, vh) = (frame.width, frame.height)
        guard vw > 0, vh > 0, frame.pixels.count >= vw * vh * 4 else { return nil }
        let l = Self.layout(size, vw, vh)
        let moved = layout != l
        guard fresh || moved else { return nil }
        if moved { canvas = [UInt8](repeating: 0, count: l.canvasWidth * l.canvasHeight * 4) }
        if mask.count != vw * vh { mask = panelMask(width: vw, height: vh, screen: screen) }
        fill(frame, l)

        out.removeAll(keepingCapacity: true)
        // Synchronized output: the terminal shows the whole update at once
        out.append("\u{1B}[?2026h")
        if moved {
            // Drop the previous placement and any leftover from a resize
            out.append("\u{1B}_Ga=d,d=A,q=2\u{1B}\\\u{1B}[2J")
        }
        // Alternate between two images and delete the old one only once the
        // new one is placed, so that the screen never shows neither
        let shown = imageID
        imageID = shown == 1 ? 2 : 1
        out.append("\u{1B}[\(l.row + 1);\(l.column + 1)H")
        let keys = "a=T,f=32,s=\(l.canvasWidth),v=\(l.canvasHeight),i=\(imageID),c=\(l.columns),r=\(l.rows),C=1,q=2"
        if !(sharedMemory && encodeSharedMemory(keys)) { encodeDirect(keys) }
        if shown != 0 { out.append("\u{1B}_Ga=d,d=I,i=\(shown),q=2\u{1B}\\") }
        out.append("\u{1B}[?2026l")
        terminal.write(out)

        layout = l
        return moved ? l.placement : nil
    }

    /// Fits the panel in the window, centered, in whole cells.
    private static func layout(_ size: Terminal.Size, _ vw: Int, _ vh: Int) -> Layout {
        let cw = Double(size.cellWidth), ch = Double(size.cellHeight)
        let s = min(Double(size.columns) * cw / Double(vw), Double(size.rows) * ch / Double(vh))
        let columns = min(size.columns, max(1, Int((Double(vw) * s / cw - 1e-6).rounded(.up))))
        let rows = min(size.rows, max(1, Int((Double(vh) * s / ch - 1e-6).rounded(.up))))
        let canvasWidth = max(vw, Int((Double(columns) * cw / s).rounded()))
        let canvasHeight = max(vh, Int((Double(rows) * ch / s).rounded()))
        let column = (size.columns - columns) / 2, row = (size.rows - rows) / 2
        // Terminal pixels per canvas pixel
        let tx = Double(columns) * cw / Double(canvasWidth), ty = Double(rows) * ch / Double(canvasHeight)
        let placement = Placement(
            x: Double(column) * cw + Double((canvasWidth - vw) / 2) * tx,
            y: Double(row) * ch + Double((canvasHeight - vh) / 2) * ty,
            width: Double(vw) * tx, height: Double(vh) * ty, panelWidth: vw, panelHeight: vh)
        return Layout(size: size, canvasWidth: canvasWidth, canvasHeight: canvasHeight, columns: columns,
                      rows: rows, column: column, row: row, placement: placement)
    }

    /// BGRX frame into the middle of the RGBA canvas, masked.
    private func fill(_ frame: VNCClient.Frame, _ l: Layout) {
        let (vw, vh) = (frame.width, frame.height)
        let ox = (l.canvasWidth - vw) / 2, oy = (l.canvasHeight - vh) / 2
        frame.pixels.withUnsafeBytes { src in
            mask.withUnsafeBufferPointer { m in
                canvas.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<vh {
                        var s = y * vw * 4, d = ((y + oy) * l.canvasWidth + ox) * 4, k = y * vw
                        for _ in 0..<vw {
                            dst[d] = src[s + 2]
                            dst[d + 1] = src[s + 1]
                            dst[d + 2] = src[s]
                            dst[d + 3] = m[k]
                            s += 4
                            d += 4
                            k += 1
                        }
                    }
                }
            }
        }
    }

    private func encodeDirect(_ keys: String) {
        let payload = Data(canvas).base64EncodedData()
        var offset = 0
        repeat {
            let end = min(offset + Self.chunk, payload.count)
            let more = end < payload.count ? 1 : 0
            out.append(offset == 0 ? "\u{1B}_G\(keys),m=\(more);" : "\u{1B}_Gm=\(more);")
            out.append(contentsOf: payload[offset..<end])
            out.append("\u{1B}\\")
            offset = end
        } while offset < payload.count
    }

    private func encodeSharedMemory(_ keys: String) -> Bool {
        shmSequence &+= 1
        // macOS limits shm names to 31 bytes
        let name = "/mirage.\(ProcessInfo.processInfo.processIdentifier).\(shmSequence)"
        guard mirage_shm_write(name, canvas, canvas.count) == 0 else {
            sharedMemory = false
            return false
        }
        // The terminal unlinks the object once it has read it
        out.append("\u{1B}_G\(keys),t=s,S=\(canvas.count);\(Data(name.utf8).base64EncodedString())\u{1B}\\")
        return true
    }
}

// MARK: Half blocks

/// Draws frames with upper and lower half blocks in 24-bit colour, two
/// pixels per cell, for terminals without kitty graphics. Only cells that
/// changed are redrawn.
final class BlockRenderer: ScreenRenderer, @unchecked Sendable {
    private struct Layout: Equatable {
        var size: Terminal.Size
        /// Picture size in cells and half cells
        var columns: Int
        var halfRows: Int
        var column: Int
        /// First row, in half cells (even)
        var halfRow: Int
        var placement: Placement
    }

    /// Transparent pixel: the terminal's background shows
    private static let clear = UInt32.max

    private let terminal: Terminal
    private let screen: DeviceProfile.Screen?
    private var layout: Layout?
    private var mask: [UInt8] = []
    private var pixels: [UInt32] = []
    /// Top and bottom colour of each cell on screen
    private var cells: [UInt32] = []
    private var out: [UInt8] = []

    init(_ terminal: Terminal, screen: DeviceProfile.Screen?) {
        self.terminal = terminal
        self.screen = screen
    }

    func draw(_ frame: VNCClient.Frame, in size: Terminal.Size, fresh: Bool) -> Placement? {
        let (vw, vh) = (frame.width, frame.height)
        guard vw > 0, vh > 0, frame.pixels.count >= vw * vh * 4 else { return nil }
        let l = Self.layout(size, vw, vh)
        let moved = layout != l
        guard fresh || moved else { return nil }
        if mask.count != vw * vh { mask = panelMask(width: vw, height: vh, screen: screen) }
        sample(frame, l)

        let rows = (l.halfRows + 1) / 2
        if moved { cells = [UInt32](repeating: 0, count: rows * l.columns * 2) }
        out.removeAll(keepingCapacity: true)
        out.append("\u{1B}[?2026h\u{1B}[0m")
        if moved { out.append("\u{1B}[2J") }
        var fg: UInt32?
        var bg = Self.clear
        var cursor: (row: Int, column: Int)?
        for r in 0..<rows {
            for c in 0..<l.columns {
                let top = pixels[2 * r * l.columns + c]
                let bottom = 2 * r + 1 < l.halfRows ? pixels[(2 * r + 1) * l.columns + c] : Self.clear
                let i = (r * l.columns + c) * 2
                if !moved && cells[i] == top && cells[i + 1] == bottom { continue }
                cells[i] = top
                cells[i + 1] = bottom

                let row = l.halfRow / 2 + r, column = l.column + c
                if cursor?.row != row || cursor?.column != column { out.append("\u{1B}[\(row + 1);\(column + 1)H") }
                let glyph: String, wantFg: UInt32?, wantBg: UInt32
                switch (top == Self.clear, bottom == Self.clear) {
                case (true, true): (glyph, wantFg, wantBg) = (" ", nil, Self.clear)
                case (false, true): (glyph, wantFg, wantBg) = ("▀", top, Self.clear)
                case (true, false): (glyph, wantFg, wantBg) = ("▄", bottom, Self.clear)
                case (false, false): (glyph, wantFg, wantBg) = top == bottom ? (" ", nil, top) : ("▀", top, bottom)
                }
                if let wantFg, wantFg != fg {
                    out.append("\u{1B}[38;2;\(wantFg >> 16);\(wantFg >> 8 & 0xFF);\(wantFg & 0xFF)m")
                    fg = wantFg
                }
                if wantBg != bg {
                    out.append(wantBg == Self.clear ? "\u{1B}[49m"
                        : "\u{1B}[48;2;\(wantBg >> 16);\(wantBg >> 8 & 0xFF);\(wantBg & 0xFF)m")
                    bg = wantBg
                }
                out.append(glyph)
                cursor = (row, column + 1)
            }
        }
        out.append("\u{1B}[0m\u{1B}[?2026l")
        terminal.write(out)

        layout = l
        return moved ? l.placement : nil
    }

    /// Fits the panel in the window, centered; a half cell is one pixel.
    private static func layout(_ size: Terminal.Size, _ vw: Int, _ vh: Int) -> Layout {
        let cw = Double(size.cellWidth), ch = Double(size.cellHeight)
        let s = min(Double(size.columns) * cw / Double(vw), Double(size.rows) * ch / Double(vh))
        let columns = min(size.columns, max(1, Int((Double(vw) * s / cw).rounded())))
        let halfRows = min(size.rows * 2, max(1, Int((Double(vh) * s * 2 / ch).rounded())))
        let column = (size.columns - columns) / 2
        let halfRow = ((size.rows * 2 - halfRows) / 2) & ~1
        let placement = Placement(x: Double(column) * cw, y: Double(halfRow) * ch / 2,
                                  width: Double(columns) * cw, height: Double(halfRows) * ch / 2,
                                  panelWidth: vw, panelHeight: vh)
        return Layout(size: size, columns: columns, halfRows: halfRows, column: column, halfRow: halfRow,
                      placement: placement)
    }

    /// Box-filters the frame down to one colour per half cell; mostly masked
    /// boxes are transparent.
    private func sample(_ frame: VNCClient.Frame, _ l: Layout) {
        let (vw, vh) = (frame.width, frame.height)
        let (w, h) = (l.columns, l.halfRows)
        if pixels.count != w * h { pixels = [UInt32](repeating: Self.clear, count: w * h) }
        frame.pixels.withUnsafeBytes { src in
            mask.withUnsafeBufferPointer { m in
                pixels.withUnsafeMutableBufferPointer { dst in
                    for j in 0..<h {
                        let y0 = j * vh / h, y1 = max(y0 + 1, (j + 1) * vh / h)
                        for i in 0..<w {
                            let x0 = i * vw / w, x1 = max(x0 + 1, (i + 1) * vw / w)
                            var r = 0, g = 0, b = 0, a = 0
                            for y in y0..<y1 {
                                var k = y * vw + x0
                                for _ in x0..<x1 {
                                    let weight = Int(m[k]), p = k * 4
                                    b += Int(src[p]) * weight
                                    g += Int(src[p + 1]) * weight
                                    r += Int(src[p + 2]) * weight
                                    a += weight
                                    k += 1
                                }
                            }
                            let area = (x1 - x0) * (y1 - y0)
                            dst[j * w + i] = a * 2 < area * 255 ? Self.clear
                                : UInt32(r / a) << 16 | UInt32(g / a) << 8 | UInt32(b / a)
                        }
                    }
                }
            }
        }
    }
}
