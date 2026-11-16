import SwiftUI

struct DuplicatesView: View {
    @Environment(DuplicatesModel.self) private var model
    @State private var confirm = false

    var body: some View {
        @Bindable var model = model
        PaneView(title: "Duplicates", status: model.status, busy: model.scanning) {
            Button { model.selectAllButOldest() } label: { ActionLabel("Keep oldest") }
                .buttonStyle(.ghost).disabled(model.groups.isEmpty)
                .help("Select every copy except the oldest in each group")
            Button { Task { await model.scan() } } label: { ActionLabel("Scan", key: "⌘R") }
                .buttonStyle(.ghost).keyboardShortcut("r").disabled(model.busy || model.roots.isEmpty)
            Button { confirm = true } label: { ActionLabel(model.selected.isEmpty ? "Trash" : "Trash \(model.selected.count)", symbol: "trash") }
                .buttonStyle(.primary).disabled(model.selected.isEmpty || model.busy)
        } content: {
            CardColumn {
                Card("Folders", symbol: "folder") {
                    HStack(spacing: 6) {
                        ForEach(model.roots, id: \.self) { root in
                            HStack(spacing: 5) {
                                Image(systemName: "folder").font(.system(size: 11))
                                Text(root.lastPathComponent)
                                Button { model.roots.removeAll { $0 == root } } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain).foregroundStyle(Theme.tertiary)
                            }
                            .font(Theme.small).foregroundStyle(Theme.text)
                            .padding(.horizontal, 9).frame(height: 26)
                            .background(Theme.border.opacity(0.5), in: Capsule())
                            .help(FS.tildePath(root))
                        }
                        Button { addFolder() } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)) }
                            .buttonStyle(.ghost).help("Add folder")
                        Spacer()
                        Text("Min size").font(Theme.small).foregroundStyle(Theme.secondary)
                        Picker("", selection: $model.minSizeMB) {
                            ForEach([0.1, 1, 10, 100], id: \.self) { Text("\($0, specifier: "%g") MB").tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                }
                if model.groups.isEmpty && !model.scanning {
                    EmptyState(symbol: "square.on.square", title: "No duplicates listed",
                               message: "Files are compared by size, then a 64 KB prefix hash, then full SHA-256. Hardlinks are collapsed; APFS clones may free less than shown.") {
                        Button { Task { await model.scan() } } label: { ActionLabel("Scan", key: "⌘R") }.buttonStyle(.primary)
                    }
                } else {
                    Card("Found") {
                        HStack(spacing: 28) {
                            BigStat("Reclaimable", model.wasted.bytes, Palette.free)
                            BigStat("Groups", "\(model.groups.count)", Theme.text)
                            BigStat("Selected", "\(model.selected.count)", model.selected.isEmpty ? Theme.tertiary : Theme.accent)
                            Spacer(minLength: 0)
                        }
                    }
                    ForEach(model.groups) { group in
                        Card("\(group.files.count) copies", trailing: "\(group.size.bytes) each · \(group.wasted.bytes) reclaimable") {
                            CardRows {
                                ForEach(group.files, id: \.self) { file in
                                    Row(selected: model.selected.contains(file)) {
                                        CheckBox(isOn: Binding(
                                            get: { model.selected.contains(file) },
                                            set: { on in if on { model.selected.insert(file) } else { model.selected.remove(file) } }
                                        ))
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 18, height: 18)
                                        Text(file.lastPathComponent).lineLimit(1)
                                        Text(FS.tildePath(file.deletingLastPathComponent())).monoSecondary().lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                    }
                                    .contextMenu { Button("Reveal in Finder") { revealInFinder(file) } }
                                }
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Move \(model.selected.count) duplicate files to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { Task { await model.trashSelected() } }
        } message: {
            Text("At least one copy of every group is always kept.")
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !model.roots.contains(url) { model.roots.append(url) }
        }
    }
}
