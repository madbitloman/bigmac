import AppKit
import SwiftUI

/// Colours and type: system label, separator and accent colours, so BigMac follows the Mac's appearance and
/// contrast settings, on a quiet canvas with raised cards. Sizes stay at or above the earlier ones.
enum Theme {
    /// Window background behind the cards.
    static let canvas = Color(light: 0xF0F0F2, dark: 0x252527)
    /// Card fill: white in light mode, a step above the canvas in dark.
    static let card = Color(light: 0xFFFFFF, dark: 0x303033)
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

    static let body = Font.system(size: 14)
    static let small = Font.system(size: 13)
    static let label = Font.system(size: 12, weight: .medium)
    static let mono = Font.system(size: 13, design: .monospaced)
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

// MARK: Buttons

/// Secondary action: a standard bordered push button.
struct GhostButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(.bordered)
    }
}

/// The pane's main action: the accent-coloured default button.
struct PrimaryButtonStyle: PrimitiveButtonStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
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

struct Hairline: View {
    var body: some View { Divider() }
}

// MARK: Layout

/// Pane chrome: a large bold title with the pane's status under it and its actions on the right, then the
/// pane's content on the canvas. There is no toolbar; the strip above the title stays free for dragging the window.
struct PaneView<Actions: View, Content: View>: View {
    let title: String
    let status: String
    var busy = false
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text)
                    Text(status.isEmpty ? " " : status).font(.system(size: 14)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 16)
                if busy { ProgressView().controlSize(.small) }
                HStack(spacing: 8) { actions }
            }
            .padding(.horizontal, Theme.gutter).padding(.top, 6).padding(.bottom, 18)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas.ignoresSafeArea())
        .navigationTitle(title)
    }
}

extension Theme {
    /// Space between the window edge and the cards.
    static let gutter: CGFloat = 28
}

/// The pane's scrolling column of cards. Lazy, so long panes only build the cards on screen.
struct CardColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) { content }
                .padding(.horizontal, Theme.gutter).padding(.bottom, Theme.gutter)
        }
    }
}

/// One row in a card's list. No separators; the selection is a soft rounded highlight.
struct Row<Content: View>: View {
    var selected = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .font(Theme.body).foregroundStyle(Theme.text)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minHeight: 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// The system's empty-state view, on a card.
struct EmptyState<Action: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        Card(nil) {
            ContentUnavailableView {
                Label(title, systemImage: symbol)
            } description: {
                Text(message).frame(maxWidth: 440)
            } actions: {
                action.controlSize(.large)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }
}

extension EmptyState where Action == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// Inline notice (Full Disk Access, action results): a tinted rounded box.
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
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
