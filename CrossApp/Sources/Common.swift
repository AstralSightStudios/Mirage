import Foundation
import MirageKit
import SwiftCrossUI

/// A titled group of rows on a tinted background.
struct InspectorSection<Content: View>: View {
    var title: String?
    var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title).font(.subheadline).emphasized().foregroundColor(.gray)
            }
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.adaptive(light: Color(white: 0.93), dark: Color(white: 0.17)))
            .cornerRadius(10)
        }
        .padding(.top, 8)
    }
}

/// Label on the left, value (selectable, so it can be copied) on the right.
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .foregroundColor(.gray)
                .lineLimit(1)
                .textSelectionEnabled()
        }
    }
}

/// A caption under a control.
struct Footnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundColor(.gray)
    }
}

/// A row of buttons acting as a segmented control.
struct TabBar<Tab: Hashable & RawRepresentable>: View where Tab.RawValue == String {
    let tabs: [Tab]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.self) { tab in
                if tab == selection {
                    Button(tab.rawValue) {}.emphasized()
                } else {
                    Button(tab.rawValue) { selection = tab }
                }
            }
        }
    }
}

extension AppModel {
    func shellText(_ s: DeviceSession.ShellStatus, device: VirtualDevice) -> String {
        switch s {
        case .disabled: return device.options.shell ? "Starts at boot" : "Off"
        case .injecting: return "Starting…"
        case .ready(let pid): return "NSH (task \(pid))"
        case .failed(let m): return "Failed: \(m)"
        case .unavailable: return "Unavailable"
        }
    }
}
