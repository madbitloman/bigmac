import SwiftUI

struct CleanView: View {
    @Environment(JunkModel.self) private var model
    @Environment(JevSettings.self) private var jev
    @State private var confirm = false
    @State private var collapsed: Set<JunkCategory> = []
    @State private var showAll: Set<JunkCategory> = []
    private let pageSize = 50

    var body: some View {
        PaneView(title: "Smart Clean", status: model.status, busy: model.scanning) {
            Button { Task { await model.askJev(jev.client!) } } label: { ActionLabel("Ask Jev", symbol: "brain") }
                .buttonStyle(.ghost)
                .disabled(jev.client == nil || model.allItems.isEmpty || model.scanning)
                .help("Sends item paths to TypeSafe Jev to judge which are safe to delete")
            Button { model.selectRecommended() } label: { ActionLabel("Select safe") }
                .buttonStyle(.ghost).disabled(model.allItems.isEmpty)
            Button { Task { await model.scan() } } label: { ActionLabel("Scan", key: "⌘R") }
                .buttonStyle(.ghost).keyboardShortcut("r").disabled(model.scanning)
            Button { confirm = true } label: { ActionLabel(model.selected.isEmpty ? "Trash" : "Trash \(model.selectedBytes.bytes)", symbol: "trash") }
                .buttonStyle(.primary).disabled(model.selected.isEmpty)
        } content: {
            VStack(spacing: 0) {
                if model.anyDenied { FDACallout() }
                if model.results.isEmpty && !model.scanning {
                    EmptyState(symbol: "sparkles", title: "Nothing scanned yet",
                               message: "Caches, logs, developer junk, Docker, Trash, screenshots, orphaned app data, local databases, old downloads and large files.") {
                        Button { Task { await model.scan() } } label: { ActionLabel("Scan", key: "⌘R") }.buttonStyle(.primary)
                    }
                } else {
                    Scroller {
                        Group {
                            ForEach(JunkCategory.allCases) { category in
                                if let result = model.results[category], !result.items.isEmpty || result.note != nil {
                                    Section { if !collapsed.contains(category) { rows(category, result) } } header: { header(category, result) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Move \(model.selected.count) items (\(model.selectedBytes.bytes)) to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { Task { await model.trashSelected() } }
        } message: {
            Text(model.selected.contains(where: FS.isInTrash)
                 ? "Items already in the Trash are deleted permanently. Everything else goes to the Trash and can be restored."
                 : "Items go to the Trash, so you can restore them until you empty it.")
        }
    }

    private func header(_ category: JunkCategory, _ result: CategoryResult) -> some View {
        ListGroup {
            Button {
                if collapsed.contains(category) { collapsed.remove(category) } else { collapsed.insert(category) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(collapsed.contains(category) ? 0 : 90))
                    Image(systemName: category.symbol).font(.system(size: 11))
                    Text(category.title).foregroundStyle(Theme.text)
                    Text("\(result.items.count)").foregroundStyle(Theme.tertiary)
                }
            }
            .buttonStyle(.plain)
            if let note = result.note { Text(note).foregroundStyle(Theme.tertiary).lineLimit(1) }
            Spacer()
            Text(result.total.bytes).monospacedDigit()
            if !result.items.isEmpty {
                Button(allSelected(result) ? "Deselect" : "Select all") { toggleAll(result) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
        } rows: { EmptyView() }
    }

    @ViewBuilder
    private func rows(_ category: JunkCategory, _ result: CategoryResult) -> some View {
        if result.items.isEmpty {
            Row { Text("Nothing to clean").foregroundStyle(Theme.tertiary) }
        }
        let shown = showAll.contains(category) ? result.items : Array(result.items.prefix(pageSize))
        ForEach(shown) { item in
            Row(selected: model.selected.contains(item.url)) {
                CheckBox(isOn: Binding(
                    get: { model.selected.contains(item.url) },
                    set: { on in if on { model.selected.insert(item.url) } else { model.selected.remove(item.url) } }
                ), disabled: item.blocked != nil)
                .help(item.blocked ?? "")
                VStack(alignment: .leading, spacing: 2) {
                    if item.docker == nil {
                        HStack(spacing: 8) {
                            Text(item.url.lastPathComponent).lineLimit(1)
                            Text(FS.tildePath(item.url.deletingLastPathComponent())).monoSecondary().lineLimit(1).truncationMode(.middle)
                        }
                    } else {
                        Text(item.displayPath).lineLimit(1).truncationMode(.middle)
                    }
                    if let detail = item.detail {
                        Text(detail).font(Theme.small).foregroundStyle(item.blocked != nil ? Theme.orange : Theme.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if item.needsReview { Pill(text: "review", tint: Theme.blue) }
                if item.blocked != nil { Pill(text: "in use", tint: Theme.orange) }
                if let v = model.jev[item.url] {
                    v.value >= 0.5
                        ? Pill(text: "safe \(Int(v.value * 100))%", tint: Theme.green)
                        : Pill(text: "keep \(Int((1 - v.value) * 100))%", tint: Theme.red)
                }
                Text(item.size.bytes).monoSecondary().frame(width: 72, alignment: .trailing)
            }
            .contextMenu { if item.docker == nil { Button("Reveal in Finder") { revealInFinder(item.url) } } }
        }
        if result.items.count > shown.count {
            Row {
                Button("Show all \(result.items.count)") { showAll.insert(category) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                Text("\(result.items.count - shown.count) more · Select all still covers every item").font(Theme.small).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func allSelected(_ r: CategoryResult) -> Bool { r.items.allSatisfy { $0.blocked != nil || model.selected.contains($0.url) } }

    private func toggleAll(_ r: CategoryResult) {
        let urls = Set(r.items.filter { $0.blocked == nil }.map(\.url))
        if allSelected(r) { model.selected.subtract(urls) } else { model.selected.formUnion(urls) }
    }
}
