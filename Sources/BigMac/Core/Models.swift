import AppKit
import Foundation
import Observation

// MARK: - Jev settings

@MainActor @Observable
final class JevSettings {
    var client: TypeSafeClient?
    var status = "Not configured"
    var busy = false

    init(useKeychain: Bool = true) {
        if let key = TypeSafeKey.resolveLocal(useKeychain: useKeychain) { connect(key, source: "local") }
    }

    func connect(_ key: String, source: String) {
        client = TypeSafeClient(apiKey: key)
        status = "Connected (\(source))"
    }

    func fetchFromAWS() async {
        busy = true
        defer { busy = false }
        do {
            let key = try await Task.detached { try TypeSafeKey.fetchFromAWS() }.value
            TypeSafeKey.keychainSave(key)
            connect(key, source: "AWS \(TypeSafeKey.awsProfile) → Keychain")
        } catch {
            status = error.localizedDescription
        }
    }

    func disconnect() {
        TypeSafeKey.keychainDelete()
        client = nil
        status = "Not configured"
    }
}

// MARK: - Smart clean

@MainActor @Observable
final class JunkModel {
    var results: [JunkCategory: CategoryResult] = [:]
    var selected: Set<URL> = []
    var jev: [URL: JevJudgments.Verdict] = [:]
    var scanning = false
    var status = ""

    var allItems: [JunkItem] { JunkCategory.allCases.flatMap { results[$0]?.items ?? [] } }
    var selectedBytes: Int64 { allItems.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size } }
    var anyDenied: Bool { results.values.contains { $0.denied } }

    func scan() async {
        scanning = true
        selected = []
        jev = [:]
        results = [:]
        for category in JunkCategory.allCases {
            status = "Scanning \(category.title.lowercased())…"
            results[category] = await Task.detached { JunkScanner.scan(category) }.value
        }
        dropOverlaps()
        status = "Found \(allItems.reduce(0) { $0 + $1.size }.bytes) in \(allItems.count) items"
        scanning = false
    }

    /// An item can show up in two categories (e.g. CocoaPods cache, or an old *and* large download);
    /// keep only its first listing, and drop anything nested inside an item already listed.
    private func dropOverlaps() {
        var listed: [String] = []
        for category in JunkCategory.allCases {
            results[category]?.items.removeAll { item in
                if item.docker != nil { return false }
                let path = FS.key(item.url)
                if listed.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
                listed.append(path)
                return false
            }
        }
    }

    /// Selects every regenerable item (never downloads or large files — those need a human decision).
    func selectRecommended() {
        selected = Set(allItems.filter { !$0.needsReview && $0.blocked == nil && (jev[$0.url]?.value ?? 1) >= 0.5 }.map(\.url))
    }

    func askJev(_ client: TypeSafeClient) async {
        // Downloads/large files are never auto-selected, so don't send personal filenames for them.
        let items = allItems.filter { !$0.needsReview && $0.docker == nil }
        status = "Asking Jev about \(items.count) items…"
        do {
            let verdicts = try await JevJudgments.judgeJunk(items, client: client)
            for (item, verdict) in zip(items, verdicts) { jev[item.url] = verdict }
            let flagged = verdicts.filter { ($0?.value ?? 1) < 0.5 }.count
            status = "Jev reviewed \(items.count) items — \(flagged) look risky to delete"
        } catch {
            status = "Jev error: \(error.localizedDescription)"
        }
    }

    func trashSelected() async {
        let chosen = allItems.filter { selected.contains($0.url) && $0.blocked == nil }
        let files = chosen.filter { $0.docker == nil }.map { (url: $0.url, size: $0.size) }
        let docker = chosen.filter { $0.docker != nil }
        var result = await Task.detached { FS.trash(files) }.value
        let dockerRemoved = await Task.detached { docker.filter { DockerScanner.remove($0.docker!) } }.value
        result.trashed += dockerRemoved.map(\.url)
        result.freed += dockerRemoved.reduce(0) { $0 + $1.size }
        for failed in docker where !dockerRemoved.contains(failed) { result.failures.append((failed.url, "docker removal failed")) }
        let permanent = result.trashed.filter { FS.isInTrash($0) || $0.scheme == "docker" }.count
        status = "Removed \(result.trashed.count) items (\(result.freed.bytes))"
            + (permanent < result.trashed.count ? " — empty the Trash to actually reclaim the space" : "")
            + (result.failures.isEmpty ? "" : " — \(result.failures.count) failed")
        let gone = Set(result.trashed)
        for key in results.keys { results[key]?.items.removeAll { gone.contains($0.url) } }
        selected.subtract(gone)
    }
}

