import Foundation
import MirageKit
import SwiftCrossUI

/// The device's console: NSH output with a command line, and the boot and
/// QEMU logs.
struct ConsolePane: View {
    var model: AppModel
    let device: VirtualDevice
    @State var tab: ConsoleTab = .shell
    @Environment(\.openWindow) var openWindow
    var poppedOut = false

    enum ConsoleTab: String, CaseIterable {
        case shell = "Shell", boot = "Console Log", qemu = "QEMU Log"
    }

    var body: some View {
        let session = model.session(device.id)
        VStack(spacing: 0) {
            HStack {
                TabBar(tabs: ConsoleTab.allCases, selection: $tab)
                Text(shellBadge(session)).font(.caption).foregroundColor(.gray)
                Spacer()
                if !poppedOut {
                    Button("Open in Window") { openWindow(id: "console") }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            switch tab {
            case .shell:
                ShellView(session: session)
            case .boot:
                LogFileView(url: model.library.paths(for: device).consoleLog)
            case .qemu:
                LogFileView(url: model.library.paths(for: device).qemuLog,
                            extra: model.library.paths(for: device).stdoutLog)
            }
        }
    }

    private func shellBadge(_ session: DeviceSession) -> String {
        switch session.shell {
        case .ready(let pid): return "NSH · task \(pid)"
        case .injecting: return "Starting shell…"
        case .failed(let m): return "Shell unavailable: \(m)"
        case .unavailable: return session.state.isActive ? "Shell unavailable" : "Not running"
        case .disabled: return "Shell off"
        }
    }
}

/// The selected device's console in its own window.
struct ConsoleWindow: View {
    var model: AppModel

    var body: some View {
        if let device = model.device(model.selection) {
            ConsolePane(model: model, device: device, poppedOut: true)
        } else {
            Text("No device selected").foregroundColor(.gray).padding()
        }
    }
}

/// Console output collected between screen updates.
@MainActor
final class ConsoleBuffer {
    var text = ""
    var changed = false

    func append(_ data: Data) {
        var chunk = String(decoding: data, as: UTF8.self)
        chunk = chunk.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "")
        text += NSHOutput.strip(chunk)
        if text.count > 200_000 { text = String(text.suffix(150_000)) }
        changed = true
    }
}

struct ShellView: View {
    let session: DeviceSession
    @State var output = ""
    @State var command = ""
    @State var history: [String] = []
    @State var builtins: [String] = []

    static let common: [(String, String)] = [
        ("ps", "Tasks"), ("free", "Memory"), ("df -h", "File systems"), ("uptime", "Uptime"),
        ("uname -a", "Version"), ("ls /data", "List /data"), ("mount", "Mounts"), ("dmesg", "Kernel log"),
    ]

    var body: some View {
        let ready: Bool = { if case .ready = session.shell { return true } else { return false } }()
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView {
                    Text(output.isEmpty ? "No output yet." : output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(white: 0.88))
                        .textSelectionEnabled()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color(white: 0.08))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 6) {
                    Text(">").foregroundColor(.green)
                    TextField("Run an NSH command", text: $command)
                        .onSubmit(perform: run)
                    Button("Run") { run() }.disabled(command.isEmpty || !ready)
                    Button("Ctrl-C") { session.sendConsole(Data([3])) }.disabled(!session.state.isActive)
                    Button("Clear") { output = "" }
                }
                .padding(6)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Footnote("COMMON")
                    ForEach(Self.common.map(CommandItem.init)) { item in
                        Button(item.title) { session.run(item.command) }.disabled(!ready)
                    }
                    Divider()
                    HStack {
                        Footnote("BUILTINS")
                        Spacer()
                        if builtins.isEmpty {
                            Button("Load") {
                                Task {
                                    guard let out = try? await session.execute("help", timeout: 8) else { return }
                                    builtins = Self.parseHelp(out)
                                }
                            }
                            .disabled(!ready)
                        }
                    }
                    ForEach(builtins.map { CommandItem(($0, $0)) }) { item in
                        Button(item.title) { session.run(item.command) }.disabled(!ready)
                    }
                    if !history.isEmpty {
                        Divider()
                        Footnote("HISTORY")
                        ForEach(history.reversed().prefix(20).map { CommandItem(($0, $0)) }) { item in
                            Button(item.title) { command = item.command }
                        }
                    }
                }
                .padding(8)
            }
            .frame(width: 200)
        }
        .task(id: session.deviceID) {
            let buffer = ConsoleBuffer()
            buffer.text = output
            let token = session.observeConsole { data in MainActor.assumeIsolated { buffer.append(data) } }
            while !Task.isCancelled {
                if buffer.changed {
                    buffer.changed = false
                    output = buffer.text
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            session.removeObserver(token)
        }
    }

    private func run() {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        session.run(cmd)
        history.removeAll { $0 == cmd }
        history.append(cmd)
        command = ""
    }

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

struct CommandItem: Identifiable {
    var id: String { command }
    let command: String
    let title: String

    init(_ pair: (String, String)) {
        command = pair.0
        title = pair.1
    }
}

/// Follows a log file (its last 400 kB).
struct LogFileView: View {
    let url: URL
    var extra: URL?
    @State var text = ""
    @Environment(\.revealFile) var revealFile

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(text.isEmpty ? "No output yet." : text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(white: 0.85))
                    .textSelectionEnabled()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(white: 0.08))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Footnote(url.path)
                Spacer()
                Button("Show File") { revealFile?(url) }
            }
            .padding(6)
        }
        .task(id: url) {
            while !Task.isCancelled {
                let t = Self.read(url, extra: extra)
                if t != text { text = t }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
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
