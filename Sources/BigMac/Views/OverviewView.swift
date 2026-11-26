import AppKit
import SwiftUI

/// The first pane: this Mac at a glance (live CPU, memory and disk), then where each of BigMac's tools stands,
/// with its one-click action. Readings update every 2 s only while this pane is on screen.
struct OverviewView: View {
    @Environment(SystemStats.self) private var stats
    @Environment(JunkModel.self) private var junk
    @Environment(DuplicatesModel.self) private var duplicates
    @Environment(AppsModel.self) private var apps
    @Environment(NetworkModel.self) private var network
    @Environment(AuditModel.self) private var audit
    @Environment(AdBlockModel.self) private var adBlock
    let open: (Pane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        SummaryCard()
                        MemoryCard()
                        DiskCard()
                    }
                    VStack(spacing: 16) {
                        securityCard
                        cleanCard
                        duplicatesCard
                        appsCard
                        networkCard
                        adBlockCard
                    }
                }
                .padding(Theme.gutter)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas.ignoresSafeArea())
        .navigationTitle("Overview")
        .onAppear { stats.start() }
        .onDisappear { stats.stop() }
        .task { await adBlock.refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(nsImage: NSImage(named: NSImage.computerName) ?? NSImage()).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(stats.computerName).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("Uptime: \(Format.uptime(stats.uptime))").font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(stats.chip.isEmpty ? stats.model : stats.chip).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Text("\(stats.model) · \(stats.cores) cores · \(Format.memory(stats.memory.total))")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, Theme.gutter).padding(.top, 4).padding(.bottom, 20)
    }

    // MARK: BigMac's tools

    private var securityCard: some View {
        let levels = audit.report.observations.filter { !audit.isDismissed($0) }.map(audit.severity)
        let high = levels.filter { $0 == .high }.count, medium = levels.filter { $0 == .medium }.count
        let ran = !audit.report.observations.isEmpty
        return ToolCard(pane: .audit, open: open,
                        value: !ran ? "Not run" : high > 0 ? "\(high) high" : medium > 0 ? "\(medium) medium" : "All clear",
                        color: !ran ? Theme.tertiary : high > 0 ? Theme.red : medium > 0 ? Theme.orange : Theme.green,
                        detail: ran ? audit.status : "Persistence, unsigned processes, interception, remote access",
                        action: "Run audit", busy: audit.busy) { Task { await audit.run() } }
    }

    private var cleanCard: some View {
        let found = junk.allItems.reduce(0) { $0 + $1.size }
        return ToolCard(pane: .clean, open: open,
                        value: junk.results.isEmpty ? "Not scanned" : found.bytes,
                        color: junk.results.isEmpty ? Theme.tertiary : Palette.free,
                        detail: junk.results.isEmpty ? "Caches, logs, developer junk, Trash, old downloads" : junk.status,
                        action: "Scan", busy: junk.busy) { Task { await junk.scan() } }
    }

    private var duplicatesCard: some View {
        ToolCard(pane: .duplicates, open: open,
                 value: duplicates.groups.isEmpty ? "Not scanned" : duplicates.wasted.bytes,
                 color: duplicates.groups.isEmpty ? Theme.tertiary : Palette.free,
                 detail: duplicates.groups.isEmpty ? "Identical files, checked by full hash" : duplicates.status,
                 action: "Scan", busy: duplicates.busy || duplicates.roots.isEmpty) { Task { await duplicates.scan() } }
    }

    private var appsCard: some View {
        let unused = apps.apps.filter { $0.isUnused(days: apps.unusedDays) }.count
        return ToolCard(pane: .apps, open: open,
                        value: apps.apps.isEmpty ? "Not scanned" : "\(unused) unused",
                        color: apps.apps.isEmpty ? Theme.tertiary : unused > 0 ? Theme.orange : Theme.text,
                        detail: apps.apps.isEmpty ? "Last-used dates and leftover support files" : apps.status,
                        action: "Scan", busy: apps.busy) { Task { await apps.scan() } }
    }

    private var networkCard: some View {
        let flagged = network.rows.filter { $0.level >= .medium }.count
        return ToolCard(pane: .network, open: open,
                        value: network.rows.isEmpty ? "No reading" : "\(network.rows.count) open",
                        color: network.rows.isEmpty ? Theme.tertiary : flagged > 0 ? Theme.orange : Theme.text,
                        detail: network.rows.isEmpty ? "Open connections by process, with risk" : "\(flagged) flagged" + (network.running ? " · live" : ""),
                        action: "Snapshot", busy: network.busy) { Task { await network.refresh() } }
    }

    @ViewBuilder private var adBlockCard: some View {
        let on = adBlock.safariBlocking
        if !adBlock.included {
            ToolCard(pane: .adBlock, open: open, value: "Not included", color: Theme.tertiary,
                     detail: "Not part of this build", action: nil, busy: false) {}
        } else {
            ToolCard(pane: .adBlock, open: open,
                     value: on ? "On in Safari" : "Off in Safari",
                     color: on ? Theme.green : Theme.tertiary,
                     detail: adBlock.hosts.installed ? "\(adBlock.hosts.entries.formatted()) servers blocked system-wide"
                                                     : "\(adBlock.ruleCount.formatted()) rules ready",
                     action: nil, busy: false) {}
        }
    }
}

/// One tool on the Overview: its headline number, a grey line of detail, and its main action.
private struct ToolCard: View {
    let pane: Pane
    let open: (Pane) -> Void
    let value: String
    let color: Color
    let detail: String
    let action: String?
    let busy: Bool
    let perform: () -> Void

    var body: some View {
        Card(pane.rawValue, symbol: pane.symbol) {
            Button("Open") { open(pane) }.buttonStyle(.link)
        } content: {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(color)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    Text(detail).font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                if let action {
                    Button(action, action: perform).buttonStyle(.ghost).disabled(busy)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(pane) }
    }
}
