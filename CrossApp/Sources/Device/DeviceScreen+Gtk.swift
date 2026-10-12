#if !os(Windows)
import CGtk
import Gtk
import GtkBackend
import MirageKit
import SwiftCrossUI

/// The emulator's panel in GTK: VNC frames as a texture in a GtkPicture,
/// a drag gesture as the finger, Home / Page Up / Page Down as the
/// hardware buttons.
struct DeviceScreen: GtkWidgetRepresentable {
    let session: DeviceSession
    let profile: DeviceProfile
    /// Size on the stage, in points.
    let width: Int
    let height: Int

    @MainActor
    final class Coordinator {
        let feed = ScreenFeed()
        var drag: GtkSignals?
        var keys: GtkSignals?
        var profile: DeviceProfile?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeGtkWidget(context: Context) -> Gtk.Picture {
        let picture = Gtk.Picture()
        picture.canShrink = true
        picture.keepAspectRatio = false
        let c = context.coordinator
        c.profile = profile
        let pointer = picture.widgetPointer
        gtk_widget_set_focusable(pointer, 1)
        c.feed.onFrame = { [weak picture] frame in picture?.show(frame) }

        let feed = c.feed
        var start = (x: 0.0, y: 0.0)
        let size = { (Double(gtk_widget_get_width(pointer)), Double(gtk_widget_get_height(pointer))) }
        c.drag = GtkSignals.dragGesture(on: pointer) { phase, x, y in
            let (w, h) = size()
            switch phase {
            case .begin:
                gtk_widget_grab_focus(pointer)
                start = (x, y)
                feed.touch(x: x, y: y, viewWidth: w, viewHeight: h, down: true)
            case .update:
                feed.touch(x: start.x + x, y: start.y + y, viewWidth: w, viewHeight: h, down: true)
            case .end:
                feed.touch(x: start.x + x, y: start.y + y, viewWidth: w, viewHeight: h, down: false)
            }
        }
        c.keys = GtkSignals.keyController(on: pointer) { [weak c] keyval, down in
            guard let c, let profile = c.profile, let qcode = Self.qcode(keyval) else { return false }
            c.feed.key(qcode, down: down, profile: profile)
            return true
        }
        c.feed.attach(session, panel: (profile.screen.width, profile.screen.height))
        return picture
    }

    func updateGtkWidget(_ picture: Gtk.Picture, context: Context) {
        context.coordinator.profile = profile
        context.coordinator.feed.attach(session, panel: (profile.screen.width, profile.screen.height))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, gtkWidget: Gtk.Picture, context: Context) -> ViewSize {
        ViewSize(Double(width), Double(height))
    }

    static func dismantleGtkWidget(_ picture: Gtk.Picture, coordinator: Coordinator) {
        coordinator.feed.detach()
    }

    private static func qcode(_ keyval: UInt32) -> String? {
        switch keyval {
        case 0xFF50: return "home"   // GDK_KEY_Home
        case 0xFF55: return "pgup"   // GDK_KEY_Page_Up
        case 0xFF56: return "pgdn"   // GDK_KEY_Page_Down
        default: return nil
        }
    }
}

extension Gtk.Picture {
    /// Shows a frame (B,G,R,X bytes) as a memory texture.
    func show(_ frame: VNCClient.Frame) {
        guard frame.width > 0, frame.height > 0 else { return }
        let bytes = frame.pixels.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        let texture = gdk_memory_texture_new(Int32(frame.width), Int32(frame.height),
                                             GDK_MEMORY_B8G8R8X8, bytes, gsize(frame.width * 4))
        g_bytes_unref(bytes)
        paintable = texture
        g_object_unref(UnsafeMutableRawPointer(texture))
    }
}

/// Signal handlers the generated bindings don't offer (GtkGestureDrag and a
/// key controller whose handler returns whether it took the key). Owns the
/// closures until the controller is destroyed with its widget.
final class GtkSignals {
    enum DragPhase { case begin, update, end }

    private var drag: ((DragPhase, Double, Double) -> Void)?
    private var key: ((UInt32, Bool) -> Bool)?

    private init() {}

    @MainActor
    static func dragGesture(on widget: UnsafeMutablePointer<GtkWidget>,
                            _ handler: @escaping (DragPhase, Double, Double) -> Void) -> GtkSignals {
        let box = GtkSignals()
        box.drag = handler
        let gesture = gtk_gesture_drag_new()
        typealias Handler = @convention(c) (OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> Void
        let begin: Handler = { _, x, y, data in GtkSignals.box(data)?.drag?(.begin, x, y) }
        let update: Handler = { _, x, y, data in GtkSignals.box(data)?.drag?(.update, x, y) }
        let end: Handler = { _, x, y, data in GtkSignals.box(data)?.drag?(.end, x, y) }
        connect(gesture, "drag-begin", unsafeBitCast(begin, to: GCallback.self), box)
        connect(gesture, "drag-update", unsafeBitCast(update, to: GCallback.self), box)
        connect(gesture, "drag-end", unsafeBitCast(end, to: GCallback.self), box)
        gtk_widget_add_controller(widget, gesture)
        return box
    }

    @MainActor
    static func keyController(on widget: UnsafeMutablePointer<GtkWidget>,
                              _ handler: @escaping (UInt32, Bool) -> Bool) -> GtkSignals {
        let box = GtkSignals()
        box.key = handler
        let controller = gtk_event_controller_key_new()
        typealias Handler = @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?) -> gboolean
        let pressed: Handler = { _, keyval, _, _, data in GtkSignals.box(data)?.key?(keyval, true) == true ? 1 : 0 }
        let released: @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Void = {
            _, keyval, _, _, data in _ = GtkSignals.box(data)?.key?(keyval, false)
        }
        connect(controller, "key-pressed", unsafeBitCast(pressed, to: GCallback.self), box)
        connect(controller, "key-released", unsafeBitCast(released, to: GCallback.self), box)
        gtk_widget_add_controller(widget, controller)
        return box
    }

    fileprivate static func box(_ data: UnsafeMutableRawPointer?) -> GtkSignals? {
        data.map { Unmanaged<GtkSignals>.fromOpaque($0).takeUnretainedValue() }
    }

    private static func connect(_ instance: OpaquePointer?, _ signal: String, _ callback: GCallback, _ box: GtkSignals) {
        let release: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
            if let data { Unmanaged<GtkSignals>.fromOpaque(data).release() }
        }
        g_signal_connect_data(UnsafeMutableRawPointer(instance), signal, callback,
                              Unmanaged.passRetained(box).toOpaque(), release, GConnectFlags(rawValue: 0))
    }
}
#endif
