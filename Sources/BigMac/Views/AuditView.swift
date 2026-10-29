import SwiftUI

struct AuditView: View {
    /// Summary-strip filters: OR within levels and within verdicts, AND between the two.
    enum Facet: Hashable { case level(RiskLevel), call(AuditVerdict.Call), dismissed }

    @Environment(AuditModel.self) private var model
    @State private var onlySuspicious = true
    @State private var facets: Set<Facet> = []
    @State private var expanded: Set<String> = []
    @State private var trashTarget: AuditItem?
    @State private var removing: Removing?

    struct Removing: Identifiable {
        var id: String { item.id }
        let item: AuditItem
        let plan: RemovalPlan
    }

    private func startRemoval(_ o: AuditItem) {
        if let plan = model.removalPlan(o) { removing = Removing(item: o, plan: plan) } else { trashTarget = o }
    }
    @State private var quitTarget: AuditItem?
    @State private var message: String?

    private var visible: [AuditItem] {
        let levels = Set(facets.compactMap { if case .level(let l) = $0 { l } else { nil } })
        let calls = Set(facets.compactMap { if case .call(let c) = $0 { c } else { nil } })
        return model.report.observations
            .filter { o in
                let fp = model.isDismissed(o)
                if facets.contains(.dismissed) { return fp }
                if fp { return !onlySuspicious && levels.isEmpty && calls.isEmpty }
                if !levels.isEmpty && !levels.contains(model.severity(o)) { return false }
                if !calls.isEmpty && !(model.verdicts[o.id].map { calls.contains($0.call) } ?? false) { return false }
                if levels.isEmpty && calls.isEmpty && onlySuspicious {
                    return model.severity(o) > .none || model.verdicts[o.id]?.call == .needsValidation
                }
                return true
            }
            .sorted { (model.severity($0), $1.title) > (model.severity($1), $0.title) }
    }

    private func toggle(_ f: Facet) {
        if f == .dismissed || facets.contains(.dismissed) { facets = facets.contains(f) ? [] : [f]; return }
        if facets.contains(f) { facets.remove(f) } else { facets.insert(f) }
    }