// MARK: - Duplicates

@MainActor @Observable
final class DuplicatesModel {
    var roots: [URL] = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]
        .map { FS.home.appending(path: $0) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    var minSizeMB: Double = 1
    var groups: [DuplicateGroup] = []
    var selected: Set<URL> = []
    var scanning = false
    var status = ""

    var wasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }

    func scan() async {
        scanning = true
        selected = []
        groups = []
        let roots = roots, minSize = Int64(minSizeMB * 1024 * 1024)
        let found = await Task.detached {
            DuplicateFinder.find(roots: roots, minSize: minSize) { message in
                Task { @MainActor in self.status = message }
            }
        }.value
        groups = found
        status = "\(found.count) duplicate groups · \(wasted.bytes) reclaimable"
        scanning = false
    }

    /// Keeps the oldest copy in each group and selects the rest.
    func selectAllButOldest() {
        selected = []
        for group in groups {
            let sorted = group.files.sorted { creation($0) < creation($1) }
            selected.formUnion(sorted.dropFirst())
        }
    }

    private func creation(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture
    }

    func trashSelected() async {
        // Never let every copy in a group go.
        var targets: [(url: URL, size: Int64)] = []
        for group in groups {
            let chosen = group.files.filter { selected.contains($0) }
            let allowed = chosen.count == group.files.count ? Array(chosen.dropFirst()) : chosen
            targets += allowed.map { ($0, group.size) }
        }
        let result = await Task.detached { FS.trash(targets) }.value
        let gone = Set(result.trashed)
        groups = groups.compactMap { g in
            let left = g.files.filter { !gone.contains($0) }
            return left.count > 1 ? DuplicateGroup(id: g.id, size: g.size, files: left) : nil
        }
        selected.subtract(gone)
        status = "Moved \(result.trashed.count) files (\(result.freed.bytes)) to Trash — empty it to reclaim the space"
            + (result.failures.isEmpty ? "" : " — \(result.failures.count) failed")
    }
}

// MARK: - Apps

@MainActor @Observable
final class AppsModel {
    var apps: [AppInfo] = []
    var jevRisk: [URL: JevJudgments.Verdict] = [:]
    var unusedDays = 90
    var onlyUnused = false
    var scanning = false
    var status = ""

    var visible: [AppInfo] { onlyUnused ? apps.filter { $0.isUnused(days: unusedDays) } : apps }

    func scan() async {
        scanning = true
        status = "Scanning applications…"
        apps = await Task.detached { AppScanner.scan() }.value
        let unused = apps.filter { $0.isUnused(days: unusedDays) }
        status = "\(apps.count) apps · \(unused.count) unused for \(unusedDays)+ days (\(unused.reduce(0) { $0 + $1.size }.bytes))"
        scanning = false
    }

    func askJev(_ client: TypeSafeClient) async {
        let targets = apps.filter { $0.removable && !$0.isApple }
        status = "Asking Jev about \(targets.count) apps…"
        do {
            let verdicts = try await JevJudgments.judgeApps(targets, client: client)
            for (app, v) in zip(targets, verdicts) { jevRisk[app.url] = v }
            status = "Jev flagged \(verdicts.filter { ($0?.value ?? 0) >= 0.5 }.count) apps as possible dependencies"
        } catch {
            status = "Jev error: \(error.localizedDescription)"
        }
    }

