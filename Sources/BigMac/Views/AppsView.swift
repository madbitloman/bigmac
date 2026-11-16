import SwiftUI

struct AppsView: View {
    @Environment(AppsModel.self) private var model
    @Environment(JevSettings.self) private var jev
    @State private var pending: AppInfo?
    @State private var includeLeftovers = false  // containers/app support can hold real user data
    @State private var showAll = false
    private let pageSize = 80

    var body: some View {
        @Bindable var model = model
        PaneView(title: "Applications", status: model.status, busy: model.scanning) {
            FilterChip(title: "Unused", isOn: $model.onlyUnused)
            Picker("", selection: $model.unusedDays) {
                ForEach([30, 90, 180, 365], id: \.self) { Text("\($0)+ days").tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            Button { Task { await model.askJev(jev.client!) } } label: { ActionLabel("Ask Jev", symbol: "brain") }
                .buttonStyle(.ghost).disabled(jev.client == nil || model.apps.isEmpty || model.busy)
                .help("Ask Jev which apps look like drivers or security tools other things depend on")
            Button { Task { await model.scan() } } label: { ActionLabel("Scan", key: "⌘R") }
                .buttonStyle(.primary).keyboardShortcut("r").disabled(model.busy)
        } content: {
            CardColumn {
                if model.apps.isEmpty && !model.scanning {
                    EmptyState(symbol: "square.grid.2x2", title: "No apps scanned",
                               message: "Lists apps in /Applications and ~/Applications with Spotlight last-used dates and leftover support files.") {
                        Button { Task { await model.scan() } } label: { ActionLabel("Scan", key: "⌘R") }.buttonStyle(.primary)
                    }
                } else {
                    let unused = model.apps.filter { $0.isUnused(days: model.unusedDays) }
                    Card("Summary") {
                        HStack(spacing: 28) {
                            BigStat("Apps", "\(model.apps.count)", Theme.text)
                            BigStat("Unused \(model.unusedDays)+ days", "\(unused.count)", unused.isEmpty ? Theme.tertiary : Theme.orange)
                            BigStat("Unused size", unused.reduce(0) { $0 + $1.size + $1.leftoverSize }.bytes, Palette.free)
                            BigStat("Total size", model.apps.reduce(0) { $0 + $1.size }.bytes, Palette.ssd)
                            Spacer(minLength: 0)
                        }
                    }
                    let shown = showAll ? model.visible : Array(model.visible.prefix(pageSize))
                    Card(model.onlyUnused ? "Unused" : "Applications", trailing: "\(model.visible.count)") {
                        CardRows {
                            ForEach(shown) { app in
                                Row {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 28, height: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(app.name).fontWeight(.medium)
                                            if let v = app.version { Text(v).font(Theme.small).foregroundStyle(Theme.tertiary) }
                                        }
                                        Text(lastUsed(app)).font(Theme.small)
                                            .foregroundStyle(app.isUnused(days: model.unusedDays) ? Theme.orange : Theme.secondary)
                                    }
                                    Spacer(minLength: 12)
                                    if app.isApple { Pill(text: "Apple", tint: Theme.tertiary) }
                                    if let r = model.jevRisk[app.url], r.value >= 0.5 {
                                        Pill(text: "dependency \(Int(r.value * 100))%", tint: Theme.orange)
                                    }
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(app.size.bytes).monospacedDigit()
                                        if app.leftoverSize > 0 { Text("+\(app.leftoverSize.bytes)").font(Theme.small).foregroundStyle(Theme.secondary) }
                                    }
                                    .frame(width: 84, alignment: .trailing)
                                    Button { pending = app } label: { ActionLabel("Uninstall") }
                                        .buttonStyle(.ghost).disabled(!app.removable || model.busy)
                                }
                                .contextMenu { Button("Reveal in Finder") { revealInFinder(app.url) } }
                            }
                            if model.visible.count > shown.count {
                                ShowMore(hidden: model.visible.count - shown.count) { showAll = true }.padding(.horizontal, 10)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $pending) { app in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 32, height: 32)
                    Text("Uninstall \(app.name)?").font(Theme.title)
                }
                if let r = model.jevRisk[app.url], r.value >= 0.5 {
                    Callout(symbol: "exclamationmark.triangle",
                            text: "Jev thinks this may be a driver or dependency (\(Int(r.value * 100))%). Check before removing.")
                }
                Toggle("Also remove \(app.leftovers.count) support files (\(app.leftoverSize.bytes))", isOn: $includeLeftovers)
                    .toggleStyle(.checkbox).disabled(app.leftovers.isEmpty)
                ForEach(app.leftovers, id: \.self) { Text(FS.tildePath($0)).monoSecondary().lineLimit(1).truncationMode(.middle) }
                Text("Everything goes to the Trash and can be restored.").font(Theme.small).foregroundStyle(Theme.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { pending = nil }.keyboardShortcut(.cancelAction)
                    Button {
                        let target = app
                        pending = nil
                        Task { await model.uninstall(target, includeLeftovers: includeLeftovers) }
                    } label: { ActionLabel("Move to Trash") }
                    .buttonStyle(.danger).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 480)
        }
    }

    private func lastUsed(_ app: AppInfo) -> String {
        guard let date = app.lastUsed else { return "Last used unknown" }
        return "Used " + date.formatted(.relative(presentation: .named))
    }
}
