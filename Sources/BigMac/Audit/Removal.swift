import Foundation

/// Full removal of a launch item: stop it, then move the plist and what it installed to the Trash.
/// Everything goes to the Trash (root-owned files too, via one admin prompt), so it stays reversible until emptied.
struct RemovalPlan: Sendable {
    struct Target: Sendable, Identifiable, Hashable {
        var id: String { url.path }
        let url: URL
        let why: String
        /// Pre-ticked in the sheet; off for things that may belong to a bigger app.
        var selected = true
        var needsAdmin: Bool { !FileManager.default.isDeletableFile(atPath: url.path) }
    }

    let label: String
    let plist: URL
    let program: String?
    /// Runs as the user before anything is removed, e.g. a vendor's own "stop" that undoes its system changes.
    var preflight: (args: [String], why: String)?
    var targets: [Target]
}

enum Removal {
    /// Tools that change system state while running and have a documented way to hand it back.
    static let cleanupHooks: [(match: String, args: [String], why: String)] = [
        ("/co.palokaj.battery/", ["maintain", "stop"], "Stops the charge limiter and turns normal charging back on"),
    ]

    private static let systemPrefixes = ["/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/Library/Apple/"]
    private static let sharedDirs: Set<String> = [
        "/usr/local/bin", "/usr/local/sbin", "/usr/local", "/opt/homebrew/bin", "/opt/homebrew", "/Applications", "/Library",
        "/Library/Application Support", FS.home.path, FS.home.appending(path: "bin").path, FS.home.appending(path: ".local/bin").path,
        FS.home.appending(path: "Library").path, FS.home.appending(path: "Library/Application Support").path,
    ]
    private static let linkDirs = ["/usr/local/bin", "/opt/homebrew/bin", FS.home.appending(path: ".local/bin").path]

