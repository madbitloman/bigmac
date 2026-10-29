import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case clean = "Clean"
    case duplicates = "Duplicates"
    case apps = "Apps"
    case network = "Network"
    case audit = "Security"
    case settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .clean: "sparkles"
        case .duplicates: "square.on.square"
        case .apps: "square.grid.2x2"
        case .network: "point.3.connected.trianglepath.dotted"
        case .audit: "shield.lefthalf.filled"
        case .settings: "gearshape"
        }
    }
    var key: KeyEquivalent { KeyEquivalent(Character("\((Pane.allCases.firstIndex(of: self) ?? 0) + 1)")) }
}

struct ContentView: View {
    @State private var pane: Pane

    init(initial: Pane = .clean) { _pane = State(initialValue: initial) }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(pane: $pane)
            Rectangle().fill(Theme.border).frame(width: 1)
            switch pane {
            case .clean: CleanView()
            case .duplicates: DuplicatesView()
            case .apps: AppsView()
            case .network: NetworkView()
            case .audit: AuditView()
            case .settings: JevSettingsView()
            }
        }
        .background(Theme.canvas)
        .ignoresSafeArea()
        .tint(Theme.accent)
    }
}

private struct Sidebar: View {
    @Binding var pane: Pane
    @Environment(JunkModel.self) private var junk
    @Environment(DuplicatesModel.self) private var duplicates
    @Environment(AppsModel.self) private var apps
    @Environment(NetworkModel.self) private var network
    @Environment(AuditModel.self) private var audit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                LogoBadge(size: 20)
                Text("BigMac").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 10).padding(.top, 44).padding(.bottom, 14)

            ForEach(Pane.allCases.filter { $0 != .settings }) { item($0) }
            Spacer()
            item(.settings)
            Text("v0.1 · runs locally, on demand").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 12)
        }
        .padding(.horizontal, 8)
        .frame(width: 216)
        .background(Theme.sidebar)
    }

    private func item(_ p: Pane) -> some View {
        SidebarItem(pane: p, selected: pane == p, trailing: trailing(p)) { pane = p }
            .keyboardShortcut(p.key, modifiers: .command)
    }

    /// Live counters, like Linear's issue counts.
    private func trailing(_ p: Pane) -> (String, Color)? {
        switch p {
        case .clean where !junk.results.isEmpty:
            return (junk.allItems.reduce(0) { $0 + $1.size }.bytes, Theme.tertiary)
        case .duplicates where !duplicates.groups.isEmpty:
            return (duplicates.wasted.bytes, Theme.tertiary)
        case .apps where !apps.apps.isEmpty:
            return ("\(apps.apps.filter { $0.isUnused(days: apps.unusedDays) }.count) unused", Theme.tertiary)
        case .network where network.running:
            return ("live", Theme.green)
        case .audit where !audit.report.observations.isEmpty:
            let high = audit.report.observations.filter { audit.severity($0) == .high }.count
            return high > 0 ? ("\(high) high", Theme.red) : ("clear", Theme.green)
        default:
            return nil
        }
    }
}

private struct SidebarItem: View {
    let pane: Pane
    let selected: Bool
    let trailing: (String, Color)?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: pane.symbol).font(.system(size: 12.5)).frame(width: 16)
                    .foregroundStyle(selected ? Theme.text : Theme.secondary)
                Text(pane.rawValue).font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.secondary)
                Spacer()
                if let (text, tint) = trailing {
                    Text(text).font(.system(size: 11)).monospacedDigit().foregroundStyle(tint)
                } else if hovering {
                    Text("⌘\(String(pane.key.character))").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(selected ? Theme.selected : hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
