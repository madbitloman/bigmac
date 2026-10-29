import SwiftUI

/// Menu bar popover: last results plus one-click scans. Nothing runs until a button is pressed.
struct MenuBarPanel: View {
    @Environment(JunkModel.self) private var junk
    @Environment(DuplicatesModel.self) private var duplicates
    @Environment(NetworkModel.self) private var network
    @Environment(AuditModel.self) private var audit
    @Environment(JevSettings.self) private var jev
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                LogoBadge(size: 18)
                Text("BigMac").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button { openMain() } label: { ActionLabel("Open", key: "⌘O") }
                    .buttonStyle(.ghost).keyboardShortcut("o")
            }
            .padding(.horizontal, 12).frame(height: 44)
            Hairline()

            item("Security Audit", "shield.lefthalf.filled", auditSummary, busy: audit.scanning || audit.triaging, action: "Run") {
                Task { await audit.run() }
            }
            item("Smart Clean", "sparkles", junkSummary, busy: junk.scanning, action: "Scan") {
                Task { await junk.scan() }
            }
            item("Network", "point.3.connected.trianglepath.dotted", networkSummary, busy: false,
                 action: network.running ? "Stop" : "Snapshot") {
                if network.running { network.stop() } else { Task { await network.refresh() } }
            }
            item("Duplicates", "square.on.square", duplicates.groups.isEmpty ? ("Not scanned", Theme.tertiary) : ("\(duplicates.wasted.bytes) reclaimable", Theme.secondary),
                 busy: duplicates.scanning, action: "Scan") {
                Task { await duplicates.scan() }
            }

            Hairline()
            HStack {
                Text("Runs only when you ask").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(Theme.small).foregroundStyle(Theme.secondary).keyboardShortcut("q")
            }
            .padding(.horizontal, 12).frame(height: 34)
        }
        .frame(width: 320)
        .background(Theme.canvas)
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

    private func item(_ title: String, _ symbol: String, _ summary: (String, Color), busy: Bool,
                      action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.body).foregroundStyle(Theme.text)
                Text(summary.0).font(Theme.small).foregroundStyle(summary.1).lineLimit(1)
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button(action: perform) { ActionLabel(action) }.buttonStyle(.ghost)
            }
        }
        .padding(.horizontal, 12).frame(height: 50)
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
