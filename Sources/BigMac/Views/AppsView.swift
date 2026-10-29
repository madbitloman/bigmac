import SwiftUI

struct AppsView: View {
    @Environment(AppsModel.self) private var model
    @Environment(JevSettings.self) private var jev
    @State private var pending: AppInfo?
    @State private var includeLeftovers = false  // containers/app support can hold real user data

    var body: some View {
        @Bindable var model = model
        PaneView(title: "Applications", status: model.status, busy: model.scanning) {
            FilterChip(title: "Unused", isOn: $model.onlyUnused)
            Picker("", selection: $model.unusedDays) {
                ForEach([30, 90, 180, 365], id: \.self) { Text("\($0)+ days").tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            Button { Task { await model.askJev(jev.client!) } } label: { ActionLabel("Ask Jev", symbol: "brain") }
                .buttonStyle(.ghost).disabled(jev.client == nil || model.apps.isEmpty)
                .help("Ask Jev which apps look like drivers or security tools other things depend on")
            Button { Task { await model.scan() } } label: { ActionLabel("Scan", key: "⌘R") }
                .buttonStyle(.primary).keyboardShortcut("r").disabled(model.scanning)
        } content: {
            if model.apps.isEmpty && !model.scanning {
                EmptyState(symbol: "square.grid.2x2", title: "No apps scanned",
                           message: "Lists apps in /Applications and ~/Applications with Spotlight last-used dates and leftover support files.") {
                    Button { Task { await model.scan() } } label: { ActionLabel("Scan", key: "⌘R") }.buttonStyle(.primary)
                }
            } else {
                Scroller {
                    Group {
                        ForEach(model.visible) { app in
                            Row {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 26, height: 26)
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
                                    Text(app.size.bytes).font(Theme.mono)
                                    if app.leftoverSize > 0 { Text("+\(app.leftoverSize.bytes)").monoSecondary() }
                                }
                                .frame(width: 80, alignment: .trailing)
                                Button { pending = app } label: { ActionLabel("Uninstall") }
                                    .buttonStyle(.ghost).disabled(!app.removable)
                            }
                            .contextMenu { Button("Reveal in Finder") { revealInFinder(app.url) } }
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
                    Button { pending = nil } label: { ActionLabel("Cancel") }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
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
            .background(Theme.raised)
        }
    }

    private func lastUsed(_ app: AppInfo) -> String {
        guard let date = app.lastUsed else { return "Last used unknown" }
        return "Used " + date.formatted(.relative(presentation: .named))
    }
}
