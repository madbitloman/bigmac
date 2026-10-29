import AppKit
import SwiftUI

/// Linear-style tokens: near-black surfaces, hairline borders, one indigo accent, muted status colours.
enum Theme {
    static let canvas = Color(light: 0xFCFCFD, dark: 0x101113)
    static let sidebar = Color(light: 0xF4F4F6, dark: 0x0B0B0D)
    static let raised = Color(light: 0xFFFFFF, dark: 0x17181B)
    static let hover = Color(light: 0x000000, dark: 0xFFFFFF, alpha: 0.045)
    static let selected = Color(light: 0x000000, dark: 0xFFFFFF, alpha: 0.075)
    static let border = Color(light: 0x000000, dark: 0xFFFFFF, alpha: 0.08)
    static let text = Color(light: 0x16171A, dark: 0xE8E9EC)
    static let secondary = Color(light: 0x6B6F76, dark: 0x8A8F98)
    static let tertiary = Color(light: 0x9EA2A9, dark: 0x5A5E66)
    static let accent = Color(light: 0x5E6AD2, dark: 0x6E79D6)

    static let red = Color(light: 0xD9443F, dark: 0xEB5757)
    static let orange = Color(light: 0xD9822B, dark: 0xF2994A)
    static let yellow = Color(light: 0xB8930E, dark: 0xE2B93B)
    static let green = Color(light: 0x2F9E6A, dark: 0x4CB782)
    static let blue = Color(light: 0x3B82C4, dark: 0x5E9FE0)

    static let body = Font.system(size: 13)
    static let small = Font.system(size: 11.5)
    static let label = Font.system(size: 11, weight: .medium)
    static let mono = Font.system(size: 11.5, design: .monospaced)
    static let title = Font.system(size: 14, weight: .semibold)

    static func risk(_ level: RiskLevel) -> Color {
        switch level {
        case .none: green
        case .low: yellow
        case .medium: orange
        case .high: red
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32, alpha: Double = 1) {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light) })
    }
}

// MARK: Buttons

struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body)
            .foregroundStyle(enabled ? Theme.text : Theme.tertiary)
            .padding(.horizontal, 9).frame(height: 26)
            .background(configuration.isPressed ? Theme.selected : hovering && enabled ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint = Theme.accent
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.5))
            .padding(.horizontal, 11).frame(height: 26)
            .background(tint.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == GhostButtonStyle { static var ghost: GhostButtonStyle { .init() } }
extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { .init() }
    static var danger: PrimaryButtonStyle { .init(tint: Theme.red) }
}

/// Button label with an optional trailing key hint, e.g. "Scan  ⌘R".
struct ActionLabel: View {
    let title: String
    var symbol: String?
    var key: String?

    init(_ title: String, symbol: String? = nil, key: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.key = key
    }

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)) }
            Text(title)
            if let key { Text(key).font(.system(size: 11)).opacity(0.55) }
        }
    }
}

// MARK: Small parts

/// Status pill with a coloured dot, Linear-issue style.
struct Pill: View {
    let text: String
    var tint: Color = Theme.secondary
    var dot = true

    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(tint).frame(width: 6, height: 6) }
            Text(text).font(Theme.label).foregroundStyle(dot ? Theme.secondary : tint)
        }
        .padding(.horizontal, 7).frame(height: 20)
        .overlay(Capsule().strokeBorder(Theme.border))
        .fixedSize()
    }
}

struct CheckBox: View {
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        Button { isOn.toggle() } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(isOn ? Theme.accent : .clear)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isOn ? Theme.accent : Theme.tertiary, lineWidth: 1))
                .overlay { if isOn { Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white) } }
                .frame(width: 14, height: 14)
                .opacity(disabled ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// Segmented-looking toggle chip for filters.
struct FilterChip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark" : "line.3.horizontal.decrease").font(.system(size: 9.5, weight: .semibold))
                Text(title)
            }
            .font(Theme.small)
            .foregroundStyle(isOn ? Theme.text : Theme.secondary)
            .padding(.horizontal, 8).frame(height: 24)
            .background(isOn ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
        }
        .buttonStyle(.plain)
    }
}

