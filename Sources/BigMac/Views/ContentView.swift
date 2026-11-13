import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case clean = "Clean"
    case duplicates = "Duplicates"
    case apps = "Apps"
    case adBlock = "Ad Blocking"
    case network = "Network"
    case audit = "Security"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .clean: "sparkles"
        case .duplicates: "square.on.square"
        case .apps: "square.grid.2x2"
        case .adBlock: "hand.raised"
        case .network: "point.3.connected.trianglepath.dotted"
        case .audit: "shield.lefthalf.filled"
        }
    }
    var key: KeyEquivalent { KeyEquivalent(Character("\((Pane.allCases.firstIndex(of: self) ?? 0) + 1)")) }

    static let cleanup: [Pane] = [.clean, .duplicates, .apps]
    static let protection: [Pane] = [.adBlock, .network, .audit]
}

struct PaneFocusKey: FocusedValueKey { typealias Value = Binding<Pane?> }
extension FocusedValues {
    var pane: Binding<Pane?>? {
        get { self[PaneFocusKey.self] }
        set { self[PaneFocusKey.self] = newValue }
    }
}

/// Go menu: ⌘1…⌘6 switch panes, as in Finder's sidebar shortcuts.
struct PaneCommands: Commands {
    @FocusedValue(\.pane) private var pane

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(Pane.allCases) { p in
                Button(p.rawValue) { pane?.wrappedValue = p }
                    .keyboardShortcut(p.key, modifiers: .command)
                    .disabled(pane == nil)
            }
        }
    }
}

struct ContentView: View {
    @State private var pane: Pane?

    init(initial: Pane = .clean) { _pane = State(initialValue: initial) }

    var body: some View {
        NavigationSplitView {
            Sidebar(pane: $pane)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            switch pane ?? .clean {
            case .clean: CleanView()
            case .duplicates: DuplicatesView()
            case .apps: AppsView()
            case .adBlock: AdBlockView()
            case .network: NetworkView()
            case .audit: AuditView()
            }
        }
        .focusedSceneValue(\.pane, $pane)
    }
}

private struct Sidebar: View {
    @Binding var pane: Pane?
    @Environment(JunkModel.self) private var junk
    @Environment(DuplicatesModel.self) private var duplicates
    @Environment(AppsModel.self) private var apps
    @Environment(NetworkModel.self) private var network
    @Environment(AuditModel.self) private var audit
    @Environment(AdBlockModel.self) private var adBlock

    var body: some View {
        List(selection: $pane) {
            Section("Cleanup") { ForEach(Pane.cleanup) { item($0) } }
            Section("Protection") { ForEach(Pane.protection) { item($0) } }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                LogoBadge(size: 18)
                Text("Runs locally, on demand").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private func item(_ p: Pane) -> some View {
        Label(p.rawValue, systemImage: p.symbol)
            .font(.body)
            .badge(badge(p))
            .tag(p)
    }

    /// Live counters, shown as sidebar badges like Mail's unread counts.
    private func badge(_ p: Pane) -> Text? {
        switch p {
        case .clean where !junk.results.isEmpty:
            return Text(junk.allItems.reduce(0) { $0 + $1.size }.bytes)
        case .duplicates where !duplicates.groups.isEmpty:
            return Text(duplicates.wasted.bytes)
        case .apps where !apps.apps.isEmpty:
            return Text("\(apps.apps.filter { $0.isUnused(days: apps.unusedDays) }.count) unused")
        case .adBlock where adBlock.blockerEnabled == true || adBlock.hosts.installed:
            return Text("on").foregroundStyle(Theme.green)
        case .network where network.running:
            return Text("live").foregroundStyle(Theme.green)
        case .audit where !audit.report.observations.isEmpty:
            let high = audit.report.observations.filter { audit.severity($0) == .high }.count
            return high > 0 ? Text("\(high) high").foregroundStyle(Theme.red) : Text("clear").foregroundStyle(Theme.green)
        default:
            return nil
        }
    }
}