    var body: some View {
        @Bindable var model = model
        PaneView(title: "Security Audit", status: model.status, busy: model.scanning || model.triaging) {
            FilterChip(title: "Suspicious", isOn: $onlySuspicious).disabled(!facets.isEmpty)
                .help("Hide items with nothing to look at. The summary filters below override this.")
            FilterChip(title: "AI triage", isOn: $model.triageAfterScan)
                .help("After collecting, send flagged items (redacted, opaque ids) to the model chosen in Settings: \(model.provider.title)")
            Button { Task { await model.triage() } } label: { ActionLabel("Ask AI", symbol: "sparkle") }
                .buttonStyle(.ghost).disabled(model.scanning || model.triaging || model.report.observations.isEmpty)
            Button { Task { await model.run() } } label: { ActionLabel("Run audit", key: "⌘R") }
                .buttonStyle(.primary).keyboardShortcut("r").disabled(model.scanning || model.triaging)
        } content: {
            VStack(spacing: 0) {
                if let message { Callout(symbol: "info.circle", text: message, tint: Theme.blue, actionTitle: "Dismiss") { self.message = nil } }
                if model.report.observations.isEmpty && !model.scanning {
                    EmptyState(symbol: "shield.lefthalf.filled", title: "No audit yet",
                               message: "A read-only sweep for fraud and malware footholds: persistence, unsigned processes, HTTPS interception, remote-access tools, browser and system extensions. Takes about 10 seconds.") {
                        Button { Task { await model.run() } } label: { ActionLabel("Run audit", key: "⌘R") }.buttonStyle(.primary)
                    }
                } else {
                    summary
                    Hairline()
                    if visible.isEmpty {
                        EmptyState(symbol: "line.3.horizontal.decrease", title: "Nothing matches",
                                   message: "No items match the selected filters.") {
                            Button { facets = [] } label: { ActionLabel("Clear filters") }.buttonStyle(.ghost)
                        }
                    }
                    Scroller {
                        Group {
                            ForEach(AuditItem.Kind.allCases, id: \.self) { kind in
                                let items = visible.filter { $0.kind == kind }
                                if !items.isEmpty {
                                    Section { ForEach(items) { row($0) } } header: {
                                        ListGroup {
                                            Image(systemName: kind.symbol).font(.system(size: 11))
                                            Text(kind.rawValue).foregroundStyle(Theme.text)
                                            Text("\(items.count)").foregroundStyle(Theme.tertiary)
                                            Spacer()
                                        } rows: { EmptyView() }
                                    }
                                }
                            }
                            if !model.report.notes.isEmpty {
                                Section {
                                    ForEach(model.report.notes, id: \.self) { note in
                                        Row { Text(note).font(Theme.small).foregroundStyle(Theme.secondary).textSelection(.enabled) }
                                    }
                                } header: {
                                    ListGroup { Image(systemName: "info.circle"); Text("Not covered"); Spacer() } rows: { EmptyView() }
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $removing) { r in
            RemovalSheet(plan: r.plan) { selected in
                removing = nil
                Task { message = await model.remove(r.item, plan: r.plan, selected: selected) }
            } cancel: { removing = nil }
        }
        .confirmationDialog("Move \(trashTarget?.path?.lastPathComponent ?? "") to the Trash?", isPresented: Binding(get: { trashTarget != nil }, set: { if !$0 { trashTarget = nil } })) {
            Button("Move to Trash", role: .destructive) { if let t = trashTarget { message = model.trash(t) }; trashTarget = nil }
        } message: {
            Text("It stays in the Trash until you empty it. Already-running copies keep running until you log out or quit them.")
        }
        .confirmationDialog("Send SIGTERM to \(quitTarget?.title ?? "") (pid \(quitTarget?.pid ?? 0))?", isPresented: Binding(get: { quitTarget != nil }, set: { if !$0 { quitTarget = nil } })) {
            Button("Quit process", role: .destructive) { if let t = quitTarget { model.quit(t) }; quitTarget = nil }
        }
    }

    /// Counts per level and verdict, like a Linear project header. Click to filter.
    private var summary: some View {
        let live = model.report.observations.filter { !model.isDismissed($0) }
        let levels = live.map(model.severity)
        let calls = live.compactMap { model.verdicts[$0.id]?.call }
        let fp = model.report.observations.count - live.count
        return FilterStrip(active: !facets.isEmpty, trailing: "\(model.report.observations.count) checked", clear: { facets = [] }) {
            stat("High", levels.filter { $0 == .high }.count, Theme.red, .level(.high))
            stat("Medium", levels.filter { $0 == .medium }.count, Theme.orange, .level(.medium))
            stat("Low", levels.filter { $0 == .low }.count, Theme.yellow, .level(.low))
            StripDivider()
            stat("Suspicious", calls.filter { $0 == .confirmed }.count, Theme.red, .call(.confirmed))
            stat("To check", calls.filter { $0 == .needsValidation }.count, Theme.orange, .call(.needsValidation))
            stat("Benign", calls.filter { $0 == .benign }.count, Theme.green, .call(.benign))
            if fp > 0 {
                StripDivider()
                stat("False positives", fp, Theme.secondary, .dismissed)
            }
        }
    }

    private func stat(_ label: String, _ count: Int, _ tint: Color, _ facet: Facet) -> some View {
        StatToggle(label: label, count: count, tint: tint, isOn: facets.contains(facet)) { toggle(facet) }
    }

    private func row(_ o: AuditItem) -> some View {
        let verdict = model.verdicts[o.id]
        let open = expanded.contains(o.id)
        let fp = model.isDismissed(o)
        return Row(selected: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Pill(text: model.severity(o).label, tint: Theme.risk(model.severity(o))).frame(width: 74, alignment: .leading)
                    Text(o.title).fontWeight(.medium).lineLimit(1).foregroundStyle(fp ? Theme.secondary : Theme.text)
                    Text(verdict?.rationale ?? o.signals.joined(separator: " · "))
                        .font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    if fp {
                        Pill(text: "False positive", tint: Theme.tertiary)
                    } else if let verdict {
                        Pill(text: verdict.call.label, tint: verdict.call == .confirmed ? Theme.red : verdict.call == .benign ? Theme.green : Theme.orange)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                if open { detail(o, verdict).padding(.leading, 84) }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { if open { expanded.remove(o.id) } else { expanded.insert(o.id) } } }
        }
        .contextMenu { actions(o) }
    }

    @ViewBuilder
    private func detail(_ o: AuditItem, _ verdict: AuditVerdict?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(o.evidence, id: \.self) { Text($0).monoSecondary().lineLimit(2).truncationMode(.middle).textSelection(.enabled) }
            }
            if !o.signals.isEmpty {
                Text(o.signals.joined(separator: " · ")).font(Theme.small).foregroundStyle(Theme.orange)
            }
            if let verdict {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkle").font(.system(size: 10)).foregroundStyle(Theme.accent)
                        Text("AI").font(Theme.label).foregroundStyle(Theme.secondary)
                        if !verdict.atRisk.isEmpty, verdict.call != .benign {
                            Text("· at risk: \(verdict.atRisk)").font(Theme.label).foregroundStyle(Theme.secondary)
                        }
                    }
                    Text(verdict.rationale).font(Theme.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    Text("→ \(verdict.action)").font(Theme.body).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }
            HStack(spacing: 6) {
                if let url = o.path { Button { revealInFinder(url) } label: { ActionLabel("Reveal", symbol: "folder") }.buttonStyle(.ghost) }
                if o.kind == .persistence, let url = o.path, url.pathExtension == "plist" {
                    Button { startRemoval(o) } label: { ActionLabel("Remove…", symbol: "trash") }.buttonStyle(.ghost)
                }
                if let pid = o.pid, [.process, .network].contains(o.kind) {
                    Button { quitTarget = o } label: { ActionLabel("Quit \(pid)", symbol: "xmark.octagon") }.buttonStyle(.ghost)
                }
                Button { copy(o) } label: { ActionLabel("Copy", symbol: "doc.on.doc") }.buttonStyle(.ghost)
                Spacer()
                falsePositiveButton(o)
            }
        }
    }

    private func falsePositiveButton(_ o: AuditItem) -> some View {
        let fp = model.isDismissed(o)
        return Button { model.setDismissed(o, !fp) } label: {
            ActionLabel(fp ? "Restore" : "Mark false positive", symbol: fp ? "arrow.uturn.backward" : "hand.thumbsup")
        }
        .buttonStyle(.ghost)
        .help(fp ? "Count this item again and send it to the AI on the next triage."
                 : "Expected on this Mac. It drops to OK, stays hidden, and isn't sent to the AI again.")
    }

    @ViewBuilder
    private func actions(_ o: AuditItem) -> some View {
        if let url = o.path { Button("Reveal in Finder") { revealInFinder(url) } }
        Button("Copy evidence") { copy(o) }
        Button(model.isDismissed(o) ? "Restore (not a false positive)" : "Mark as false positive") { model.setDismissed(o, !model.isDismissed(o)) }
        if o.kind == .persistence, let url = o.path, url.pathExtension == "plist" {
            Divider()
            Button("Remove launch item and what it installed…", role: .destructive) { startRemoval(o) }
        }
        if let pid = o.pid, [.process, .network].contains(o.kind) {
            Button("Quit process \(pid)…", role: .destructive) { quitTarget = o }
        }
    }

    private func copy(_ o: AuditItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(([o.title] + o.evidence + o.signals).joined(separator: "\n"), forType: .string)
    }
}

extension AuditVerdict.Call {
    var label: String {
        switch self {
        case .confirmed: "Suspicious"
        case .needsValidation: "Check"
        case .benign: "Benign"
        }
    }
}

/// Confirms a full removal: what gets stopped, what goes to the Trash, and whether macOS will ask for a password.
struct RemovalSheet: View {
    let plan: RemovalPlan
    let confirm: (Set<String>) -> Void
    let cancel: () -> Void
    @State private var selected: Set<String>

    init(plan: RemovalPlan, confirm: @escaping (Set<String>) -> Void, cancel: @escaping () -> Void) {
        self.plan = plan
        self.confirm = confirm
        self.cancel = cancel
        _selected = State(initialValue: Set(plan.targets.filter(\.selected).map(\.id)))
    }

    private var needsAdmin: Bool {
        !plan.plist.path.hasPrefix(FS.home.path) || plan.targets.contains { selected.contains($0.id) && $0.needsAdmin }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Remove \(plan.label)").font(Theme.title).foregroundStyle(Theme.text)
                Text("Stops it now and moves these to the Trash. Nothing is deleted until you empty the Trash.")
                    .font(Theme.small).foregroundStyle(Theme.secondary)
            }
            .padding(16)
            Hairline()
            VStack(alignment: .leading, spacing: 0) {
                if let hook = plan.preflight {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle").font(.system(size: 12)).foregroundStyle(Theme.green).frame(width: 14)
                        Text("First: \(hook.why)").font(Theme.body).foregroundStyle(Theme.text)
                    }
                    .padding(.horizontal, 16).frame(height: 34)
                }
                if let program = plan.program {
                    HStack(spacing: 10) {
                        Image(systemName: "stop.circle").font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 14)
                        Text("Stops processes running \(FS.tildePath(URL(filePath: program)))").font(Theme.body).foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.horizontal, 16).frame(height: 34)
                }
                ForEach(plan.targets) { t in
                    let binding = Binding(get: { selected.contains(t.id) }, set: { if $0 { selected.insert(t.id) } else { selected.remove(t.id) } })
                    HStack(spacing: 10) {
                        CheckBox(isOn: binding, disabled: t.url == plan.plist)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(FS.tildePath(t.url)).font(Theme.mono).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                            Text(t.why + (t.needsAdmin ? " · needs admin" : "")).font(Theme.small).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
            }
            .padding(.vertical, 6)
            Hairline()
            HStack {
                if needsAdmin {
                    Label("macOS will ask for your password", systemImage: "lock").font(Theme.small).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                Button { confirm(selected) } label: { ActionLabel("Remove \(selected.count)") }.buttonStyle(.danger)
            }
            .padding(12)
        }
        .frame(width: 520)
        .background(Theme.canvas)
    }
}
