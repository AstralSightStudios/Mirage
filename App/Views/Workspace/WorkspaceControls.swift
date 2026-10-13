import MirageKit
import SwiftUI

/// Device / Workspace switch at the left of the toolbar.
struct ViewModePicker: View {
    @Binding var workspace: Bool

    var body: some View {
        Picker("View", selection: $workspace) {
            Label("Device", systemImage: "applewatch").tag(false)
            Label("Workspace", systemImage: "rectangle.3.group").tag(true)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .help("Show one device, or every device on the workspace (⇧⌘E)")
    }
}

/// The workspace's layout and arranging controls.
struct WorkspaceToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        let ws = model.workspace
        ToolbarItemGroup {
            Picker("Layout", selection: Binding(get: { ws.layout }, set: { ws.layout = $0 })) {
                ForEach(WorkspaceLayout.allCases) { l in
                    Label(l.title, systemImage: l.symbol).tag(l)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Layout: freeform, or a fixed split of the window")
            Menu {
                WorkspaceArrangeItems(model: model)
            } label: {
                Label("Arrange", systemImage: "align.horizontal.center")
            }
            .help("Align, distribute and size the selected devices (all when none are selected)")
            Button {
                ws.fitAll()
            } label: {
                Label("Fit All", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Zoom the canvas so every device is in view (⌘0)")
            .disabled(ws.layout != .free || ws.tiles.isEmpty)
        }
    }
}

/// Arrange commands, shared by the toolbar menu and the Workspace menu.
struct WorkspaceArrangeItems: View {
    let model: AppModel
    var shortcuts = false

    var body: some View {
        let ws = model.workspace
        let none = ws.tiles.count < 2
        Section("Align") {
            item("Align Left Edges", "align.horizontal.left", .leftArrow) { ws.align(.left) }
            item("Align Centers", "align.horizontal.center", nil) { ws.align(.centerX) }
            item("Align Right Edges", "align.horizontal.right", .rightArrow) { ws.align(.right) }
            item("Align Top Edges", "align.vertical.top", .upArrow) { ws.align(.top) }
            item("Align Middles", "align.vertical.center", nil) { ws.align(.centerY) }
            item("Align Bottom Edges", "align.vertical.bottom", .downArrow) { ws.align(.bottom) }
        }
        .disabled(none)
        Section("Arrange") {
            item("Distribute Horizontally", "distribute.horizontal.center", "h") { ws.distribute(horizontally: true) }
            item("Distribute Vertically", "distribute.vertical.center", "j") { ws.distribute(horizontally: false) }
            item("Make Same Height", "arrow.up.and.down.square", "=") { ws.matchSize() }
            item("Arrange in a Row", "rectangle.split.3x1", "r") { ws.arrange(horizontally: true) }
            item("Arrange in a Column", "rectangle.split.1x2", "c") { ws.arrange(horizontally: false) }
            item("Tidy Up", "square.grid.3x2", "t") { ws.tidy() }
        }
        .disabled(none)
        Section {
            Toggle("Snap While Dragging", isOn: Binding(get: { ws.snapping }, set: { ws.snapping = $0 }))
            Toggle("Show Grid", isOn: Binding(get: { ws.showGrid }, set: { ws.showGrid = $0 }))
            Toggle("Add Devices When They Boot", isOn: Binding(get: { ws.autoAdd }, set: { ws.autoAdd = $0 }))
        }
        Section {
            Button("Add All Running Devices") {
                for (id, s) in model.sessions where s.state.isActive { ws.add(id) }
            }
            Button("Actual Size") { ws.resetZoom() }
                .disabled(ws.layout != .free)
            Button("Remove Selected from Workspace") { ws.remove(ws.selection) }
                .disabled(ws.selection.isEmpty)
        }
    }

    @ViewBuilder
    private func item(_ title: String, _ symbol: String, _ key: KeyEquivalent?, action: @escaping () -> Void) -> some View {
        if shortcuts, let key {
            Button(action: action) { Label(title, systemImage: symbol) }
                .keyboardShortcut(key, modifiers: [.control, .command])
        } else {
            Button(action: action) { Label(title, systemImage: symbol) }
        }
    }
}