    func uninstall(_ app: AppInfo, includeLeftovers: Bool) async {
        var targets = [(url: app.url, size: app.size)]
        if includeLeftovers { targets += app.leftovers.map { ($0, Int64(0)) } }
        let result = await Task.detached { FS.trash(targets) }.value
        if result.trashed.contains(app.url) { apps.removeAll { $0.url == app.url } }
        status = result.failures.isEmpty
            ? "Moved \(app.name) to Trash (\((app.size + (includeLeftovers ? app.leftoverSize : 0)).bytes))"
            : "Could not remove: \(result.failures.map { $0.1 }.joined(separator: ", "))"
    }
}

// MARK: - Network

struct ConnectionRow: Identifiable, Sendable {
    var id: String { connection.id }
    let connection: Connection
    let exePath: String?
    let signer: Signer
    let signals: [RiskSignal]
    let firstSeen: Date
    /// The user marked this binary as a false positive.
    var trusted = false
    /// Identical (process, remote) sockets collapsed into this row.
    var count = 1
    var level: RiskLevel { trusted ? .none : RiskLevel(signals: signals) }
    var jevKey: String { "\(exePath ?? connection.command)|\(connection.remote)" }
}

@MainActor @Observable
final class NetworkModel {
    var rows: [ConnectionRow] = []
    // Nothing polls until the user clicks Snapshot or Watch.
    var jev: [String: JevJudgments.Verdict] = [:]  // keyed by exe+remote so polling doesn't re-bill
    var running = false
    var autoJev = false
    var interval: Double = 5
    var status = "Click Snapshot for one reading, or Watch to poll every few seconds."
    private var firstSeen: [String: Date] = [:]
    private let signatures = SignatureCache()
    /// Binaries the user marked as false positives; their connections show as OK.
    private(set) var trusted = Set(UserDefaults.standard.stringArray(forKey: "networkTrusted") ?? []) {
        didSet { UserDefaults.standard.set(Array(trusted).sorted(), forKey: "networkTrusted") }
    }

    func setTrusted(_ row: ConnectionRow, _ on: Bool) {
        guard let path = row.exePath else { return }
        if on { trusted.insert(path) } else { trusted.remove(path) }
        for i in rows.indices where rows[i].exePath == path { rows[i].trusted = on }
    }
    private var loop: Task<Void, Never>?
    private let launched = Date()

    func isNew(_ row: ConnectionRow) -> Bool {
        row.firstSeen.timeIntervalSince(launched) > interval * 1.5 && Date().timeIntervalSince(row.firstSeen) < 60
    }

    func start(jev settings: JevSettings) {
        guard loop == nil else { return }
        running = true
        loop = Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.refresh()
                if self.autoJev, let client = settings.client { await self.askJev(client, onlyUnjudged: true) }
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        running = false
    }

    func refresh() async {
        do {
            let connections = try await Task.detached { try Lsof.connections() }.value
            var fresh: [ConnectionRow] = []
            var index: [String: Int] = [:]
            for c in connections {
                // Many sockets from one process to the same remote differ only by local port; show them once.
                let key = "\(c.pid)|\(c.proto)|\(c.remote)"
                if let i = index[key] { fresh[i].count += 1; continue }
                index[key] = fresh.count
                let path = Lsof.executablePath(pid: c.pid)
                let signer = path != nil ? await signatures.signer(for: path!) : .unknown
                let seen = firstSeen[c.id] ?? Date()
                firstSeen[c.id] = seen
                fresh.append(ConnectionRow(connection: c, exePath: path, signer: signer,
                                           signals: RiskSignal.evaluate(c, exePath: path, signer: signer), firstSeen: seen,
                                           trusted: path.map(trusted.contains) ?? false))
            }
            rows = fresh.sorted { ($0.level, jev[$0.jevKey]?.value ?? 0) > ($1.level, jev[$1.jevKey]?.value ?? 0) }
            let flagged = rows.filter { $0.level >= .medium }.count
            status = "\(rows.count) connections from \(Set(rows.map(\.connection.pid)).count) processes · \(flagged) flagged · \(Date().formatted(date: .omitted, time: .standard))"
        } catch {
            status = "lsof failed: \(error.localizedDescription)"
        }
    }

