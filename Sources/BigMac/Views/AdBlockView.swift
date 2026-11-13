import SwiftUI

/// Ad Blocking: BigMac's Safari content blocker and YouTube ad skipper, and the optional system-wide hosts list.
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
            VStack(spacing: 0) {
                if let message = model.message {
                    Callout(symbol: "exclamationmark.triangle", text: message, actionTitle: "Dismiss") { model.message = nil }
                }
                Form {
                    safari
                    categories
                    allowed
                    systemWide
                    credits
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
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

    // MARK: Sections

    private var safari: some View {
        Section {
            extensionRow(title: "Ad and tracker blocker",
                         detail: "\(model.ruleCount.formatted()) rules. Blocks requests and hides ad slots in Safari.",
                         enabled: model.blockerEnabled, identifier: RuleStore.contentBlockerIdentifier)
            extensionRow(title: "YouTube ad skipper",
                         detail: "Skips video ads on youtube.com. Allow it on youtube.com when Safari asks.",
                         enabled: model.youTubeEnabled, identifier: RuleStore.youTubeExtensionIdentifier)
        } header: {
            Text("Safari")
        } footer: {
            if !model.linkedToSafari {
                Text("Open BigMac.app (not a development build) to use the Safari extensions.").formFooter()
            } else if model.blockerEnabled != true || model.youTubeEnabled != true {
                Text("Safari extensions are switched on in Safari: Settings > Extensions, then tick BigMac's.").formFooter()
            }
        }
    }

    private func extensionRow(title: String, detail: String, enabled: Bool?, identifier: String) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                switch enabled {
                case true?: Pill(text: "On", tint: Theme.green)
                case false?: Pill(text: "Off", tint: Theme.tertiary)
                case nil: EmptyView()
                }
                Button(enabled == true ? "Settings…" : "Turn On in Safari…") { model.openSafariSettings(identifier) }
                    .disabled(!model.linkedToSafari)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }

    private var categories: some View {
        Section {
            ForEach(BlockingCategory.allCases) { category in
                Toggle(isOn: Binding(get: { model.isOn(category) }, set: { model.set(category, on: $0) })) {
                    Text(category.title)
                    Text(category.detail)
                }
            }
        } header: {
            Text("Block in Safari")
        }
    }

    private var allowed: some View {
        Section {
            ForEach(model.settings.allowedDomains, id: \.self) { domain in
                LabeledContent(domain) {
                    Button { model.removeAllowed(domain) } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Block on \(domain) again")
                }
            }
            HStack {
                TextField("Allow a site", text: $newSite, prompt: Text("example.com"))
                    .onSubmit(add)
                    .onChange(of: newSite) { siteRejected = false }
                Button("Add", action: add).disabled(newSite.trimmed.isEmpty)
            }
        } header: {
            Text("Allowed Sites")
        } footer: {
            Text(siteRejected ? "That isn't a site name. Enter something like example.com."
                              : "Nothing is blocked on these sites. They're also left out of the system-wide list.")
                .formFooter(siteRejected ? Theme.red : Theme.secondary)
        }
    }

    private func add() {
        if model.allow(newSite) { newSite = "" } else { siteRejected = true }
    }

    private var systemWide: some View {
        Section {
            LabeledContent {
                HStack(spacing: 10) {
                    if model.hostsBusy { ProgressView().controlSize(.small) }
                    if model.hosts.installed {
                        if !model.hostsUpToDate {
                            Button("Update…") { confirmSystemWide = true }.disabled(model.hostsBusy)
                        }
                        Button("Turn Off…") { confirmSystemWide = false }.disabled(model.hostsBusy)
                    } else {
                        Button("Turn On…") { confirmSystemWide = true }.disabled(model.hostsBusy || model.hosts.malformed)
                    }
                }
            } label: {
                Text("Block ads in every app")
                Text(systemWideDetail)
            }
        } header: {
            Text("System-Wide")
        } footer: {
            Text("Adds ad and tracker servers to /etc/hosts, so Chrome, Firefox and other apps can't reach them. It blocks whole servers only and can't hide page elements. Browsers that use their own secure DNS, and some VPNs, skip it.")
                .formFooter()
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
        Section {
            ForEach(model.catalog.lists) { list in
                LabeledContent {
                    Link(list.license, destination: URL(string: list.homepage) ?? URL(string: "https://easylist.to")!)
                } label: {
                    Text(list.title)
                    Text("\(list.ruleCount.formatted()) rules, version \(list.version)")
                }
            }
            LabeledContent {
                Link("MIT", destination: URL(string: "https://github.com/StevenBlack/hosts")!)
            } label: {
                Text("StevenBlack hosts")
                Text("System-wide list")
            }
        } header: {
            Text("Block Lists")
        }
    }
}
