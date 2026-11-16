import SwiftUI

struct NetworkView: View {
    @Environment(NetworkModel.self) private var model
    @Environment(JevSettings.self) private var jev
    @State private var killTarget: ConnectionRow?
    @State private var onlyFlagged = false
    @State private var levels: Set<RiskLevel> = []
    @State private var onlyTrusted = false
    @State private var showAll = false
    private let pageSize = 100

    private var rows: [ConnectionRow] {
        if onlyTrusted { return model.rows.filter(\.trusted) }
        if !levels.isEmpty { return model.rows.filter { levels.contains($0.level) } }
        return onlyFlagged ? model.rows.filter { $0.level >= .medium || (model.jev[$0.jevKey]?.value ?? 0) >= 0.5 } : model.rows
    }

    /// Counts per risk level; click one to show only those.
    private var summary: some View {
        let count = { (l: RiskLevel) in model.rows.filter { $0.level == l }.count }
        let trusted = model.rows.filter(\.trusted).count
        let filtering = !levels.isEmpty || onlyTrusted
        return Card("Connections", trailing: "\(model.rows.count) open · \(Set(model.rows.map(\.connection.pid)).count) processes") {
            if filtering { Button("Show all") { levels = []; onlyTrusted = false }.buttonStyle(.link) }
        } content: {
            HStack(spacing: 6) {
                ForEach([RiskLevel.high, .medium, .low, .none], id: \.self) { l in
                    StatTile(label: l.label, count: count(l), color: Theme.risk(l), isOn: levels.contains(l)) {
                        onlyTrusted = false
                        if levels.contains(l) { levels.remove(l) } else { levels.insert(l) }
                    }
                }
                if trusted > 0 {
                    Divider().frame(height: 40).padding(.horizontal, 6)
                    StatTile(label: "Trusted", count: trusted, color: Theme.secondary, isOn: onlyTrusted) {
                        levels = []; onlyTrusted.toggle()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, -10)
        }
    }

    /// Some binaries are named after their version (Claude Code installs as `…/claude/versions/2.1.312`).
    private func displayName(_ row: ConnectionRow) -> String {
        let cmd = row.connection.command
        guard cmd.first?.isNumber == true, cmd.allSatisfy({ $0.isNumber || $0 == "." }), let path = row.exePath else { return cmd }
        let generic: Set = ["versions", "version", "bin", "MacOS", "Contents", "current", "latest"]
        let app = URL(filePath: path).deletingLastPathComponent().pathComponents.reversed().first { !generic.contains($0) }
        return app.map { "\($0) \(cmd)" } ?? cmd
    }

    var body: some View {
        @Bindable var model = model
        PaneView(title: "Network", status: model.status, busy: model.busy) {
            FilterChip(title: "Flagged", isOn: $onlyFlagged).disabled(!levels.isEmpty || onlyTrusted)
            FilterChip(title: "Auto-Jev", isOn: $model.autoJev).disabled(jev.client == nil)
                .help("Judge each new (binary, remote) pair with Jev. Results are cached, so polling doesn't re-bill.")
            Button { Task { await model.askJev(jev.client!) } } label: { ActionLabel("Ask Jev", symbol: "brain") }
                .buttonStyle(.ghost).disabled(jev.client == nil || model.rows.isEmpty)
            Button { Task { await model.refresh() } } label: { ActionLabel("Snapshot", key: "⌘R") }
                .buttonStyle(.ghost).keyboardShortcut("r").disabled(model.busy)
            Button { model.running ? model.stop() : model.start(jev: jev) } label: {
                ActionLabel(model.running ? "Stop" : "Watch", symbol: model.running ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.primary)
        } content: {
            CardColumn {
                if model.rows.isEmpty {
                    EmptyState(symbol: "point.3.connected.trianglepath.dotted", title: "No reading yet",
                               message: "Snapshot lists your processes' open connections once. Watch re-reads them every \(Int(model.interval)) s until you stop it. Risk comes from code signature, binary location and port.") {
                        Button { Task { await model.refresh() } } label: { ActionLabel("Snapshot", key: "⌘R") }.buttonStyle(.primary)
                    }
                } else {
                    summary
                    let shown = showAll ? rows : Array(rows.prefix(pageSize))
                    Card(nil) {
                        CardRows {
                            HStack(spacing: 10) {
                                Text("Risk").frame(width: 116, alignment: .leading)
                                Text("Process")
                                Spacer()
                                Text("Remote").frame(width: 190, alignment: .leading)
                                Text("Signer").frame(width: 150, alignment: .leading)
                            }
                            .font(Theme.small).foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 10).padding(.bottom, 4)
                            if rows.isEmpty {
                                Text("Nothing matches these filters.").font(Theme.small).foregroundStyle(Theme.secondary).padding(10)
                            }
                            ForEach(shown) { row($0) }
                            if rows.count > shown.count {
                                ShowMore(hidden: rows.count - shown.count) { showAll = true }.padding(.horizontal, 10)
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Send SIGTERM to \(killTarget?.connection.command ?? "") (pid \(killTarget?.connection.pid ?? 0))?",
                            isPresented: Binding(get: { killTarget != nil }, set: { if !$0 { killTarget = nil } })) {
            Button("Quit process", role: .destructive) { if let t = killTarget { model.kill(t) }; killTarget = nil }
        }
    }

    private func row(_ row: ConnectionRow) -> some View {
        Row {
            HStack(spacing: 4) {
                Pill(text: row.level.label, tint: Theme.risk(row.level))
                if model.isNew(row) { Pill(text: "new", tint: Theme.accent, dot: false) }
            }
            .frame(width: 116, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayName(row)).fontWeight(.medium).lineLimit(1)
                    Text(verbatim: String(row.connection.pid)).monoSecondary().fixedSize()
                    if row.count > 1 { Text(verbatim: "×\(row.count)").monoSecondary().fixedSize().help("\(row.count) sockets to this remote") }
                    if row.trusted { Pill(text: "trusted", tint: Theme.tertiary, dot: false) }
                    if let v = model.jev[row.jevKey] {
                        Pill(text: "Jev \(Int(v.value * 100))%", tint: v.value >= 0.66 ? Theme.red : v.value >= 0.33 ? Theme.orange : Theme.green)
                    }
                }
                Text(row.signals.isEmpty ? (row.exePath.map { FS.tildePath(URL(filePath: $0)) } ?? "?") : row.signals.map(\.rawValue).joined(separator: " · "))
                    .font(Theme.small).foregroundStyle(row.signals.isEmpty ? Theme.tertiary : Theme.orange)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Text("\(row.connection.remoteHost):\(row.connection.remotePort.map(String.init) ?? "–")")
                .font(Theme.mono).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                .frame(width: 190, alignment: .leading)
                .textSelection(.enabled)
            Text(row.signer.label).font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(1)
                .frame(width: 150, alignment: .leading)
        }
        .contextMenu {
            if let path = row.exePath { Button("Reveal binary in Finder") { revealInFinder(URL(filePath: path)) } }
            Button("Copy remote address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.connection.remote, forType: .string)
            }
            if row.exePath != nil {
                Button(row.trusted ? "Stop trusting this binary" : "Trust this binary (false positive)") { model.setTrusted(row, !row.trusted) }
            }
            Divider()
            Button("Quit process \(row.connection.command)…", role: .destructive) { killTarget = row }
        }
    }
}
