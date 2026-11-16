import SwiftUI

/// The card language shared by the main window and the menu bar panel: rounded tiles with a bold title,
/// rings and bars, coloured dot legends, and a grey label over each value.

enum CardStyle { case window, panel }

private struct CardStyleKey: EnvironmentKey { static let defaultValue = CardStyle.window }
extension EnvironmentValues {
    /// `.panel` in the menu bar popover: translucent tiles over its material, slightly tighter.
    var cardStyle: CardStyle {
        get { self[CardStyleKey.self] }
        set { self[CardStyleKey.self] = newValue }
    }
}

/// Chart colours: magenta CPU, orange RAM, teal SSD; the memory split follows Activity Monitor's.
enum Palette {
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
    /// Category colours for split bars (Clean, Overview), in order.
    static let series: [Color] = [user, ram, cpu, ssd, system, free,
                                  Color(light: 0x6E6AD8, dark: 0x8E8AF0), Color(light: 0xA07A50, dark: 0xC49A6C),
                                  Color(light: 0x8A8A8E, dark: 0x98989D)]
}

/// A titled tile. `trailing` is grey text at the right of the title; `accessory` holds small header actions.
struct Card<Accessory: View, Content: View>: View {
    @Environment(\.cardStyle) private var style
    let title: String?
    var symbol: String?
    var trailing: String?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(_ title: String?, symbol: String? = nil, trailing: String? = nil,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        let panel = style == .panel
        VStack(alignment: .leading, spacing: panel ? 10 : 14) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.secondary) }
                    Text(title).font(.system(size: panel ? 16 : 19, weight: .bold)).foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    if let trailing { Text(trailing).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1) }
                    accessory
                }
            }
            content
        }
        .padding(panel ? 14 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            if panel {
                // Translucent over the menu bar window's own material, like Control Center.
                shape.fill(.quaternary.opacity(0.55))
            } else {
                shape.fill(Theme.card).overlay(shape.strokeBorder(Theme.border.opacity(0.7)))
            }
        }
    }
}

extension Card where Accessory == EmptyView {
    init(_ title: String?, symbol: String? = nil, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, symbol: symbol, trailing: trailing, accessory: { EmptyView() }, content: content)
    }
}

/// Rows inside a card: no separators, with the selection highlight reaching slightly past the text.
struct CardRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }.padding(.horizontal, -10)
    }
}

/// Concentric usage ring.
struct Ring: View {
    let value: Double
    let color: Color
    let diameter: CGFloat
    var width: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(Theme.border, lineWidth: width)
            Circle().trim(from: 0, to: max(0.005, min(value, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: value)
        }
        .frame(width: diameter - width, height: diameter - width)
    }
}

/// Grey label over a large coloured number.
struct BigStat: View {
    let label: String, value: String, color: Color
    init(_ label: String, _ value: String, _ color: Color) { (self.label, self.value, self.color) = (label, value, color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(color).monospacedDigit()
                .lineLimit(1).fixedSize()
        }
        .frame(minWidth: 70, alignment: .leading)
    }
}

/// A count that filters what's below when clicked: dot and label over a large number.
struct StatTile: View {
    let label: String
    let count: Int
    let color: Color
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Circle().fill(count > 0 ? color : Theme.tertiary).frame(width: 8, height: 8)
                    Text(label).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Text("\(count)").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(count > 0 ? color : Theme.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minWidth: 84, alignment: .leading)
            .background(isOn ? color.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(isOn ? color.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0 && !isOn)
        .help(isOn ? "Show everything again" : "Show only \(label.lowercased())")
    }
}

/// Grey label over a plain value, for facts rather than measurements.
struct Fact: View {
    let label: String, value: String
    init(_ label: String, _ value: String) { (self.label, self.value) = (label, value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text).monospacedDigit().lineLimit(1)
        }
    }
}

/// Coloured dot, label and value; `stacked` puts the value under the label.
struct Legend: View {
    let color: Color, label: String, value: String
    var stacked = false
    init(_ color: Color, _ label: String, _ value: String, stacked: Bool = false) {
        (self.color, self.label, self.value, self.stacked) = (color, label, value, stacked)
    }

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) { dot; Text(label).font(.system(size: 13)).foregroundStyle(Theme.secondary) }
                Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).monospacedDigit().padding(.leading, 14)
            }
            .lineLimit(1)
        } else {
            HStack(spacing: 5) {
                dot
                Text(label).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).monospacedDigit()
            }
            .lineLimit(1)
        }
    }

    private var dot: some View { Circle().fill(color).frame(width: 9, height: 9) }
}

/// Horizontal bar split into coloured parts; the rest of `total` stays as the track.
struct StackedBar: View {
    let parts: [(Double, Color)]
    let total: Double
    var height: CGFloat = 14

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
        .frame(height: height)
    }
}

/// Recent CPU load as thin bars, newest on the right.
struct CPUBars: View {
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

/// Columns of legends/facts that wrap evenly, like the memory legend.
struct LegendGrid<Content: View>: View {
    var columns = 3
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns), alignment: .leading, spacing: 10) {
            content
        }
    }
}

/// "Show all 240" under a capped list.
struct ShowMore: View {
    let hidden: Int
    let action: () -> Void

    var body: some View {
        Button("Show \(hidden) more", action: action)
            .buttonStyle(.link).font(.system(size: 13)).padding(.top, 6)
    }
}

enum Format {
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    static func uptime(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f.string(from: t) ?? ""
    }

    static func memory(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) }
}
