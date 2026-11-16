import SwiftUI

/// Live Mac readings, shared by the menu bar panel and the Overview pane. Whoever shows them starts and stops
/// `SystemStats`; these cards only read it.

struct SummaryCard: View {
    @Environment(SystemStats.self) private var stats

    var body: some View {
        Card("Summary") {
            HStack(spacing: 22) {
                ZStack {
                    Ring(value: stats.cpu, color: Palette.cpu, diameter: 124)
                    Ring(value: stats.memory.pressure, color: Palette.ram, diameter: 96)
                    Ring(value: stats.disk.fraction, color: Palette.ssd, diameter: 68)
                }
                .frame(width: 124, height: 124)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 18) {
                        BigStat("CPU", Format.percent(stats.cpu), Palette.cpu)
                        BigStat("RAM", Format.percent(stats.memory.pressure), Palette.ram)
                    }
                    HStack(spacing: 18) {
                        BigStat("SSD", Format.percent(stats.disk.fraction), Palette.ssd)
                        BigStat("Cores", "\(stats.cores)", Theme.text)
                    }
                }
                Spacer(minLength: 0)
            }
            CPUBars(history: stats.cpuHistory)
                .frame(height: 44)
            HStack(spacing: 14) {
                Legend(Palette.user, "User", Format.percent(stats.cpuUser))
                Legend(Palette.system, "System", Format.percent(stats.cpuSystem))
            }
        }
    }
}

struct MemoryCard: View {
    @Environment(SystemStats.self) private var stats

    var body: some View {
        let m = stats.memory
        let parts: [(String, UInt64, Color)] = [
            ("Wired", m.wired, Palette.wired), ("App", m.used, Palette.app), ("Compressed", m.compressed, Palette.compressed),
            ("Cached", m.cache, Palette.cache), ("Free", m.free, Palette.free),
        ]
        Card("Memory", trailing: Format.memory(m.total)) {
            StackedBar(parts: parts.map { (Double($0.1), $0.2) }, total: Double(m.total))
            LegendGrid {
                ForEach(parts, id: \.0) { Legend($0.2, $0.0, Format.memory($0.1), stacked: true) }
            }
        }
    }
}

struct DiskCard: View {
    @Environment(SystemStats.self) private var stats
    @Environment(JunkModel.self) private var junk
    @Environment(DuplicatesModel.self) private var duplicates

    var body: some View {
        let d = stats.disk
        let cleanable = junk.allItems.reduce(0) { $0 + $1.size } + duplicates.wasted
        Card("Macintosh HD", trailing: "\(d.available.bytes) free of \(d.total.bytes)") {
            // Used space, with the part BigMac found reclaimable shown in green at its end.
            StackedBar(parts: [(Double(max(0, d.used - cleanable)), Palette.ssd), (Double(min(cleanable, d.used)), Palette.free)],
                       total: Double(d.total))
            HStack(spacing: 14) {
                Legend(Palette.ssd, "Used", d.used.bytes)
                Legend(Palette.free, "BigMac can free", cleanable > 0 ? cleanable.bytes : "scan to see")
            }
        }
    }
}
