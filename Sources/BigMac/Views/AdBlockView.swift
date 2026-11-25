import SwiftUI

/// Ad Blocking: BigMac's Safari content blocker, pop-up blocker and YouTube ad skipper, and the optional system-wide hosts list.
struct AdBlockView: View {
    @Environment(AdBlockModel.self) private var model
    @State private var newSite = ""
    @State private var siteRejected = false
    @State private var confirmSystemWide: Bool?

    var body: some View {
        PaneView(title: "Ad Blocking", status: status, busy: model.hostsBusy) {
            Button { model.openSafariSettings(RuleStore.contentBlockerIdentifier) } label: {
                ActionLabel("Safari Settings", symbol: "safari")
            }
            .buttonStyle(.ghost).disabled(!model.linkedToSafari)
        } content: {
            CardColumn {
                if let message = model.message {
                    Callout(symbol: "exclamationmark.triangle", text: message, actionTitle: "Dismiss") { model.message = nil }
                }
                overview
                safari
                categories
                allowed
                systemWide
                credits
            }
        }
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The extensions are switched on in Safari, so re-read their state on coming back.
            Task { await model.refresh() }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmSystemWide != nil }, set: { if !$0 { confirmSystemWide = nil } })) {
            if let on = confirmSystemWide {
                Button(on ? "Turn On" : "Turn Off") { Task { await model.setSystemWide(on) } }
            }
        } message: {
            Text("BigMac edits only its own section of /etc/hosts. macOS will ask for your password.")
        }
    }

    private var status: String {
        var parts: [String] = []
        switch model.blockerEnabled {
        case true?: parts.append("Safari blocking on")
        case false?: parts.append("Safari blocking off")
        case nil: break
        }
        if model.hosts.installed { parts.append("\(model.hosts.entries.formatted()) servers blocked system-wide") }
        return parts.joined(separator: " · ")
    }

    private var confirmTitle: String {
        confirmSystemWide == true ? "Block \(model.hostsAvailable.formatted()) ad and tracker servers in every app?" : "Turn off system-wide blocking?"
    }

    // MARK: Cards

    /// The headline numbers, like the top of a stats card.
    private var overview: some View {
        Card("Summary") {
            HStack(spacing: 28) {
                BigStat("Safari", model.blockerEnabled == true ? "On" : "Off", model.blockerEnabled == true ? Theme.green : Theme.tertiary)
                BigStat("Rules", model.ruleCount.formatted(), Palette.user)
                BigStat("Allowed sites", "\(model.settings.allowedDomains.count)", Theme.text)
                BigStat("System-wide", model.hosts.installed ? model.hosts.entries.formatted() : "Off",
                        model.hosts.installed ? Palette.ssd : Theme.tertiary)
                Spacer(minLength: 0)
            }
        }
    }

    private var safari: some View {
        Card("Safari", symbol: "safari") {
            CardRows {
                extensionRow(title: "Ad and tracker blocker",
                             detail: "\(model.ruleCount.formatted()) rules. Blocks requests and hides ad slots in Safari.",
                             enabled: model.blockerEnabled, identifier: RuleStore.contentBlockerIdentifier)
                extensionRow(title: "Pop-up blocker",
                             detail: popupBlockerDetail,
                             enabled: model.popupBlockerEnabled, identifier: RuleStore.popupBlockerExtensionIdentifier)
                extensionRow(title: "YouTube ad skipper",
                             detail: "Skips video ads on youtube.com. Allow it on youtube.com when Safari asks.",
                             enabled: model.youTubeEnabled, identifier: RuleStore.youTubeExtensionIdentifier)
            }
            if !model.linkedToSafari {
                Note("Open BigMac.app (not a development build) to use the Safari extensions.")
            } else if model.blockerEnabled != true || model.youTubeEnabled != true || model.popupBlockerEnabled != true {
                Note("Safari extensions are switched on in Safari: Settings > Extensions, then tick BigMac's. The pop-up blocker asks to read and change pages on every site: it needs that to see which clicks you made.")
            }
        }
    }

    private var popupBlockerDetail: String {
        var text = "Stops tabs, windows and pop-unders a site opens without your click, and invisible full-page links. Optional: allow it on all websites when Safari asks."
        if model.blockedPopups > 0 { text += " \(model.blockedPopups.formatted()) blocked so far." }
        return text
    }

    private func extensionRow(title: String, detail: String, enabled: Bool?, identifier: String) -> some View {
        SettingRow(title: title, detail: detail) {
            switch enabled {
            case true?: Pill(text: "On", tint: Theme.green)
            case false?: Pill(text: "Off", tint: Theme.tertiary)
            case nil: EmptyView()
            }
            Button(enabled == true ? "Settings…" : "Turn On in Safari…") { model.openSafariSettings(identifier) }
                .buttonStyle(.ghost).disabled(!model.linkedToSafari)
        }
    }

    private var categories: some View {
        Card("Block in Safari", symbol: "hand.raised") {
            CardRows {
                ForEach(BlockingCategory.allCases) { category in
                    SettingRow(title: category.title, detail: category.detail) {
                        Toggle("", isOn: Binding(get: { model.isOn(category) }, set: { model.set(category, on: $0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }
        }
    }

    private var allowed: some View {
        Card("Allowed Sites", symbol: "checkmark.shield", trailing: "\(model.settings.allowedDomains.count)") {
            CardRows {
                ForEach(model.settings.allowedDomains, id: \.self) { domain in
                    Row {
                        Text(domain)
                        Spacer()
                        Button { model.removeAllowed(domain) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Block on \(domain) again")
                    }
                }
            }
            HStack {
                TextField("Allow a site", text: $newSite, prompt: Text("example.com"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .onChange(of: newSite) { siteRejected = false }
                Button("Add", action: add).buttonStyle(.ghost).disabled(newSite.trimmed.isEmpty)
            }
            Note(siteRejected ? "That isn't a site name. Enter something like example.com."
                              : "Nothing is blocked on these sites. They're also left out of the system-wide list.",
                 color: siteRejected ? Theme.red : Theme.secondary)
        }
    }

    private func add() {
        if model.allow(newSite) { newSite = "" } else { siteRejected = true }
    }

    private var systemWide: some View {
        Card("System-Wide", symbol: "globe") {
            CardRows {
                SettingRow(title: "Block ads in every app", detail: systemWideDetail) {
                    if model.hostsBusy { ProgressView().controlSize(.small) }
                    if model.hosts.installed {
                        if !model.hostsUpToDate {
                            Button("Update…") { confirmSystemWide = true }.buttonStyle(.ghost).disabled(model.hostsBusy)
                        }
                        Button("Turn Off…") { confirmSystemWide = false }.buttonStyle(.ghost).disabled(model.hostsBusy)
                    } else {
                        Button("Turn On…") { confirmSystemWide = true }.buttonStyle(.ghost).disabled(model.hostsBusy || model.hosts.malformed)
                    }
                }
            }
            Note("Adds ad and tracker servers to /etc/hosts, so Chrome, Firefox and other apps can't reach them. It blocks whole servers only and can't hide page elements. Browsers that use their own secure DNS, and some VPNs, skip it.")
        }
    }

    private var systemWideDetail: String {
        if model.hosts.malformed { return "BigMac's section of /etc/hosts is damaged; fix it by hand first." }
        guard model.hosts.installed else { return "Off. \(model.hostsAvailable.formatted()) servers ready to block." }
        return model.hostsUpToDate
            ? "On: \(model.hosts.entries.formatted()) servers blocked."
            : "On: \(model.hosts.entries.formatted()) servers blocked. Your allowed sites changed since; update to apply them."
    }

    private var credits: some View {
        Card("Block Lists", symbol: "list.bullet.rectangle") {
            CardRows {
                ForEach(model.catalog.lists) { list in
                    SettingRow(title: list.title, detail: "\(list.ruleCount.formatted()) rules, version \(list.version)") {
                        Link(list.license, destination: URL(string: list.homepage) ?? URL(string: "https://easylist.to")!)
                    }
                }
                SettingRow(title: "StevenBlack hosts", detail: "System-wide list") {
                    Link("MIT", destination: URL(string: "https://github.com/StevenBlack/hosts")!)
                }
            }
        }
    }
}

/// Title and grey detail on the left, controls on the right, as in a settings list.
struct SettingRow<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Row {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) { trailing }
        }
    }
}

/// Explanatory grey text at the bottom of a card.
struct Note: View {
    let text: String
    var color: Color = Theme.secondary
    init(_ text: String, color: Color = Theme.secondary) { (self.text, self.color) = (text, color) }

    var body: some View {
        Text(text).font(Theme.small).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}
