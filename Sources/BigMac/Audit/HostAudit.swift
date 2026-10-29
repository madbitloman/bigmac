import Foundation

/// One evidence-backed fact about the machine. Collectors are deterministic and read-only;
/// Haiku only judges what they found (see `AuditTriage`).
struct AuditItem: Identifiable, Sendable, Hashable {
    enum Kind: String, CaseIterable, Sendable {
        case posture = "Security posture"
        case persistence = "Persistence (launch agents, cron, shell)"
        case process = "Running processes"
        case network = "Network connections"
        case interception = "Traffic interception (proxy, DNS, certs, profiles)"
        case remoteAccess = "Remote-access tools"
        case browser = "Browser extensions"
        case systemExtension = "System & kernel extensions"
        case privacy = "Privacy permissions"

        var symbol: String {
            switch self {
            case .posture: "checkmark.shield"
            case .persistence: "arrow.clockwise.circle"
            case .process: "cpu"
            case .network: "network"
            case .interception: "lock.trianglebadge.exclamationmark"
            case .remoteAccess: "display.2"
            case .browser: "puzzlepiece.extension"
            case .systemExtension: "gearshape.2"
            case .privacy: "hand.raised"
            }
        }
    }

    /// Stable fingerprint, e.g. `persistence:/Library/LaunchDaemons/x.plist`.
    let id: String
    let kind: Kind
    let title: String
    var evidence: [String]
    var signals: [String] = []
    var severity: RiskLevel = .none
    var path: URL?
    var pid: Int32?
    /// Apple-signed or otherwise expected; never sent to Haiku.
    var routine = false
}

struct AuditReport: Sendable {
    var observations: [AuditItem] = []
    /// Checks that couldn't run (need admin, Full Disk Access, ...).
    var notes: [String] = []
}

enum HostAudit {
    static func run() async -> AuditReport {
        let signatures = SignatureCache()
        var report = AuditReport()
        report.observations += posture(&report.notes)
        report.observations += await persistence(signatures)
        report.observations += await processes(signatures)
        report.observations += await network(signatures)
        report.observations += interception(&report.notes)
        report.observations += remoteAccess()
        report.observations += browserExtensions()
        report.observations += systemExtensions()
        report.observations += privacy(&report.notes)
        report.observations = ThreatIntel.enrich(report.observations)
        report.notes.append("Login items registered with Background Task Management need admin to list: run `sudo sfltool dumpbtm` in Terminal.")
        return report
    }

    // MARK: Posture

