import MirageKit
import SwiftTerm
import SwiftUI

/// The device's console: an interactive NSH terminal, a command bar with
/// history and the firmware's builtin commands, and the boot / QEMU logs.
struct ConsolePane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let device: VirtualDevice
    var poppedOut = false
    @State private var tab: Tab = .shell
    @State private var showCommands = true
    @StateObject private var terminal = TerminalController()

    enum Tab: String, CaseIterable, Identifiable {
        case shell = "Shell", boot = "Console Log", qemu = "QEMU Log"
        var id: String { rawValue }
    }

    var body: some View {
        let session = model.session(device.id)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                ShellBadge(session: session)
                Spacer()
                if tab == .shell {
                    Button { terminal.clear() } label: { Image(systemName: "trash") }
                        .help("Clear")
                    Button { terminal.copyAll() } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy All")
                    Toggle(isOn: $showCommands) { Image(systemName: "sidebar.right") }
                        .toggleStyle(.button)
                        .help("Commands")
                }
                if !poppedOut {
                    Button { openWindow(id: "console", value: device.id) } label: {
                        Image(systemName: "macwindow.on.rectangle")
                    }
                    .help("Open in Separate Window")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            switch tab {
            case .shell:
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        TerminalHost(controller: terminal, session: session)
                        Divider()
                        CommandBar(session: session, terminal: terminal)
                    }
                    if showCommands {
                        Divider()
                        CommandPalette(session: session)
                            .frame(width: 210)
                    }
                }
            case .boot:
                LogFileView(url: model.library.paths(for: device).consoleLog)
            case .qemu:
                LogFileView(url: model.library.paths(for: device).qemuLog,
                            extra: model.library.paths(for: device).stdoutLog)
            }
        }
        
    }
}

private struct ShellBadge: View {
    let session: DeviceSession

    var body: some View {
        let (text, color): (String, SwiftUI.Color) = {
            switch session.shell {
            case .ready(let pid): return ("NSH · task \(pid)", .green)
            case .injecting: return ("Starting shell…", .orange)
            case .failed: return ("Shell unavailable", .red)
            case .unavailable: return (session.state.isActive ? "Shell unavailable" : "Not running", .secondary)
            case .disabled: return ("Shell off", .secondary)
            }
        }()
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .help({ if case .failed(let m) = session.shell { return m } else { return "" } }())
    }
}

/// Routes console output to the currently mounted terminal view.
@MainActor
final class TerminalController: NSObject, ObservableObject, TerminalViewDelegate {
    private(set) weak var activeView: TerminalView?
    weak var session: DeviceSession?
    private var token: UUID?

    func attach(_ view: TerminalView, session: DeviceSession) {
        guard activeView !== view || self.session !== session else { return }
        unbind()
        activeView = view
        view.terminalDelegate = self
        self.session = session
        clear()
        token = session.observeConsole { [weak self] data in
            self?.activeView?.feed(byteArray: ArraySlice([UInt8](data)))
        }
    }

    func detach(_ view: TerminalView) {
        guard activeView === view else { return }
        unbind()
    }

    private func unbind() {
        if let token, let session { session.removeObserver(token) }
        activeView?.terminalDelegate = nil
        token = nil
        session = nil
        activeView = nil
    }

    func clear() {
        activeView?.feed(text: "\u{1B}c")
    }

    func copyAll() {
        guard let view = activeView else { return }
        let text = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func focus() {
        activeView?.window?.makeFirstResponder(activeView)
    }

    // MARK: TerminalViewDelegate

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let d = Data(data)
        MainActor.assumeIsolated { session?.sendConsole(d) }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        let text = String(decoding: content, as: UTF8.self)
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

private struct TerminalHost: NSViewRepresentable {
    let controller: TerminalController
    let session: DeviceSession

    func makeCoordinator() -> TerminalController { controller }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(white: 0.08, alpha: 1)
        view.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
        view.caretColor = .systemGreen
        view.optionAsMetaKey = false
        controller.attach(view, session: session)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        controller.attach(view, session: session)
    }

    static func dismantleNSView(_ view: TerminalView, coordinator: TerminalController) {
        coordinator.detach(view)
    }
}

/// One-line command entry with history (↑/↓) and completion of the
/// firmware's builtins.
private struct CommandBar: View {
    let session: DeviceSession
    let terminal: TerminalController
    @State private var text = ""
    @State private var cursor: Int?
    @AppStorage("MirageCommandHistory") private var historyData = Data()

