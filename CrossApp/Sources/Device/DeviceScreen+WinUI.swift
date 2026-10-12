#if os(Windows)
import Foundation
import MirageKit
import SwiftCrossUI
import UWP
import WinUI
import WinUIBackend
import WindowsFoundation

/// The emulator's panel in WinUI: VNC frames in a WriteableBitmap shown by
/// an Image, pointer press / move / release (captured) as the finger.
struct DeviceScreen: WinUIElementRepresentable {
    let session: DeviceSession
    let profile: DeviceProfile
    /// Size on the stage, in points.
    let width: Int
    let height: Int

    @MainActor
    final class Coordinator {
        let feed = ScreenFeed()
        var bitmap: WriteableBitmap?
        var pressed = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeWinUIElement(context: Context) -> WinUI.Border {
        let border = WinUI.Border()
        let image = WinUI.Image()
        image.stretch = .fill
        border.child = image
        // a background makes the whole area hit-testable before the first frame
        let brush = WinUI.SolidColorBrush()
        brush.color = UWP.Color(a: 255, r: 0, g: 0, b: 0)
        border.background = brush

        let c = context.coordinator
        c.feed.onFrame = { [weak image, weak c] frame in
            guard let image, let c else { return }
            Self.show(frame, in: image, coordinator: c)
        }
        let feed = c.feed
        func send(_ args: PointerRoutedEventArgs?, down: Bool) {
            guard let args, let point = try? args.getCurrentPoint(border) else { return }
            feed.touch(x: Double(point.position.x), y: Double(point.position.y),
                       viewWidth: border.actualWidth, viewHeight: border.actualHeight, down: down)
        }
        border.pointerPressed.addHandler { [weak border, weak c] _, args in
            guard let border, let c, let args else { return }
            c.pressed = true
            _ = try? border.capturePointer(args.pointer)
            send(args, down: true)
        }
        border.pointerMoved.addHandler { [weak c] _, args in
            guard let c, c.pressed else { return }
            send(args, down: true)
        }
        border.pointerReleased.addHandler { [weak border, weak c] _, args in
            guard let border, let c, c.pressed, let args else { return }
            c.pressed = false
            send(args, down: false)
            try? border.releasePointerCapture(args.pointer)
        }
        border.pointerCaptureLost.addHandler { [weak c] _, args in
            guard let c, c.pressed else { return }
            c.pressed = false
            send(args, down: false)
        }
        c.feed.attach(session, panel: (profile.screen.width, profile.screen.height))
        return border
    }

    func updateWinUIElement(_ border: WinUI.Border, context: Context) {
        border.width = Double(width)
        border.height = Double(height)
        context.coordinator.feed.attach(session, panel: (profile.screen.width, profile.screen.height))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: WinUI.Border, context: Context) -> ViewSize {
        ViewSize(Double(width), Double(height))
    }

    static func dismantleWinUIElement(_ border: WinUI.Border, coordinator: Coordinator) {
        coordinator.feed.detach()
    }

    /// Copies a frame (B,G,R,X bytes) into the bitmap, which WinUI reads as BGRA.
    @MainActor
    private static func show(_ frame: VNCClient.Frame, in image: WinUI.Image, coordinator c: Coordinator) {
        guard frame.width > 0, frame.height > 0 else { return }
        var bitmap = c.bitmap
        if bitmap == nil || bitmap!.pixelWidth != Int32(frame.width) || bitmap!.pixelHeight != Int32(frame.height) {
            bitmap = WriteableBitmap(Int32(frame.width), Int32(frame.height))
            c.bitmap = bitmap
            image.source = bitmap
        }
        guard let bitmap, let pixels = bitmap.pixelBuffer, let buffer = try? pixels.buffer else { return }
        let count = min(Int(pixels.length), frame.pixels.count)
        frame.pixels.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }
            memcpy(buffer, base, count)
        }
        // X is undefined in the frame; WinUI blends on alpha
        var i = 3
        while i < count {
            buffer[i] = 255
            i += 4
        }
        try? bitmap.invalidate()
    }
}
#endif