/// Clickable count in a summary strip; the selected ones filter the list below.
struct StatToggle: View {
    let label: String
    let count: Int
    let tint: Color
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(count > 0 ? tint : Theme.tertiary.opacity(0.5)).frame(width: 6, height: 6)
                Text("\(count)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(count > 0 ? Theme.text : Theme.tertiary)
                Text(label).font(Theme.small).foregroundStyle(isOn ? Theme.text : Theme.secondary)
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(isOn ? Theme.selected : hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isOn ? tint.opacity(0.55) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0 && !isOn)
        .onHover { hovering = $0 }
        .fixedSize()
    }
}

/// Strip of StatToggles with a Clear link, shared by Security and Network.
struct FilterStrip<Content: View>: View {
    let active: Bool
    let trailing: String
    let clear: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) {
            content
            if active {
                Button("Clear", action: clear).buttonStyle(.plain).font(Theme.small).foregroundStyle(Theme.accent).padding(.leading, 6)
            }
            Spacer(minLength: 8)
            Text(trailing).font(Theme.small).foregroundStyle(Theme.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 12).frame(height: 40)
    }
}

struct StripDivider: View {
    var body: some View { Rectangle().fill(Theme.border).frame(width: 1, height: 14).padding(.horizontal, 6) }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.border).frame(height: 1) }
}

/// Indeterminate 1px progress line under the top bar.
struct ProgressLine: View {
    let active: Bool
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            Rectangle().fill(
                LinearGradient(colors: [.clear, Theme.accent, .clear], startPoint: .leading, endPoint: .trailing)
            )
            .frame(width: geo.size.width * 0.3)
            .offset(x: geo.size.width * phase)
            .opacity(active ? 1 : 0)
        }
        .frame(height: 1)
        .clipped()
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

// MARK: Layout

private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// ImageRenderer can't draw scroll views, so headless snapshots lay lists out flat.
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// Scrolling list body with pinned section headers.
struct Scroller<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        if snapshot {
            Color.clear.overlay(alignment: .top) { VStack(spacing: 0) { content }.fixedSize(horizontal: false, vertical: true) }.clipped()
        } else {
            ScrollView { LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) { content } }
        }
    }
}

/// Pane chrome: 52pt top bar (title · status · actions), progress line, optional callout, content.
struct PaneView<Actions: View, Content: View>: View {
    let title: String
    let status: String
    var busy = false
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(Theme.title).foregroundStyle(Theme.text).fixedSize()
                // The status gives way first so buttons never truncate; full text on hover.
                Text(status).font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
                    .layoutPriority(-1).help(status)
                Spacer(minLength: 12)
                HStack(spacing: 6) { actions }.fixedSize()
            }
            .padding(.horizontal, 18).frame(height: 52)
            ZStack(alignment: .top) {
                Hairline()
                ProgressLine(active: busy)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
    }
}

/// Grouped list section: small caps header with trailing info, hairline-separated rows.
struct ListGroup<Header: View, Rows: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) { header }
                .font(Theme.label).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 18).frame(height: 32)
                .background(Theme.canvas)
            rows
        }
    }
}

/// One list row: hover highlight and a hairline below.
struct Row<Content: View>: View {
    var selected = false
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) { content }
                .font(Theme.body).foregroundStyle(Theme.text)
                .padding(.horizontal, 18).padding(.vertical, 7)
                .frame(minHeight: 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Theme.selected : hovering ? Theme.hover : .clear)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
            Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 18).opacity(0.6)
        }
    }
}

struct EmptyState<Action: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Theme.tertiary)
                .frame(width: 56, height: 56)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
            Text(title).font(Theme.title).foregroundStyle(Theme.text).padding(.top, 4)
            Text(message).font(Theme.small).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
            action.padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Action == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// Inline notice strip (Full Disk Access, action results).
struct Callout: View {
    let symbol: String
    let text: String
    var tint: Color = Theme.orange
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint)
            Text(text).font(Theme.small).foregroundStyle(Theme.secondary).textSelection(.enabled)
            Spacer()
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.ghost) }
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(tint.opacity(0.06))
        .overlay(alignment: .bottom) { Hairline() }
    }
}

struct FDACallout: View {
    var body: some View {
        Callout(symbol: "lock", text: "Some folders couldn't be read. Grant Full Disk Access for a complete scan.",
                actionTitle: "Open Settings") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        }
    }
}

extension View {
    func monoSecondary() -> some View { font(Theme.mono).foregroundStyle(Theme.secondary) }
}

func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}