    static func plan(plist: URL) -> RemovalPlan? {
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let args = dict["ProgramArguments"] as? [String] ?? []
        let label = dict["Label"] as? String ?? plist.deletingPathExtension().lastPathComponent
        // For `sh script.sh` the interesting file is the script, not the shell.
        var program = dict["Program"] as? String ?? args.first
        if let p = program, systemPrefixes.contains(where: p.hasPrefix), let script = args.dropFirst().first(where: { $0.hasPrefix("/") }) {
            program = script
        }
        var targets = [RemovalPlan.Target(url: plist, why: "launch item")]
        var hook: (args: [String], why: String)?
        if let program, !systemPrefixes.contains(where: program.hasPrefix) {
            let url = URL(filePath: program)
            let name = url.lastPathComponent.lowercased()
            if let h = cleanupHooks.first(where: { program.contains($0.match) }), FileManager.default.isExecutableFile(atPath: program) {
                hook = (h.args, h.why)
            }
            // Inside an app bundle: offer the bundle, unticked, since a helper may belong to a bigger app.
            if let range = program.range(of: ".app/") {
                let bundle = URL(filePath: String(program[..<range.lowerBound]) + ".app")
                let dedicated = bundle.deletingPathExtension().lastPathComponent.lowercased() == name
                targets.append(.init(url: bundle, why: "app that contains the program", selected: dedicated))
            } else {
                let parent = url.deletingLastPathComponent()
                let tokens = Set(label.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) + [name])
                    .filter { $0.count >= 4 && !["com", "app", "helper", "agent", "daemon", "launch"].contains($0) }
                // A folder named after the tool (e.g. /usr/local/co.palokaj.battery) holds only its files.
                if !sharedDirs.contains(parent.path), tokens.contains(where: parent.lastPathComponent.lowercased().contains) {
                    targets.append(.init(url: parent, why: "folder the tool installed"))
                } else if FileManager.default.fileExists(atPath: program) {
                    targets.append(.init(url: url, why: "program it runs"))
                }
                let root = targets.last!.url.path
                for dir in linkDirs {
                    for link in FS.children(of: URL(filePath: dir)) ?? [] {
                        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), dest == root || dest.hasPrefix(root + "/") {
                            targets.append(.init(url: link, why: "command-line link"))
                        }
                    }
                }
                // Matching GUI app and sudoers rule left by the installer.
                for app in FS.children(of: URL(filePath: "/Applications")) ?? []
                where app.pathExtension == "app" && app.deletingPathExtension().lastPathComponent.lowercased() == name {
                    targets.append(.init(url: app, why: "app with the same name"))
                }
                let sudoers = URL(filePath: "/private/etc/sudoers.d").appending(path: url.lastPathComponent)
                if FileManager.default.fileExists(atPath: sudoers.path) {
                    targets.append(.init(url: sudoers, why: "passwordless sudo rule it installed"))
                }
            }
        }
        // Log/state folder, when it's a dedicated dot-folder in home (e.g. ~/.battery).
        for key in ["StandardOutPath", "StandardErrorPath"] {
            guard let path = dict[key] as? String else { continue }
            let dir = URL(filePath: path).deletingLastPathComponent()
            if dir.deletingLastPathComponent().path == FS.home.path, dir.lastPathComponent.hasPrefix("."),
               !targets.contains(where: { $0.url == dir }) {
                targets.append(.init(url: dir, why: "its logs and settings"))
            }
        }
        targets.removeAll { !isSafe($0.url) }
        return RemovalPlan(label: label, plist: plist, program: program, preflight: hook, targets: targets)
    }

    /// Top-level folders macOS and other software share; a tool's own folder is never one of their direct children.
    private static let sharedParents: Set<String> = ["/", "/Library", "/private", "/private/etc", "/private/var", "/Users", "/Volumes"]

    /// Safety net, checked when the plan is built and again right before root acts on it:
    /// never touch a shared or system location, whatever the plist says, and never through a symlinked parent.
    static func isSafe(_ url: URL) -> Bool {
        let lexical = url.standardizedFileURL
        // Resolve the parent only: a command-line link is itself a symlink and is moved as a link.
        let real = lexical.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: lexical.lastPathComponent)
        let p = real.path
        // /private/etc and /tmp resolve through Apple's own top-level links; anything else must already be real.
        guard p == lexical.path || p == "/private" + lexical.path else { return false }
        if p == "/" || sharedDirs.contains(p) || systemPrefixes.contains(where: p.hasPrefix) { return false }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue,
           sharedParents.contains(real.deletingLastPathComponent().path), !p.hasSuffix(".app") {
            return false
        }
        // FS protects all of /usr; third-party installs under /usr/local are fair game, nothing else protected is.
        return !FS.isProtected(real) || p.hasPrefix("/usr/local/")
    }

    /// `pkill -f` takes a regex over the whole command line; match the program path as a literal, whole argument.
    static func exactProgramPattern(_ program: String) -> String {
        let special = Set("\\^$.|?*+()[]{}")
        let escaped = program.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
        return "(^|[[:space:]])\(escaped)([[:space:]]|$)"
    }

    struct Outcome: Sendable {
        var removed: [URL] = []
        var failed: [(URL, String)] = []
        var log: [String] = []
        var cancelled = false
    }

    /// Stops the item and moves the selected targets to the Trash. Blocks while the admin prompt is open: call off the main actor.
    static func execute(_ plan: RemovalPlan, selected: Set<String>) -> Outcome {
        var out0 = Outcome()
        // Re-check now: files can change between opening the sheet and confirming it.
        let targets = plan.targets.filter { selected.contains($0.id) }.filter { t in
            if isSafe(t.url) { return true }
            out0.failed.append((t.url, "skipped: path changed or is not safe to remove"))
            return false
        }
        if let hook = plan.preflight, let program = plan.program {
            let ok = Shell.run(program, hook.args, timeout: 30, anyStatus: true) != nil
            out0.log.append("\(hook.why): \(ok ? "done" : "failed")")
        }
        let system = !plan.plist.path.hasPrefix(FS.home.path)
        var admin: [String] = []
        if system {
            admin.append("launchctl bootout system \(q(plan.plist.path)) 2>/dev/null")
        } else {
            _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", plan.plist.path], anyStatus: true)
        }
        var out = out0
        if let program = plan.program {
            let pattern = exactProgramPattern(program)
            _ = Shell.run("/usr/bin/pkill", ["-f", "--", pattern], anyStatus: true)
            admin.append("pkill -f -- \(q(pattern)) 2>/dev/null")
        }
        // Children before parents, so a link inside a folder isn't moved twice.
        let ordered = targets.sorted { $0.url.path.count > $1.url.path.count }
        var asRoot: [RemovalPlan.Target] = []
        for t in ordered {
            if t.needsAdmin { asRoot.append(t); continue }
            let result = FS.trash([(t.url, 0)])
            if result.trashed.isEmpty { asRoot.append(t) } else { out.removed.append(t.url) }
        }
        // Root moves into a fresh folder it creates itself (mktemp: random name, 0700), so nothing planted in the
        // user-writable Trash can redirect it; the folder is handed to the user only after the moves.
        let trash = FS.home.appending(path: ".Trash").path
        if !asRoot.isEmpty {
            admin.append("T=\(q(trash)); [ -d \"$T\" ] && [ ! -L \"$T\" ] && D=$(mktemp -d \"$T/BigMac removal.XXXXXX\") || exit 1")
            for (n, t) in asRoot.enumerated() {
                admin.append("mv -n -- \(q(t.url.path)) \"$D/\"\(q("\(n + 1) \(t.url.lastPathComponent)"))")
            }
            admin.append("chown \(getuid()) \"$D\"")
        }
        if !asRoot.isEmpty || system {
            let script = "do shell script \"\(appleScriptEscape(admin.joined(separator: "; ") + "; true"))\" with administrator privileges"
            if Shell.run("/usr/bin/osascript", ["-e", script], timeout: 300) == nil { out.cancelled = true }
        }
        for t in asRoot {
            if FileManager.default.fileExists(atPath: t.url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: t.url.path)) != nil {
                out.failed.append((t.url, out.cancelled ? "admin password prompt was cancelled" : "still there"))
            } else {
                out.removed.append(t.url)
            }
        }
        return out
    }

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