    private var history: [String] {
        (try? JSONDecoder().decode([String].self, from: historyData)) ?? []
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right").foregroundStyle(.green).font(.caption.weight(.bold))
            TextField("Run an NSH command", text: $text)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .onSubmit(run)
                .onKeyPress(.upArrow) { step(-1); return .handled }
                .onKeyPress(.downArrow) { step(1); return .handled }
                .onKeyPress(.tab) { complete(); return .handled }
                .disabled(!ready)
            if !text.isEmpty {
                Button("Run", action: run).buttonStyle(.borderless).keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(SwiftUI.Color(white: 0.11))
    }

    private var ready: Bool {
        if case .ready = session.shell { return true }
        return false
    }

    private func run() {
        let cmd = text.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        session.run(cmd)
        var h = history.filter { $0 != cmd }
        h.append(cmd)
        historyData = (try? JSONEncoder().encode(Array(h.suffix(200)))) ?? Data()
        text = ""
        cursor = nil
    }

    private func step(_ d: Int) {
        let h = history
        guard !h.isEmpty else { return }
        let i = max(0, min(h.count, (cursor ?? h.count) + d))
        cursor = i
        text = i < h.count ? h[i] : ""
    }

    private func complete() {
        let words = BuiltinCatalog.shared.commands(for: session) + history
        guard let match = words.first(where: { $0.hasPrefix(text) && $0 != text }) else { return }
        text = match
    }
}

/// Builtins the running firmware offers (parsed from `help`).
@MainActor
final class BuiltinCatalog {
    static let shared = BuiltinCatalog()
    private var byDevice: [UUID: [String]] = [:]

    func commands(for session: DeviceSession) -> [String] {
        byDevice[session.deviceID] ?? []
    }

    func load(for session: DeviceSession) async -> [String] {
        if let c = byDevice[session.deviceID], !c.isEmpty { return c }
        guard let out = try? await session.execute("help", timeout: 8) else { return [] }
        let words = Self.parseHelp(out)
        byDevice[session.deviceID] = words
        return words
    }

    func forget(_ id: UUID) { byDevice[id] = nil }

    static func parseHelp(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasSuffix(":") || t.hasPrefix("help usage") { continue }
            for w in t.split(separator: " ") where w.count > 1 && w.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }) {
                out.append(String(w))
            }
        }
        return Array(Set(out)).sorted()
    }
}

/// Common commands and the firmware's builtins, one click to run.
private struct CommandPalette: View {
    let session: DeviceSession
    @State private var builtins: [String] = []
    @State private var filter = ""

    static let common: [(String, String, String)] = [
        ("ps", "list.bullet.rectangle", "Tasks"),
        ("free", "memorychip", "Memory"),
        ("df -h", "internaldrive", "File systems"),
        ("uptime", "clock", "Uptime"),
        ("uname -a", "info.circle", "Version"),
        ("ls /data", "folder", "List /data"),
        ("mount", "externaldrive.connected.to.line.below", "Mounts"),
        ("ifconfig", "network", "Network"),
        ("dmesg", "text.alignleft", "Kernel log"),
        ("getprop", "list.dash", "Properties"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Filter commands…", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.caption)
                if !filter.isEmpty {
                    Button { filter = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .padding(8)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("COMMON")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)

                    ForEach(Self.common, id: \.0) { cmd, icon, title in
                        Button { session.run(cmd) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: icon)
                                    .frame(width: 16)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(title).font(.caption.weight(.medium))
                                    Text(cmd).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Divider().padding(.vertical, 4)

                    HStack {
                        Text("BUILTINS")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if builtins.isEmpty {
                            Button("Load") { Task { builtins = await BuiltinCatalog.shared.load(for: session) } }
                                .buttonStyle(.borderless)
                                .font(.caption2)
                        }
                    }
                    .padding(.horizontal, 8)

                    ForEach(builtins.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }, id: \.self) { b in
                        Button { session.run(b) } label: {
                            Text(b)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(white: 0.09))
        .disabled({ if case .ready = session.shell { return false } else { return true } }())
        .task(id: session.shell) {
            if case .ready = session.shell {
                builtins = BuiltinCatalog.shared.commands(for: session)
            }
        }
    }
}

/// Follows a log file.
struct LogFileView: View {
    let url: URL
    var extra: URL?
    @State private var text = ""
    @State private var follow = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "No output yet." : text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                SwiftUI.Color.clear.frame(height: 1).id("end")
            }
            .background(SwiftUI.Color(white: 0.08))
            .foregroundStyle(SwiftUI.Color(white: 0.85))
            .overlay(alignment: .topTrailing) {
                HStack {
                    Toggle("Follow", isOn: $follow).toggleStyle(.checkbox).font(.caption)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
            }
            .task(id: url) {
                while !Task.isCancelled {
                    let t = Self.read(url, extra: extra)
                    if t != text {
                        text = t
                        if follow { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    static func read(_ url: URL, extra: URL?) -> String {
        func tail(_ u: URL) -> String {
            guard let fh = try? FileHandle(forReadingFrom: u) else { return "" }
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            let start = size > 400_000 ? size - 400_000 : 0
            try? fh.seek(toOffset: start)
            let d = (try? fh.readToEnd()) ?? Data()
            return NSHOutput.strip(String(decoding: d, as: UTF8.self))
        }
        var s = tail(url)
        if let extra {
            let e = tail(extra)
            if !e.isEmpty { s = e + (s.isEmpty ? "" : "\n" + s) }
        }
        return s
    }
}