    func askJev(_ client: TypeSafeClient, onlyUnjudged: Bool = false) async {
        // One row per unique (binary, remote) pair.
        var seen = Set<String>()
        let targets = rows.filter { (!onlyUnjudged || jev[$0.jevKey] == nil) && seen.insert($0.jevKey).inserted }
        guard !targets.isEmpty else { return }
        do {
            let verdicts = try await JevJudgments.judgeConnections(targets, client: client)
            for (row, v) in zip(targets, verdicts) { jev[row.jevKey] = v }
        } catch {
            status = "Jev error: \(error.localizedDescription)"
        }
    }

    func kill(_ row: ConnectionRow) {
        Darwin.kill(row.connection.pid, SIGTERM)
    }
}

@MainActor @Observable
final class AuditModel {
    var report = AuditReport()
    var verdicts: [String: AuditVerdict] = [:]
    var scanning = false
    var triaging = false
    var status = "Runs only when you click Run audit."
    var triageAfterScan = true
    var provider = InferenceProvider(rawValue: UserDefaults.standard.string(forKey: "inferenceProvider") ?? "") ?? .bedrock {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: "inferenceProvider")
            if let first = provider.models.first, !provider.models.contains(where: { $0.0 == model }) { model = first.0 }
        }
    }
    var model = UserDefaults.standard.string(forKey: "bedrockModel") ?? BedrockClient.models[0].0 {
        didSet { UserDefaults.standard.set(model, forKey: "bedrockModel") }
    }
    /// Only for the OpenAI-compatible provider.
    var openAIBaseURL = UserDefaults.standard.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1" {
        didSet { UserDefaults.standard.set(openAIBaseURL, forKey: "openAIBaseURL") }
    }
    var openAIModel = UserDefaults.standard.string(forKey: "openAIModel") ?? "" {
        didSet { UserDefaults.standard.set(openAIModel, forKey: "openAIModel") }
    }
    var lastScan: Date?

    /// The configured model, or why it can't run yet.
    var client: Result<any ToolModel, InferenceError> {
        switch provider {
        case .bedrock:
            return .success(BedrockClient(model: model))
        case .anthropic:
            guard let key = InferenceKeys.resolve(.anthropic) else { return .failure(.init(message: "add an Anthropic API key in Settings")) }
            return .success(AnthropicClient(model: model, key: key))
        case .openai:
            guard let url = URL(string: openAIBaseURL), url.scheme == "https" || url.host() == "localhost" || url.host() == "127.0.0.1" else {
                return .failure(.init(message: "set an https base URL in Settings"))
            }
            guard !openAIModel.isEmpty else { return .failure(.init(message: "set a model id in Settings")) }
            // Local servers (Ollama, LM Studio) usually need no key.
            return .success(OpenAICompatibleClient(model: openAIModel, baseURL: url, key: InferenceKeys.resolve(.openai)))
        }
    }

    /// False positives the user marked, by fingerprint (value is the title, for display in Settings/debugging).
    /// Fingerprints are path-based, so marks survive rescans; dismissed items are never sent to Haiku.
    private(set) var dismissed = (UserDefaults.standard.dictionary(forKey: "auditDismissed") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(dismissed, forKey: "auditDismissed") }
    }

    func isDismissed(_ o: AuditItem) -> Bool { dismissed[o.id] != nil }

    func setDismissed(_ o: AuditItem, _ on: Bool) {
        dismissed[o.id] = on ? o.title : nil
        summarize()
    }

    /// Haiku's call wins over the heuristic once it has judged an item; a false-positive mark wins over both.
    /// A known-technique match is a floor the model can't lower, since the evidence it reads is attacker-written.
    func severity(_ o: AuditItem) -> RiskLevel {
        if isDismissed(o) { return .none }
        guard let verdict = verdicts[o.id] else { return o.severity }
        return o.signals.contains(where: { $0.hasPrefix("known technique:") }) ? max(verdict.severity, o.severity) : verdict.severity
    }

    func run() async {
        scanning = true
        status = "Collecting evidence…"
        verdicts = [:]
        report = await Task.detached { await HostAudit.run() }.value
        scanning = false
        lastScan = Date()
        summarize()
        if triageAfterScan { await triage() }
    }

    func triage() async {
        let items = AuditTriage.candidates(report.observations.filter { !isDismissed($0) })
        guard !items.isEmpty else { return }
        triaging = true
        defer { triaging = false }
        summarize()
        let client: any ToolModel
        switch self.client {
        case .success(let c): client = c
        case .failure(let e): status += " · AI triage skipped: \(e.message)"; return
        }
        status += " · asking \(client.model) about \(items.count) items…"
        let outcome = await Task.detached { AuditTriage.triage(items, client: client) }.value
        verdicts = outcome.verdicts
        summarize()
        let tokens = outcome.usage.input + outcome.usage.output
        let cost = listPrice(model: client.model).map { Double(outcome.usage.input) / 1e6 * $0.0 + Double(outcome.usage.output) / 1e6 * $0.1 }
        status += " · AI judged \(outcome.verdicts.count)/\(items.count)"
            + (outcome.skipped > 0 ? " (\(outcome.skipped) skipped by call cap)" : "")
            + " · \(tokens) tokens" + (cost.map { " ≈ $\(String(format: "%.4f", $0)) list price" } ?? "")
        if let first = outcome.errors.first { status += " · \(outcome.errors.count) batch(es) failed: \(first)" }
    }

    func summarize() {
        let levels = report.observations.map(severity)
        let high = levels.filter { $0 == .high }.count, medium = levels.filter { $0 == .medium }.count
        let fp = report.observations.filter(isDismissed).count
        status = "\(report.observations.count) observations · \(high) high · \(medium) medium"
            + (fp > 0 ? " · \(fp) false positive\(fp == 1 ? "" : "s")" : "")
            + (lastScan.map { " · \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
    }

    func trash(_ o: AuditItem) -> String {
        guard let url = o.path else { return "Nothing to remove" }
        let result = FS.trash([(url, 0)])
        if result.trashed.isEmpty {
            return "Couldn't move \(FS.tildePath(url)) to Trash (\(result.failures.first?.1 ?? "permission denied")). System items need: sudo rm \"\(url.path)\""
        }
        report.observations.removeAll { $0.id == o.id }
        return "Moved \(url.lastPathComponent) to Trash. Log out or restart to stop anything it already launched."
    }

    func removalPlan(_ o: AuditItem) -> RemovalPlan? {
        guard o.kind == .persistence, let url = o.path, url.pathExtension == "plist" else { return nil }
        return Removal.plan(plist: url)
    }

    /// Full removal (stop, vendor cleanup, Trash). May show the macOS admin prompt for root-owned files.
    func remove(_ o: AuditItem, plan: RemovalPlan, selected: Set<String>) async -> String {
        let outcome = await Task.detached { Removal.execute(plan, selected: selected) }.value
        if outcome.failed.isEmpty { report.observations.removeAll { $0.id == o.id } }
        summarize()
        var parts = outcome.log
        if !outcome.removed.isEmpty { parts.append("Moved \(outcome.removed.count) item\(outcome.removed.count == 1 ? "" : "s") to the Trash") }
        if !outcome.failed.isEmpty {
            parts.append("\(outcome.failed.count) left in place (\(outcome.failed[0].1)): " + outcome.failed.map { FS.tildePath($0.0) }.joined(separator: ", "))
        }
        return "\(plan.label): " + parts.joined(separator: " · ")
    }

    func quit(_ o: AuditItem) {
        if let pid = o.pid { Darwin.kill(pid, SIGTERM) }
    }
}
