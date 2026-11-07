import SwiftUI

/// Menu bar popover in the iStatistica spirit: a glanceable Mac summary on cards, then BigMac's one-click scans.
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
            summaryCard
            memoryCard
            diskCard
            actionsCard
            footer
        }
        .padding(12)
        .frame(width: 340)
        .background(Theme.canvas)
        .onAppear { stats.start() }
        .onDisappear { stats.stop() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            LogoBadge(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(stats.chip.isEmpty ? stats.model : stats.chip).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text("\(stats.model) · up \(Self.uptime(stats.uptime))").font(Theme.small).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button { openMain() } label: { ActionLabel("Open", key: "⌘O") }
                .buttonStyle(.ghost).keyboardShortcut("o")
        }
        .padding(.horizontal, 4)
    }

    // MARK: Summary

    private var summaryCard: some View {
        Card("Summary") {
            HStack(spacing: 18) {
                ZStack {
                    Ring(value: stats.cpu, color: Palette.cpu, diameter: 92)
                    Ring(value: stats.memory.pressure, color: Palette.ram, diameter: 70)
                    Ring(value: stats.disk.fraction, color: Palette.ssd, diameter: 48)
                }
                .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 18) {
                        BigStat("CPU", Self.percent(stats.cpu), Palette.cpu)
                        BigStat("RAM", Self.percent(stats.memory.pressure), Palette.ram)
                    }
                    HStack(spacing: 18) {
                        BigStat("SSD", Self.percent(stats.disk.fraction), Palette.ssd)
                        BigStat("Cores", "\(stats.cores)", Theme.text)
                    }
                }
                Spacer(minLength: 0)
            }
            CPUBars(history: stats.cpuHistory)
                .frame(height: 30)
            HStack(spacing: 14) {
                Legend(Palette.user, "User", Self.percent(stats.cpuUser))
                Legend(Palette.system, "System", Self.percent(stats.cpuSystem))
            }
        }
    }

    // MARK: Memory

    private var memoryCard: some View {
        let m = stats.memory
        let parts: [(String, UInt64, Color)] = [
            ("Wired", m.wired, Palette.wired), ("App", m.used, Palette.app), ("Compressed", m.compressed, Palette.compressed),
            ("Cached", m.cache, Palette.cache), ("Free", m.free, Palette.free),
        ]
        return Card("Memory", trailing: ByteCountFormatter.string(fromByteCount: Int64(m.total), countStyle: .memory)) {
            StackedBar(parts: parts.map { (Double($0.1), $0.2) }, total: Double(m.total))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
                ForEach(parts, id: \.0) { Legend($0.2, $0.0, ByteCountFormatter.string(fromByteCount: Int64($0.1), countStyle: .memory), stacked: true) }
            }
        }
    }

    // MARK: Disk

    private var diskCard: some View {
        let d = stats.disk
        let cleanable = junk.allItems.reduce(0) { $0 + $1.size } + duplicates.wasted
        return Card("Macintosh HD", trailing: "\(d.available.bytes) free of \(d.total.bytes)") {
            // Used space, with the part BigMac found reclaimable shown in green at its end.
            StackedBar(parts: [(Double(max(0, d.used - cleanable)), Palette.ssd), (Double(min(cleanable, d.used)), Palette.free)],
                       total: Double(d.total))
            HStack(spacing: 14) {
                Legend(Palette.ssd, "Used", d.used.bytes)
                Legend(Palette.free, "BigMac can free", cleanable > 0 ? cleanable.bytes : "scan to see")
            }
        }
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
            Text("Scans run only when you ask").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain).font(Theme.small).foregroundStyle(Theme.secondary).keyboardShortcut("q")
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
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(summary.1 == Theme.tertiary ? Theme.secondary : summary.1)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.body).foregroundStyle(Theme.text)
                Text(summary.0).font(Theme.small).foregroundStyle(summary.1).lineLimit(1)
            }
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) } else { Button(action: perform) { ActionLabel(action) }.buttonStyle(.ghost) }
        }
        .frame(height: 40)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openMain() }
    }

    private func openMain() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    static func uptime(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f.string(from: t) ?? ""
    }
}

/// iStatistica-like colours: magenta CPU, orange RAM, teal SSD; the memory split matches Activity Monitor's.
private enum Palette {
    static let cpu = Color(light: 0xB43FC0, dark: 0xD45FD8)
    static let ram = Color(light: 0xD98A1F, dark: 0xF0AE48)
    static let ssd = Color(light: 0x2BA597, dark: 0x5ED8C7)
    static let user = Color(light: 0x2F7FE0, dark: 0x3E8EF7)
    static let system = Color(light: 0xD9443F, dark: 0xE46B5A)
    static let wired = system
    static let app = ram
    static let compressed = cpu
    static let cache = user
    static let free = Color(light: 0x2F9E4A, dark: 0x5BC55A)
}

private struct Card<Content: View>: View {
    let title: String?
    var trailing: String? = nil
    @ViewBuilder let content: Content

    init(_ title: String?, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                    Spacer()
                    if let trailing { Text(trailing).font(Theme.small).foregroundStyle(Theme.secondary) }
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

private struct Ring: View {
    let value: Double
    let color: Color
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Theme.border, lineWidth: 8)
            Circle().trim(from: 0, to: max(0.005, min(value, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: value)
        }
        .frame(width: diameter - 8, height: diameter - 8)
    }
}

private struct BigStat: View {
    let label: String, value: String, color: Color
    init(_ label: String, _ value: String, _ color: Color) { (self.label, self.value, self.color) = (label, value, color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(Theme.small).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(color).monospacedDigit()
        }
        .frame(minWidth: 56, alignment: .leading)
    }
}

/// Coloured dot, label and value; `stacked` puts the value under the label, as in iStatistica's memory legend.
private struct Legend: View {
    let color: Color, label: String, value: String
    var stacked = false
    init(_ color: Color, _ label: String, _ value: String, stacked: Bool = false) {
        (self.color, self.label, self.value, self.stacked) = (color, label, value, stacked)
    }

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) { dot; Text(label).font(Theme.small).foregroundStyle(Theme.secondary) }
                Text(value).font(Theme.small.weight(.medium)).foregroundStyle(Theme.text).monospacedDigit().padding(.leading, 12)
            }
            .lineLimit(1)
        } else {
            HStack(spacing: 5) {
                dot
                Text(label).font(Theme.small).foregroundStyle(Theme.secondary)
                Text(value).font(Theme.small.weight(.medium)).foregroundStyle(Theme.text).monospacedDigit()
            }
            .lineLimit(1)
        }
    }

    private var dot: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

/// Horizontal bar split into coloured parts; the rest of `total` stays as the track.
private struct StackedBar: View {
    let parts: [(Double, Color)]
    let total: Double

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(part.1).frame(width: total > 0 ? geo.size.width * part.0 / total : 0)
                }
                Spacer(minLength: 0)
            }
            .background(Theme.border)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 10)
    }
}

/// Recent CPU load as thin bars, newest on the right.
private struct CPUBars: View {
    let history: [Double]

    var body: some View {
        GeometryReader { geo in
            let slots = SystemStats.historyLength
            let width = geo.size.width / CGFloat(slots)
            HStack(alignment: .bottom, spacing: 0) {
                Spacer(minLength: 0)
                ForEach(Array(history.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 1).fill(Palette.user)
                        .frame(width: max(1, width - 2), height: max(1, geo.size.height * min(v, 1)))
                        .frame(width: width)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
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
