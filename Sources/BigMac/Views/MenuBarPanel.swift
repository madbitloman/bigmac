import SwiftUI

/// Menu bar popover: a glanceable Mac summary on cards, then BigMac's one-click scans.
/// System readings refresh every 2 s only while the popover is open; scans still run only when a button is pressed.
struct MenuBarPanel: View {
    @Environment(JunkModel.self) private var junk
    @Environment(DuplicatesModel.self) private var duplicates
    @Environment(NetworkModel.self) private var network
    @Environment(AuditModel.self) private var audit
    @Environment(SystemStats.self) private var stats
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 10) {
            header
            SummaryCard()
            MemoryCard()
            DiskCard()
            actionsCard
            footer
        }
        .padding(12)
        .frame(width: 400)
        .environment(\.cardStyle, .panel)
        .onAppear { stats.start() }
        .onDisappear { stats.stop() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            LogoBadge(size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(stats.chip.isEmpty ? stats.model : stats.chip).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Text("\(stats.model) · up \(Format.uptime(stats.uptime))").font(Font.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button { openMain() } label: { ActionLabel("Open", key: "⌘O") }
                .buttonStyle(.ghost).keyboardShortcut("o")
        }
        .padding(.horizontal, 4)
    }

    // MARK: BigMac

    private var actionsCard: some View {
        Card(nil) {
            VStack(spacing: 2) {
                row("Security", "shield.lefthalf.filled", auditSummary, busy: audit.busy, action: "Run") { Task { await audit.run() } }
                row("Clean", "sparkles", junkSummary, busy: junk.busy, action: "Scan") { Task { await junk.scan() } }
                row("Network", "point.3.connected.trianglepath.dotted", networkSummary, busy: network.mode == .snapshot,
                    action: network.running ? "Stop" : "Snapshot") {
                    if network.running { network.stop() } else { Task { await network.refresh() } }
                }
                row("Duplicates", "square.on.square",
                    duplicates.groups.isEmpty ? ("Not scanned", Theme.tertiary) : ("\(duplicates.wasted.bytes) reclaimable", Theme.secondary),
                    busy: duplicates.busy, action: "Scan") { Task { await duplicates.scan() } }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Scans run only when you ask").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain).font(Font.system(size: 13)).foregroundStyle(Theme.secondary).keyboardShortcut("q")
        }
        .padding(.horizontal, 4)
    }

    private var auditSummary: (String, Color) {
        guard !audit.report.observations.isEmpty else { return ("Not run yet", Theme.tertiary) }
        let levels = audit.report.observations.map(audit.severity)
        let high = levels.filter { $0 == .high }.count, medium = levels.filter { $0 == .medium }.count
        if high > 0 { return ("\(high) high · \(medium) medium", Theme.red) }
        if medium > 0 { return ("\(medium) medium", Theme.orange) }
        return ("Nothing suspicious", Theme.green)
    }

    private var junkSummary: (String, Color) {
        junk.results.isEmpty ? ("Not scanned", Theme.tertiary) : ("\(junk.allItems.reduce(0) { $0 + $1.size }.bytes) found", Theme.secondary)
    }

    private var networkSummary: (String, Color) {
        guard !network.rows.isEmpty else { return (network.running ? "Watching…" : "No reading", Theme.tertiary) }
        let flagged = network.rows.filter { $0.level >= .medium }.count
        return ("\(network.rows.count) connections · \(flagged) flagged\(network.running ? " · live" : "")",
                flagged > 0 ? Theme.orange : Theme.secondary)
    }

    private func row(_ title: String, _ symbol: String, _ summary: (String, Color), busy: Bool,
                     action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(summary.1 == Theme.tertiary ? Theme.secondary : summary.1)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                Text(summary.0).font(Font.system(size: 13)).foregroundStyle(summary.1).lineLimit(1)
            }
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) } else { Button(action: perform) { ActionLabel(action) }.buttonStyle(.ghost) }
        }
        .frame(height: 50)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openMain() }
    }

    private func openMain() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Menu bar glyph; shows a count when the last audit found high-severity items.
struct MenuBarLabel: View {
    @Environment(AuditModel.self) private var audit

    var body: some View {
        let high = audit.report.observations.filter { audit.severity($0) == .high }.count
        HStack(spacing: 3) {
            Image(nsImage: Logo.menuBarImage)
            if high > 0 { Text("\(high)") }
        }
    }
}
