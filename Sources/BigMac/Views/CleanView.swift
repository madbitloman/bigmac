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
                .disabled(jev.client == nil || model.allItems.isEmpty || model.busy)
                .help("Sends item paths to TypeSafe Jev to judge which are safe to delete")
            Button { model.selectRecommended() } label: { ActionLabel("Select safe") }
                .buttonStyle(.ghost).disabled(model.allItems.isEmpty)
            Button { Task { await model.scan() } } label: { ActionLabel("Scan", key: "⌘R") }
                .buttonStyle(.ghost).keyboardShortcut("r").disabled(model.busy)
            Button { confirm = true } label: { ActionLabel(model.selected.isEmpty ? "Trash" : "Trash \(model.selectedBytes.bytes)", symbol: "trash") }
                .buttonStyle(.primary).disabled(model.selected.isEmpty || model.busy)
        } content: {
            CardColumn {
                if model.anyDenied { FDACallout() }
                if model.results.isEmpty && !model.scanning {
                    EmptyState(symbol: "sparkles", title: "Nothing scanned yet",
                               message: "Caches, logs, developer junk, Docker, Trash, screenshots, orphaned app data, local databases, old downloads and large files.") {
                        Button { Task { await model.scan() } } label: { ActionLabel("Scan", key: "⌘R") }.buttonStyle(.primary)
                    }
                } else {
                    summary
                    ForEach(JunkCategory.allCases) { category in
                        if let result = model.results[category], !result.items.isEmpty || result.note != nil {
                            card(category, result)
                        }
                    }
                }
            }
        }
        .confirmationDialog("Move \(model.selected.count) items (\(model.selectedBytes.bytes)) to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { Task { await model.trashSelected() } }
        } message: {
            Text(confirmMessage)
        }
    }

    private var found: [(JunkCategory, Int64)] {
        JunkCategory.allCases.compactMap { c in model.results[c].flatMap { $0.total > 0 ? (c, $0.total) : nil } }
    }

    /// Colours go by position among the categories that found something, so neighbours never share one.
    private func color(_ category: JunkCategory) -> Color {
        Palette.series[(found.firstIndex { $0.0 == category } ?? 0) % Palette.series.count]
    }

    /// Total found, split by category like the Memory card.
    private var summary: some View {
        let total = found.reduce(0) { $0 + $1.1 }
        return Card("Found") {
            HStack(spacing: 28) {
                BigStat("Reclaimable", total.bytes, Palette.free)
                BigStat("Selected", model.selected.isEmpty ? "–" : model.selectedBytes.bytes, model.selected.isEmpty ? Theme.tertiary : Theme.accent)
                BigStat("Items", "\(model.allItems.count)", Theme.text)
                Spacer(minLength: 0)
            }
            StackedBar(parts: found.map { (Double($0.1), color($0.0)) }, total: Double(max(total, 1)))
            LegendGrid(columns: 4) {
                ForEach(found, id: \.0) { Legend(color($0.0), $0.0.title, $0.1.bytes, stacked: true) }
            }
        }
    }

    private func card(_ category: JunkCategory, _ result: CategoryResult) -> some View {
        let open = !collapsed.contains(category)
        return Card(category.title, symbol: category.symbol,
                    trailing: "\(result.items.count) items · \(result.total.bytes)") {
            if !result.items.isEmpty {
                Button(allSelected(result) ? "Deselect" : "Select all") { toggleAll(result) }.buttonStyle(.link)
            }
            Button {
                if open { collapsed.insert(category) } else { collapsed.remove(category) }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(open ? 0 : -90))
            }
            .buttonStyle(.borderless).foregroundStyle(Theme.secondary).help(open ? "Collapse" : "Expand")
        } content: {
            if let note = result.note { Text(note).font(Theme.small).foregroundStyle(Theme.secondary) }
            if open, !result.items.isEmpty { CardRows { rows(category, result) } }
        }
    }

    @ViewBuilder
    private func rows(_ category: JunkCategory, _ result: CategoryResult) -> some View {
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
            HStack(spacing: 8) {
                ShowMore(hidden: result.items.count - shown.count) { showAll.insert(category) }
                Text("Select all still covers every item").font(Theme.small).foregroundStyle(Theme.tertiary).padding(.top, 6)
            }
            .padding(.horizontal, 10)
        }
    }

    private func allSelected(_ r: CategoryResult) -> Bool { r.items.allSatisfy { $0.blocked != nil || model.selected.contains($0.url) } }

    private func toggleAll(_ r: CategoryResult) {
        let urls = Set(r.items.filter { $0.blocked == nil }.map(\.url))
        if allSelected(r) { model.selected.subtract(urls) } else { model.selected.formUnion(urls) }
    }

    /// Says plainly which parts can't be restored: items already in the Trash, and Docker data (removed by docker itself).
    private var confirmMessage: String {
        let chosen = model.allItems.filter { model.selected.contains($0.url) }
        var permanent: [String] = []
        if chosen.contains(where: { $0.docker == nil && FS.isInTrash($0.url) }) { permanent.append("items already in the Trash") }
        if chosen.contains(where: { $0.docker != nil }) { permanent.append("Docker images and volumes") }
        guard !permanent.isEmpty else { return "Items go to the Trash, so you can restore them until you empty it." }
        let rest = chosen.contains { $0.docker == nil && !FS.isInTrash($0.url) } ? " Everything else goes to the Trash and can be restored." : ""
        return "These are deleted permanently and can't be restored: \(permanent.joined(separator: " and "))." + rest
    }
}
