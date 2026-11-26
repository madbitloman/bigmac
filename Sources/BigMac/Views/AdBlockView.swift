import SwiftUI

/// Ad & Pop-up Blocking: one switch and one set of categories for BigMac's blocking in Safari, the allowed sites,
/// the browsers (Safari's two extensions, and the extension for Chrome and Firefox), and the optional system-wide hosts list.
struct AdBlockView: View {
    @Environment(AdBlockModel.self) private var model
    @State private var newSite = ""
    @State private var siteRejected = false
    @State private var confirmSystemWide: Bool?

    var body: some View {
        PaneView(title: "Ad & Pop-up Blocking", status: status, busy: model.hostsBusy) {
            Toggle("Blocking", isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.large)
                .help(model.isEnabled ? "Turn off BigMac's blocking in Safari" : "Turn on BigMac's blocking in Safari")
        } content: {
            CardColumn {
                if let message = model.message {
                    Callout(symbol: "exclamationmark.triangle", text: message, actionTitle: "Dismiss") { model.message = nil }
                }
                if model.showLayoutNotice {
                    Callout(symbol: "puzzlepiece.extension", text: "BigMac's pop-up blocker and YouTube ad skipper are now one Safari extension, BigMac Pop-up and YouTube Blocker. Check that it's on in Safari's Extensions settings; the separate YouTube Ad Skipper is gone.",
                            tint: Theme.blue, actionTitle: "OK") { model.dismissLayoutNotice() }
                }
                overview
                categories
                allowed
                SectionHeader("Browsers")
                safari
                BrowserExtensionCard()
                SectionHeader("Advanced")
                systemWide
                credits
            }
        }
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Extensions are switched on in Safari, and its toolbar page can change the allowed sites, so re-read on coming back.
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
        if !model.isEnabled {
            parts.append("Off")
        } else if model.linkedToSafari {
            parts.append(model.safariBlocking ? "On in Safari" : "Not switched on in Safari yet")
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
                BigStat("Safari", safariValue.text, safariValue.color)
                BigStat("Rules", model.isEnabled ? model.ruleCount.formatted() : "0", Palette.user)
                BigStat("Pop-ups stopped", model.blockedPopups.formatted(), Theme.text)
                BigStat("Allowed sites", "\(model.settings.allowedDomains.count)", Theme.text)
                Spacer(minLength: 0)
            }
            if !model.isEnabled {
                Note("Blocking is off: Safari loads every ad, tracker and pop-up until you switch it back on (top right). Your choices below are kept.")
            }
        }
    }

    private var safariValue: (text: String, color: Color) {
        if !model.isEnabled { return ("Off", Theme.tertiary) }
        switch (model.blockerEnabled, model.webExtensionEnabled) {
        case (true?, true?): return ("On", Theme.green)
        case (true?, _), (_, true?): return ("Partly", Theme.orange)
        default: return ("Off", Theme.tertiary)
        }
    }

    private var categories: some View {
        Card("What to Block", symbol: "hand.raised") {
            CardRows {
                ForEach(Self.categoryOrder) { category in
                    SettingRow(title: category.title, detail: detail(for: category)) {
                        Toggle("", isOn: Binding(get: { model.isOn(category) }, set: { model.set(category, on: $0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }
            .disabled(!model.isEnabled)
            .opacity(model.isEnabled ? 1 : 0.55)
            Note("For Safari. The extension for Chrome and Firefox has its own switches under its toolbar button.")
        }
    }

    private static let categoryOrder: [BlockingCategory] = [.ads, .trackers, .popups, .strictPopups, .annoyances, .social, .youtube]

    private func detail(for category: BlockingCategory) -> String {
        if category == .youtube, !model.youTubeSkipperBundled, model.linkedToSafari {
            return category.detail + ". Not included in this copy of BigMac."
        }
        return category.detail
    }

    private var safari: some View {
        Card("Safari", symbol: "safari", accessory: {
            Button { model.openSafariExtensions() } label: { ActionLabel("Open Safari Extensions Settings", symbol: "gearshape") }
                .buttonStyle(.ghost).disabled(!model.linkedToSafari)
        }) {
            CardRows {
                extensionRow(title: "BigMac Ad Blocker",
                             detail: "Ads, trackers, pop-up networks and cookie notices. \(model.ruleCount.formatted()) rules. It never sees your pages.",
                             enabled: model.blockerEnabled)
                extensionRow(title: "BigMac Pop-up and YouTube Blocker",
                             detail: "Stops tabs and windows a site opens without your click, and skips YouTube ads. Its toolbar button can always allow pop-ups on a site.",
                             enabled: model.webExtensionEnabled)
            }
            if !model.linkedToSafari {
                Note("Open BigMac.app (not a development build) to use the Safari extensions.")
            } else if model.blockerEnabled != true || model.webExtensionEnabled != true {
                Note("Switch both on in Safari: Settings > Extensions. The pop-up and YouTube blocker asks to read and change pages on every site: it needs that to see which clicks you made. It sends nothing anywhere.")
            }
        }
    }

    private func extensionRow(title: String, detail: String, enabled: Bool?) -> some View {
        SettingRow(title: title, detail: detail) {
            switch enabled {
            case true?: Pill(text: "On", tint: Theme.green)
            case false?: Pill(text: "Off in Safari", tint: Theme.tertiary)
            case nil: EmptyView()
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
        Card("System-Wide", symbol: "globe", trailing: "Needs your password") {
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

/// A small heading between groups of cards.
struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
            .textCase(.uppercase).padding(.top, 10).padding(.leading, 4)
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
