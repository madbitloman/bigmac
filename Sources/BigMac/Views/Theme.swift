import AppKit
import SwiftUI

/// System colours and type, so BigMac follows the Mac's appearance, accent colour and contrast settings
/// the way Apple's own apps do. Sizes stay at or above the earlier custom ones.
enum Theme {
    static let canvas = Color(nsColor: .controlBackgroundColor)
    static let raised = Color(nsColor: .windowBackgroundColor)
    static let selected = Color.accentColor.opacity(0.12)
    static let border = Color(nsColor: .separatorColor)
    static let text = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let accent = Color.accentColor

    static let red = Color(nsColor: .systemRed)
    static let orange = Color(nsColor: .systemOrange)
    static let yellow = Color(nsColor: .systemYellow)
    static let green = Color(nsColor: .systemGreen)
    static let blue = Color(nsColor: .systemBlue)

    static let body = Font.body
    static let small = Font.callout
    static let label = Font.subheadline.weight(.medium)
    static let mono = Font.system(.callout, design: .monospaced)
    static let title = Font.title3.weight(.semibold)

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
    /// A fixed light/dark pair, for chart colours that have no system equivalent.
    init(light: UInt32, dark: UInt32, alpha: Double = 1) {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light) })
    }
}

private struct InToolbarKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Set on pane actions placed in the window toolbar, where buttons take the toolbar's own look.
    var inToolbar: Bool {
        get { self[InToolbarKey.self] }
        set { self[InToolbarKey.self] = newValue }
    }
}

// MARK: Buttons

/// Secondary action: a standard bordered push button, or a plain toolbar item in the toolbar.
struct GhostButtonStyle: PrimitiveButtonStyle {
    @Environment(\.inToolbar) private var inToolbar

    func makeBody(configuration: Configuration) -> some View {
        let button = Button(role: configuration.role, action: configuration.trigger) { configuration.label }
        if inToolbar { button.buttonStyle(.automatic) } else { button.buttonStyle(.bordered) }
    }
}

/// The pane's main action: the accent-coloured default button.
struct PrimaryButtonStyle: PrimitiveButtonStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) { configuration.label }
            .buttonStyle(.borderedProminent)
            .tint(tint)
    }
}

extension PrimitiveButtonStyle where Self == GhostButtonStyle { static var ghost: GhostButtonStyle { .init() } }
extension PrimitiveButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { .init() }
    static var danger: PrimaryButtonStyle { .init(tint: Theme.red) }
}

/// Button label: title with an optional SF Symbol. `key` is shown as a tooltip, the way macOS shows shortcuts.
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
        Group {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
        .help(key.map { "\(title) (\($0))" } ?? "")
    }
}

// MARK: Small parts

/// Status tag: a tinted capsule with an optional dot, like the tags in Mail and Reminders.
struct Pill: View {
    let text: String
    var tint: Color = Theme.secondary
    var dot = true

    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(tint).frame(width: 7, height: 7) }
            Text(text).font(Theme.label).foregroundStyle(dot ? Theme.text : tint)
        }
        .padding(.horizontal, 8).frame(height: 21)
        .background(tint.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

/// A standard macOS checkbox without a title.
struct CheckBox: View {
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        Toggle("", isOn: $isOn).toggleStyle(.checkbox).labelsHidden().disabled(disabled)
    }
}

/// On/off filter, drawn as a native toggle button.
struct FilterChip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn).toggleStyle(.button)
    }
}

/// Clickable count in the filter bar; the selected ones filter the list below.
struct StatToggle: View {
    let label: String
    let count: Int
    let tint: Color
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) {
            HStack(spacing: 6) {
                Circle().fill(count > 0 ? tint : Theme.tertiary).frame(width: 7, height: 7)
                Text("\(count)").fontWeight(.semibold).monospacedDigit()
                Text(label)
            }
        }
        .toggleStyle(.button)
        .disabled(count == 0 && !isOn)
        .fixedSize()
    }
}

/// Filter bar under the toolbar (like Finder's search scope bar), shared by Security and Network.
struct FilterStrip<Content: View>: View {
    let active: Bool
    let trailing: String
    let clear: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) {
            content
            if active { Button("Clear", action: clear).buttonStyle(.link).padding(.leading, 4) }
            Spacer(minLength: 8)
            Text(trailing).font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(.bar)
    }
}

struct StripDivider: View {
    var body: some View { Divider().frame(height: 16).padding(.horizontal, 4) }
}

struct Hairline: View {
    var body: some View { Divider() }
}

// MARK: Layout

/// Scrolling list body with pinned section headers.
struct Scroller<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView { LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) { content } }
    }
}

/// Pane chrome: the window title and subtitle come from the pane, its actions go in the window toolbar,
/// and a small spinner shows while it works.
struct PaneView<Actions: View, Content: View>: View {
    let title: String
    let status: String
    var busy = false
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
            .navigationTitle(title)
            .navigationSubtitle(status)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if busy { ProgressView().controlSize(.small) }
                    actions.environment(\.inToolbar, true).labelStyle(.titleAndIcon)
                }
            }
    }
}

/// Grouped list section: a pinned header on the bar material, then the rows.
struct ListGroup<Header: View, Rows: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) { header }
                .font(Theme.label).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 18).frame(height: 34)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            rows
        }
    }
}

/// One list row with an inset separator below, like a plain macOS table.
struct Row<Content: View>: View {
    var selected = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) { content }
                .font(Theme.body).foregroundStyle(Theme.text)
                .padding(.horizontal, 18).padding(.vertical, 8)
                .frame(minHeight: 38)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Theme.selected : .clear)
                .contentShape(Rectangle())
            Divider().padding(.leading, 18)
        }
    }
}

/// The system's empty-state view.
struct EmptyState<Action: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message).frame(maxWidth: 420)
        } actions: {
            action.controlSize(.large)
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
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(Theme.small).foregroundStyle(Theme.text).textSelection(.enabled)
            Spacer()
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.ghost) }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(tint.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
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

extension View {
    /// Explanatory text under a grouped form section, aligned with the rows above it.
    func formFooter(_ color: Color = Theme.secondary) -> some View {
        foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
    }
}