    static func posture(_ notes: inout [String]) -> [AuditItem] {
        var out: [AuditItem] = []
        func add(_ id: String, _ title: String, _ evidence: String, bad: Bool, level: RiskLevel = .medium) {
            out.append(AuditItem(id: "posture:\(id)", kind: .posture, title: title, evidence: [evidence],
                                   severity: bad ? level : .none, routine: !bad))
        }
        if let s = Shell.run("spctl", ["--status"], anyStatus: true) {
            add("gatekeeper", "Gatekeeper", s.trimmed, bad: !s.contains("enabled"), level: .high)
        }
        if let s = Shell.run("csrutil", ["status"], anyStatus: true) {
            add("sip", "System Integrity Protection", s.trimmed, bad: !s.contains("enabled."), level: .high)
        }
        if let s = Shell.run("fdesetup", ["status"], anyStatus: true) {
            add("filevault", "FileVault disk encryption", s.trimmed, bad: !s.contains("On"))
        }
        if let s = Shell.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"], anyStatus: true) {
            add("firewall", "Application firewall", s.trimmed, bad: s.contains("disabled"), level: .low)
        }
        for (label, name) in [("com.openssh.sshd", "Remote Login (SSH)"), ("com.apple.screensharing", "Screen Sharing")] {
            let on = Shell.succeeds("launchctl", ["print", "system/\(label)"])
            add(label, name, on ? "\(label) is loaded — the Mac accepts incoming \(name) sessions" : "off", bad: on, level: .low)
        }
        if let user = Shell.run("defaults", ["read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"])?.trimmed, !user.isEmpty {
            add("autologin", "Automatic login", "Logs in as \(user) without a password", bad: true, level: .low)
        }
        return out
    }

    // MARK: Persistence

    static let launchDirs: [URL] = [
        FS.home.appending(path: "Library/LaunchAgents"),
        URL(filePath: "/Library/LaunchAgents"),
        URL(filePath: "/Library/LaunchDaemons"),
    ]

    struct LaunchItem: Sendable {
        let label: String
        let program: String?
        let arguments: [String]
        let runAtLoad: Bool
        let keepAlive: Bool
    }

    static func parseLaunchPlist(_ url: URL) -> LaunchItem? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let args = plist["ProgramArguments"] as? [String] ?? []
        let keepAlive = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] is [String: Any])
        return LaunchItem(label: plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent,
                          program: plist["Program"] as? String ?? args.first, arguments: args,
                          runAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive)
    }

    /// Patterns that turn a shell line or launch command into a downloader/backdoor.
    static let suspiciousCommand: [(String, String)] = [
        (#"(curl|wget)[^|;]*\|\s*(ba|z)?sh"#, "pipes a download into a shell"),
        (#"base64\s+(-d|-D|--decode)"#, "decodes base64 payload"),
        (#"eval\s+["']?\$\((curl|wget)"#, "evals downloaded code"),
        (#"DYLD_INSERT_LIBRARIES"#, "injects a dylib into processes"),
        (#"/dev/tcp/|nc\s+(-e|-c)|ncat\s+-e"#, "opens a reverse shell"),
        (#"osascript\s+-e"#, "runs inline AppleScript"),
        (#"python[0-9.]*\s+-c\s+.*(socket|exec|urllib)"#, "runs inline Python networking/exec"),
        (#"https?://\d{1,3}(\.\d{1,3}){3}"#, "talks to a raw IP URL"),
    ]

    /// BigMac itself (often an ad-hoc debug build under .build/), never worth reporting.
    static let ownExecutable = Bundle.main.executableURL?.resolvingSymlinksInPath().path

    static func commandSignals(_ text: String) -> [String] {
        suspiciousCommand.compactMap { pattern, label in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil ? label : nil
        }
    }

    static func persistence(_ signatures: SignatureCache) async -> [AuditItem] {
        var out: [AuditItem] = []
        let interpreters: Set<String> = ["sh", "bash", "zsh", "python", "python3", "osascript", "perl", "ruby", "node", "curl"]
        for dir in launchDirs {
            for url in FS.children(of: dir) ?? [] where url.pathExtension == "plist" {
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                guard let item = parseLaunchPlist(url) else {
                    out.append(AuditItem(id: "persistence:\(url.path)", kind: .persistence, title: url.lastPathComponent,
                                           evidence: ["\(FS.tildePath(url)) is not a readable property list"],
                                           signals: ["unreadable plist"], severity: .low, path: url))
                    continue
                }
                if item.program == nil {
                    out.append(AuditItem(id: "persistence:\(url.path)", kind: .persistence, title: item.label,
                                         evidence: ["plist: \(FS.tildePath(url))", "defines no program — inert leftover"],
                                         path: url, routine: true))
                    continue
                }
                var signals: [String] = []
                var signer = Signer.unknown
                var signerNote: String?
                if let program = item.program {
                    if FileManager.default.fileExists(atPath: program), !FileManager.default.isReadableFile(atPath: program) {
                        signerNote = "not checked — binary is root-only (owner \(owner(program)))"
                    } else if FileManager.default.fileExists(atPath: program) {
                        signer = await signatures.signer(for: program)
                        signals += RiskSignal.binary(path: program, signer: signer).map(\.rawValue)
                        if dir.path.hasPrefix("/Library"), FileManager.default.isWritableFile(atPath: program) {
                            signals.append("system-wide item runs a binary your user account can modify")
                        }
                    } else {
                        signals.append("target binary is missing")
                    }
                    if interpreters.contains(URL(filePath: program).lastPathComponent) {
                        signals.append("runs an interpreter (\(URL(filePath: program).lastPathComponent))")
                    }
                }
                signals += commandSignals(item.arguments.joined(separator: " "))
                if let created, Date().timeIntervalSince(created) < 7 * 86400 { signals.append("installed in the last 7 days") }

                var evidence = ["plist: \(FS.tildePath(url))", "label: \(item.label)",
                                "runs: \(item.arguments.isEmpty ? item.program ?? "?" : item.arguments.prefix(6).joined(separator: " "))",
                                "signer: \(signerNote ?? signer.label)"]
                if item.runAtLoad || item.keepAlive { evidence.append("starts \(item.runAtLoad ? "at login/boot" : "")\(item.keepAlive ? " and is kept alive" : "")") }
                if let created { evidence.append("created \(FS.ago(created))") }
                let level = signals.contains("target binary is missing") && signals.count == 1 ? .low : level(for: signals)
                out.append(AuditItem(id: "persistence:\(url.path)", kind: .persistence, title: item.label, evidence: evidence,
                                       signals: signals, severity: level, path: url, routine: signer == .apple && signals.isEmpty))
            }
        }
        if let cron = Shell.run("crontab", ["-l"]) {
            for line in cron.split(separator: "\n").map(String.init) where !line.trimmed.isEmpty && !line.hasPrefix("#") {
                let signals = commandSignals(line)
                out.append(AuditItem(id: "persistence:cron:\(line)", kind: .persistence, title: "crontab entry", evidence: [line],
                                       signals: signals, severity: signals.isEmpty ? .low : .high))
            }
        }
        for name in [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".bash_profile", ".bashrc", ".profile"] {
            let url = FS.home.appending(path: name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(line).trimmed
                guard !line.hasPrefix("#") else { continue }
                let signals = commandSignals(line)
                guard !signals.isEmpty else { continue }
                out.append(AuditItem(id: "persistence:\(url.path):\(n + 1)", kind: .persistence, title: "~/\(name) line \(n + 1)",
                                       evidence: [String(line.prefix(4000))], signals: signals, severity: .medium, path: url))
            }
        }
        if let items = FS.children(of: URL(filePath: "/Library/StartupItems")), !items.isEmpty {
            out.append(AuditItem(id: "persistence:/Library/StartupItems", kind: .persistence, title: "Legacy StartupItems",
                                   evidence: items.map(\.path), signals: ["deprecated persistence mechanism"], severity: .medium,
                                   path: URL(filePath: "/Library/StartupItems")))
        }
        return out
    }

    static func owner(_ path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.ownerAccountName] as? String ?? "?"
    }

    static func level(for signals: [String]) -> RiskLevel {
        let weights = signals.map { s in RiskSignal(rawValue: s)?.weight ?? 2 }
        switch weights.reduce(0, +) {
        case 0: return .none
        case 1...2: return .low
        case 3...4: return .medium
        default: return .high
        }
    }

    // MARK: Processes

    struct ProcessEntry: Sendable, Hashable {
        let pid: Int32
        let ppid: Int32
        let user: String
        let command: String
    }

    static func parsePS(_ text: String) -> [ProcessEntry] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { return nil }
            return ProcessEntry(pid: pid, ppid: ppid, user: String(parts[2]), command: String(parts[3]))
        }
    }

    static func processes(_ signatures: SignatureCache) async -> [AuditItem] {
        let entries = parsePS(Shell.run("ps", ["-axo", "pid=,ppid=,user=,comm="]) ?? "")
        var byPath: [String: [ProcessEntry]] = [:]
        var out: [AuditItem] = []
        for e in entries {
            guard let path = Lsof.executablePath(pid: e.pid) ?? (e.command.hasPrefix("/") ? e.command : nil) else { continue }
            // SIP-protected system locations can't hold third-party code.
            if ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/"].contains(where: path.hasPrefix) { continue }
            byPath[path, default: []].append(e)
        }
        for (path, procs) in byPath {
            var signals: [String] = []
            var signerLabel = "unknown"
            if !FileManager.default.fileExists(atPath: path) {
                signals.append("executable was deleted after launch")
            } else {
                let signer = await signatures.signer(for: path)
                if signer == .apple || path == ownExecutable { continue }
                signals += RiskSignal.binary(path: path, signer: signer).map(\.rawValue)
                if procs.contains(where: { $0.user == "root" }), FileManager.default.isWritableFile(atPath: path) {
                    signals.append("runs as root from a file your user account can modify")
                }
                guard !signals.isEmpty else { continue }
                signerLabel = signer.label
            }
            let first = procs[0]
            out.append(AuditItem(id: "process:\(path)", kind: .process, title: URL(filePath: path).lastPathComponent,
                                   evidence: ["executable: \(path)", "signer: \(signerLabel)", "pids: \(procs.map { String($0.pid) }.joined(separator: ", ")) (user \(first.user), parent \(first.ppid))"],
                                   signals: signals, severity: level(for: signals), pid: first.pid))
        }
        return out
    }

    // MARK: Network

    static func network(_ signatures: SignatureCache) async -> [AuditItem] {
        let connections = (try? Lsof.connections()) ?? []
        var grouped: [String: (Connection, String?, Signer, [RiskSignal], [String])] = [:]
        for c in connections {
            let path = Lsof.executablePath(pid: c.pid)
            let signer = path != nil ? await signatures.signer(for: path!) : .unknown
            let signals = RiskSignal.evaluate(c, exePath: path, signer: signer)
            guard RiskLevel(signals: signals) >= .medium else { continue }
            let key = path ?? c.command
            grouped[key, default: (c, path, signer, signals, [])].4.append(c.remote)
        }
        return grouped.map { key, g in
            let (c, path, signer, signals, remotes) = g
            return AuditItem(id: "network:\(key)", kind: .network, title: c.command,
                               evidence: ["executable: \(path ?? "unknown")", "signer: \(signer.label)",
                                          "remote: \(Array(Set(remotes)).sorted().prefix(8).joined(separator: ", "))"],
                               signals: signals.map(\.rawValue), severity: RiskLevel(signals: signals), pid: c.pid)
        }
    }

    // MARK: Interception

    /// Resolvers that are normal to see: private ranges, VPN/Tailscale, and big public resolvers.
    static func isExpectedResolver(_ ip: String) -> Bool {
        let known = ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112", "208.67.222.222", "208.67.220.220", "100.100.100.100"]
        return known.contains(ip) || Lsof.isPrivate(ip) || ip.hasPrefix("100.") || ip.lowercased().hasPrefix("fd") || ip.lowercased().hasPrefix("fe80")
    }

    static func interception(_ notes: inout [String]) -> [AuditItem] {
        var out: [AuditItem] = []
        if let proxy = Shell.run("scutil", ["--proxy"]) {
            let enabled = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable"].filter { proxy.contains("\($0) : 1") }
            if !enabled.isEmpty {
                let detail = proxy.split(separator: "\n").map { $0.trimmed }
                    .filter { ["HTTPProxy", "HTTPPort", "HTTPSProxy", "HTTPSPort", "SOCKSProxy", "SOCKSPort", "ProxyAutoConfigURLString"].contains(where: $0.hasPrefix) }
                out.append(AuditItem(id: "interception:proxy", kind: .interception, title: "System proxy is on",
                                       evidence: ["enabled: \(enabled.joined(separator: ", "))"] + detail,
                                       signals: ["all web traffic is routed through a proxy"], severity: .medium))
            }
        }
        if let dns = Shell.run("scutil", ["--dns"]) {
            let servers = Set(dns.split(separator: "\n").compactMap { line -> String? in
                guard line.contains("nameserver[") else { return nil }
                return line.split(separator: ":", maxSplits: 1).last.map { $0.trimmed }
            })
            let odd = servers.filter { !isExpectedResolver($0) }.sorted()
            if !odd.isEmpty {
                out.append(AuditItem(id: "interception:dns", kind: .interception, title: "Non-standard DNS resolvers",
                                       evidence: ["all resolvers: \(servers.sorted().joined(separator: ", "))", "unrecognised: \(odd.joined(separator: ", "))"],
                                       signals: ["DNS goes to a public resolver that isn't a well-known provider — could be your ISP, or a DNS changer"],
                                       severity: .low))
            }
        }
        if let hosts = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) {
            let defaults = ["localhost", "broadcasthost"]
            let custom = hosts.split(separator: "\n").map { $0.trimmed }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") && !defaults.contains(where: $0.hasSuffix) }
            if !custom.isEmpty {
                let redirects = custom.filter { line in !["127.", "0.0.0.0", "::1", "::"].contains(where: line.hasPrefix) }
                out.append(AuditItem(id: "interception:hosts", kind: .interception, title: "/etc/hosts has \(custom.count) custom entries",
                                       evidence: Array(custom.prefix(15)),
                                       signals: redirects.isEmpty ? ["entries only block domains (point to localhost)"] : ["\(redirects.count) entries redirect domains to other IPs"],
                                       severity: redirects.isEmpty ? .low : .high, path: URL(filePath: "/etc/hosts")))
            }
        }
        for (flag, domain) in [([], "user"), (["-d"], "admin")] {
            guard let dump = Shell.run("security", ["dump-trust-settings"] + flag) else { continue }
            for line in dump.split(separator: "\n") where line.hasPrefix("Cert ") {
                let name = line.split(separator: ":", maxSplits: 1).last.map { $0.trimmed } ?? String(line)
                out.append(AuditItem(id: "interception:cert:\(domain):\(name)", kind: .interception, title: "Trusted root: \(name)",
                                       evidence: ["custom trust setting in the \(domain) domain for certificate “\(name)”"],
                                       signals: ["a custom trusted root can decrypt and alter HTTPS traffic for every site"], severity: .medium))
            }
        }
        if let profiles = Shell.run("profiles", ["list"], anyStatus: true), !profiles.contains("no configuration profiles") {
            let lines = profiles.split(separator: "\n").map { $0.trimmed }.filter { $0.contains("profileIdentifier") || $0.contains("attribute") }
            if !lines.isEmpty {
                out.append(AuditItem(id: "interception:profiles", kind: .interception, title: "Configuration profiles installed",
                                       evidence: Array(lines.prefix(15)),
                                       signals: ["profiles can force proxies, DNS, root certificates and browser policies"], severity: .medium))
            }
        }
        if let mdm = Shell.run("profiles", ["status", "-type", "enrollment"], anyStatus: true), mdm.contains("MDM enrollment: Yes") {
            out.append(AuditItem(id: "interception:mdm", kind: .interception, title: "Mac is enrolled in MDM",
                                   evidence: [mdm.trimmed], signals: ["a remote administrator can manage this Mac"], severity: .low))
        }
        notes.append("System-wide configuration profiles need admin to list: `sudo profiles show`.")
        return out
    }

    // MARK: Remote access

    /// Tools used legitimately by IT, and constantly by tech-support and banking scammers.
    static let remoteTools = [
        "anydesk", "teamviewer", "screenconnect", "connectwisecontrol", "splashtop", "rustdesk", "logmein", "gotoassist",
        "goto resolve", "ultraviewer", "realvnc", "vnc server", "zoho assist", "supremo", "aeroadmin", "bomgar", "beyondtrust",
        "atera", "ninjarmm", "action1", "simplehelp", "remote utilities", "remotepc", "chrome remote desktop", "chromoting",
        "dwagent", "dwservice", "meshagent", "tacticalrmm", "kaseya", "parsec",
    ]

    static func matchesRemoteTool(_ name: String) -> String? {
        let lower = name.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let compact = lower.replacingOccurrences(of: " ", with: "")
        return remoteTools.first { lower.contains($0) || compact.contains($0.replacingOccurrences(of: " ", with: "")) }
    }

    static func remoteAccess() -> [AuditItem] {
        var found: [String: (installed: [String], running: [String], launch: [String])] = [:]
        for dir in [URL(filePath: "/Applications"), FS.home.appending(path: "Applications")] {
            for app in FS.children(of: dir) ?? [] where app.pathExtension == "app" {
                if let tool = matchesRemoteTool(app.lastPathComponent) { found[tool, default: ([], [], [])].installed.append(app.path) }
            }
        }
        for e in parsePS(Shell.run("ps", ["-axo", "pid=,ppid=,user=,comm="]) ?? "") {
            if let tool = matchesRemoteTool(URL(filePath: e.command).lastPathComponent) {
                found[tool, default: ([], [], [])].running.append("\(URL(filePath: e.command).lastPathComponent) (pid \(e.pid), \(e.user))")
            }
        }
        for dir in launchDirs {
            for plist in FS.children(of: dir) ?? [] {
                if let tool = matchesRemoteTool(plist.lastPathComponent) { found[tool, default: ([], [], [])].launch.append(FS.tildePath(plist)) }
            }
        }
        return found.map { tool, f in
            var evidence: [String] = []
            if !f.installed.isEmpty { evidence.append("installed: \(f.installed.joined(separator: ", "))") }
            if !f.launch.isEmpty { evidence.append("starts automatically via: \(f.launch.prefix(5).joined(separator: ", "))") }
            if !f.running.isEmpty { evidence.append("running now: \(Array(Set(f.running)).prefix(5).joined(separator: ", "))") }
            if f.installed.isEmpty && !f.launch.isEmpty { evidence.append("launch items remain but no app bundle was found") }
            let signals = ["remote-control software lets someone else see and drive this Mac"]
                + (f.running.isEmpty ? [] : ["currently running"]) + (f.launch.isEmpty ? [] : ["auto-starts"])
            return AuditItem(id: "remote:\(tool)", kind: .remoteAccess, title: tool.capitalized, evidence: evidence, signals: signals,
                               severity: f.running.isEmpty ? .medium : .high,
                               path: f.installed.first.map { URL(filePath: $0) })
        }
    }

    // MARK: Browser extensions

    static let browserRoots: [(String, String)] = [
        ("Chrome", "Google/Chrome"), ("Brave", "BraveSoftware/Brave-Browser"), ("Edge", "Microsoft Edge"),
        ("Arc", "Arc/User Data"), ("Vivaldi", "Vivaldi"), ("Chromium", "Chromium"),
    ]
    static let powerfulPermissions: Set<String> = [
        "webRequest", "webRequestBlocking", "declarativeNetRequest", "debugger", "proxy", "nativeMessaging",
        "cookies", "management", "clipboardRead", "history", "scripting", "tabCapture", "desktopCapture",
    ]

    static func browserExtensions() -> [AuditItem] {
        var out: [AuditItem] = []
        let support = FS.home.appending(path: "Library/Application Support")
        for (browser, rel) in browserRoots {
            let root = support.appending(path: rel)
            for profile in FS.children(of: root) ?? [] {
                let name = profile.lastPathComponent
                guard name == "Default" || name.hasPrefix("Profile ") else { continue }
                for ext in FS.children(of: profile.appending(path: "Extensions")) ?? [] {
                    guard let version = FS.children(of: ext)?.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first,
                          let data = try? Data(contentsOf: version.appending(path: "manifest.json")),
                          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    let perms = (manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
                    let hosts = (manifest["host_permissions"] as? [String] ?? [])
                        + ((manifest["content_scripts"] as? [[String: Any]])?.flatMap { $0["matches"] as? [String] ?? [] } ?? [])
                        + perms.filter { $0.contains("://") || $0 == "<all_urls>" }
                    let broad = hosts.contains { ["<all_urls>", "*://*/*", "http://*/*", "https://*/*"].contains($0) }
                    let powerful = perms.filter(powerfulPermissions.contains)
                    let update = manifest["update_url"] as? String
                    let storeURLs = ["clients2.google.com", "edge.microsoft.com"]
                    let sideloaded = update == nil || !storeURLs.contains { update!.contains($0) }
                    var signals: [String] = []
                    if broad { signals.append("can read and change data on all websites") }
                    if !powerful.isEmpty { signals.append("powerful permissions: \(powerful.joined(separator: ", "))") }
                    if sideloaded { signals.append("not installed from the browser's web store") }
                    let severity: RiskLevel = broad && sideloaded ? .high : broad && !powerful.isEmpty ? .medium : signals.isEmpty ? .none : .low
                    let title = extensionName(manifest, dir: version)
                    out.append(AuditItem(id: "browser:\(browser):\(name):\(ext.lastPathComponent)", kind: .browser,
                                           title: "\(title) (\(browser))",
                                           evidence: ["id: \(ext.lastPathComponent), version \(manifest["version"] as? String ?? "?"), profile \(name)",
                                                      "update source: \(update ?? "none")"],
                                           signals: signals, severity: severity, path: version, routine: severity == .none))
                }
            }
        }
        return out
    }

    static func extensionName(_ manifest: [String: Any], dir: URL) -> String {
        let raw = manifest["name"] as? String ?? "?"
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__") else { return raw }
        let key = String(raw.dropFirst(6).dropLast(2))
        let locale = manifest["default_locale"] as? String ?? "en"
        for loc in [locale, "en", "en_US"] {
            if let data = try? Data(contentsOf: dir.appending(path: "_locales/\(loc)/messages.json")),
               let msgs = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let entry = (msgs[key] ?? msgs.first(where: { $0.key.lowercased() == key.lowercased() })?.value) as? [String: Any],
               let message = entry["message"] as? String { return message }
        }
        return raw
    }

    // MARK: System & kernel extensions

    static func systemExtensions() -> [AuditItem] {
        var out: [AuditItem] = []
        for line in (Shell.run("systemextensionsctl", ["list"]) ?? "").split(separator: "\n") where line.contains("\t") && line.contains("[") {
            let cols = line.split(separator: "\t").map { $0.trimmed }
            guard cols.count >= 5, cols[2] != "teamID" else { continue }
            out.append(AuditItem(id: "sysext:\(cols[3])", kind: .systemExtension, title: cols[4],
                                   evidence: ["bundle: \(cols[3])", "team: \(cols[2])", "state: \(cols.last ?? "")"],
                                   signals: ["system extensions can filter network traffic or monitor the whole system"], severity: .low))
        }
        for line in (Shell.run("kmutil", ["showloaded", "--list-only"], timeout: 30) ?? "").split(separator: "\n") {
            guard let bundle = line.split(separator: " ").first(where: { $0.contains(".") && !$0.hasPrefix("0x") }),
                  !bundle.hasPrefix("com.apple.") else { continue }
            out.append(AuditItem(id: "kext:\(bundle)", kind: .systemExtension, title: String(bundle),
                                   evidence: [line.trimmed], signals: ["third-party kernel extension runs with full kernel privileges"], severity: .medium))
        }
        return out
    }

    // MARK: Privacy (TCC)

    static func privacy(_ notes: inout [String]) -> [AuditItem] {
        let db = "/Library/Application Support/com.apple.TCC/TCC.db"
        guard FileManager.default.isReadableFile(atPath: db) else {
            notes.append("Grant Full Disk Access to also list apps allowed to use Accessibility, Screen Recording and Input Monitoring.")
            return []
        }
        let services = [
            "kTCCServiceAccessibility": "Accessibility (can control the Mac)",
            "kTCCServiceScreenCapture": "Screen Recording",
            "kTCCServiceListenEvent": "Input Monitoring (keystrokes)",
            "kTCCServicePostEvent": "Synthetic input",
            "kTCCServiceSystemPolicyAllFiles": "Full Disk Access",
        ]
        let sql = "select service, client from access where auth_value = 2 and service in (\(services.keys.map { "'\($0)'" }.joined(separator: ",")))"
        var grants: [String: [String]] = [:]
        for line in (Shell.run("sqlite3", ["-separator", "|", db, sql]) ?? "").split(separator: "\n") {
            let cols = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard cols.count == 2, !cols[1].hasPrefix("com.apple.") else { continue }
            grants[cols[1], default: []].append(services[cols[0]] ?? cols[0])
        }
        return grants.map { client, perms in
            var signals: [String] = []
            if client.hasPrefix("/") { signals += RiskSignal.binary(path: client, signer: .unknown).map(\.rawValue) }
            if matchesRemoteTool(client) != nil { signals.append("remote-access tool with these permissions can watch and control the Mac") }
            return AuditItem(id: "privacy:\(client)", kind: .privacy, title: client, evidence: ["allowed: \(perms.sorted().joined(separator: ", "))"],
                               signals: signals, severity: signals.isEmpty ? .none : .high, routine: false)
        }
    }
}

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
