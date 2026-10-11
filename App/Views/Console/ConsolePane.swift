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

/// Owns the SwiftTerm view so it survives SwiftUI updates.
@MainActor
final class TerminalController: NSObject, ObservableObject, TerminalViewDelegate {
    let view: TerminalView
    weak var session: DeviceSession?
    private var token: UUID?

    override init() {
        view = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        super.init()
        view.terminalDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(white: 0.08, alpha: 1)
        view.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
        view.caretColor = .systemGreen
        view.optionAsMetaKey = false
    }

    func bind(_ s: DeviceSession) {
        guard session !== s else { return }
        if let token, let session { session.removeObserver(token) }
        session = s
        clear()
        token = s.observeConsole { [weak self] data in
            self?.view.feed(byteArray: ArraySlice([UInt8](data)))
        }
    }

    func unbind() {
        if let token, let session { session.removeObserver(token) }
        token = nil
        session = nil
    }

    func clear() {
        view.feed(text: "\u{1B}c")
    }

    func copyAll() {
        let text = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func focus() {
        view.window?.makeFirstResponder(view)
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

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            controller.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            controller.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        controller.bind(session)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        controller.bind(session)
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
        List {
            Section("Common") {
                ForEach(Self.common, id: \.0) { cmd, icon, title in
                    Button { session.run(cmd) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(title)
                                Text(cmd).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: icon) }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                ForEach(builtins.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }, id: \.self) { b in
                    Button { session.run(b) } label: {
                        Text(b).font(.callout.monospaced())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text("Builtins")
                    Spacer()
                    if builtins.isEmpty {
                        Button("Load") { Task { builtins = await BuiltinCatalog.shared.load(for: session) } }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter")
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
