import AppKit
import Foundation

// MARK: - Shared helpers

enum Shell {
    /// Runs a tool (name or absolute path) with a sane PATH (GUI apps don't inherit the shell's).
    /// Returns stdout, or nil on failure; `anyStatus` keeps stdout from tools that report state via exit code.
    /// SIP-protected system dirs come first, so a same-named binary dropped into Homebrew can't stand in for `ps` or `sqlite3`.
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 20, anyStatus: Bool = false) -> String? {
        let dirs = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]
        let candidates = tool.hasPrefix("/") ? [tool] : dirs.map { "\($0)/\(tool)" }
        guard let path = candidates.first(where: FileManager.default.isExecutableFile) else { return nil }
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = dirs.joined(separator: ":")
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return process.terminationStatus == 0 || anyStatus ? String(decoding: data, as: UTF8.self) : nil
    }

    static func succeeds(_ tool: String, _ args: [String]) -> Bool {
        run(tool, args, timeout: 8) != nil
    }

    static func isRunning(_ processName: String) -> Bool {
        run("pgrep", ["-x", processName]) != nil
    }
}

extension FS {
    /// Comparable path: standardized, symlinks resolved, no trailing slash.
    static func key(_ url: URL) -> String {
        let p = url.resolvingSymlinksInPath().standardizedFileURL.path
        return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    /// Most recent modification of the item or anything under it (bounded walk).
    static func lastWrite(_ url: URL, limit: Int = 50_000) -> Date? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        var newest = (try? url.resourceValues(forKeys: keys))?.contentModificationDate
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        var seen = 0
        while seen < limit, let child = enumerator?.nextObject() as? URL {
            seen += 1
            if let d = (try? child.resourceValues(forKeys: keys))?.contentModificationDate, d > (newest ?? .distantPast) { newest = d }
        }
        return newest
    }

    /// Heuristic: TCC.db is only readable with Full Disk Access.
    static var hasFullDiskAccess: Bool {
        FileManager.default.isReadableFile(atPath: home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db").path)
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        return date.formatted(.relative(presentation: .named))
    }
}

// MARK: - Screenshots

enum ScreenshotScanner {
    static let mediaExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "mov", "mp4"]
    static let namePrefixes = ["Screenshot", "Screen Shot", "Screen Recording", "CleanShot", "Снимок экрана", "Запись экрана", "Знімок екрана"]

    /// Where macOS saves screenshots (`defaults read com.apple.screencapture location`), default ~/Desktop.
    static var location: URL {
        if let raw = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String, !raw.isEmpty {
            return URL(filePath: (raw as NSString).expandingTildeInPath)
        }
        return FS.home.appending(path: "Desktop")
    }

    static func scan() -> CategoryResult {
        var result = CategoryResult()
        let desktop = FS.home.appending(path: "Desktop")
        let dedicated = FS.key(location) != FS.key(desktop)
        var folders = [(location, dedicated)]
        if dedicated { folders.append((desktop, false)) }  // older screenshots often still sit on the Desktop

        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        for (folder, takeAllMedia) in folders {
            guard let files = FS.children(of: folder, keys: keys) else { result.denied = true; continue }
            for file in files where mediaExtensions.contains(file.pathExtension.lowercased()) {
                let name = file.lastPathComponent
                guard takeAllMedia || namePrefixes.contains(where: name.hasPrefix) else { continue }
                let v = try? file.resourceValues(forKeys: Set(keys))
                guard v?.isRegularFile == true else { continue }
                let created = v?.creationDate
                result.items.append(JunkItem(url: file, category: .screenshots, size: FS.allocatedSize(of: file).bytes,
                                             detail: "taken \(FS.ago(created))", date: created))
            }
        }
        result.items.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }  // oldest first
        result.note = "Saved to \(FS.tildePath(location))"
        return result
    }
}

// MARK: - Orphaned app data

/// Support data in ~/Library whose bundle ID no installed app owns, untouched for `staleDays`.
enum OrphanScanner {
    static func scan(staleDays: Int = 30) -> CategoryResult {
        var result = CategoryResult()
        let lib = FS.home.appending(path: "Library")
        let installed = Set(AppScanner.scan().compactMap(\.bundleID))
        let cutoff = Date().addingTimeInterval(-Double(staleDays) * 86_400)
        var folders = ["Application Support", "Preferences", "Saved Application State", "HTTPStorages", "WebKit"]
        // Sizing other apps' containers triggers a privacy prompt per app unless we have Full Disk Access.
        if FS.hasFullDiskAccess { folders.insert("Containers", at: 0) } else { result.note = "Grant Full Disk Access to also check app containers" }

        for folder in folders {
            guard let kids = FS.children(of: lib.appending(path: folder)) else { result.denied = true; continue }
            for kid in kids {
                guard let id = bundleID(from: kid.lastPathComponent), !isOwned(id, installed: installed) else { continue }
                let touched = FS.lastWrite(kid, limit: 5_000)
                guard (touched ?? .distantPast) < cutoff else { continue }
                let (size, _) = FS.allocatedSize(of: kid)
                result.items.append(JunkItem(url: kid, category: .orphanedAppData, size: size,
                                             detail: "\(folder) · no installed app · last used \(FS.ago(touched))", date: touched))
            }
        }
        result.items.sort { $0.size > $1.size }
        return result
    }

    /// "com.vendor.app(.plist|.savedState|.binarycookies)" → "com.vendor.app"; nil if it doesn't look like a bundle ID.
    static func bundleID(from name: String) -> String? {
        var id = name
        for ext in [".plist", ".savedState", ".binarycookies"] where id.hasSuffix(ext) { id = String(id.dropLast(ext.count)) }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }) else { return nil }
        return id
    }

    static func isOwned(_ id: String, installed: Set<String>) -> Bool {
        let lower = id.lowercased()
        if lower.hasPrefix("com.apple.") || lower.hasPrefix("group.") { return true }
        // Helpers/extensions (com.foo.app.helper, com.foo.app-launcher) and parents (com.foo) of installed apps count as owned.
        if installed.contains(where: { let i = $0.lowercased(); return lower.hasPrefix(i) || i.hasPrefix(lower + ".") }) {
            return true
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }
}

// MARK: - Local databases

enum DatabaseScanner {
    struct Engine: Sendable {
        let name: String
        let process: String
        let globs: [String]  // directory patterns; trailing * matches a name prefix
        let lockFiles: [String]
    }

    static let engines: [Engine] = [
        Engine(name: "PostgreSQL", process: "postgres",
               globs: ["/opt/homebrew/var/postgresql*", "/opt/homebrew/var/postgres", "/usr/local/var/postgresql*", "/usr/local/var/postgres",
                       "~/Library/Application Support/Postgres/var-*"],
               lockFiles: ["postmaster.pid"]),
        Engine(name: "MySQL/MariaDB", process: "mysqld", globs: ["/opt/homebrew/var/mysql", "/usr/local/var/mysql"], lockFiles: []),
        Engine(name: "MongoDB", process: "mongod", globs: ["/opt/homebrew/var/mongodb", "/usr/local/var/mongodb"], lockFiles: []),
        Engine(name: "Redis", process: "redis-server", globs: ["/opt/homebrew/var/db/redis", "/usr/local/var/db/redis"], lockFiles: []),
    ]

    static func scan() -> CategoryResult {
        var result = CategoryResult()
        for engine in engines {
            let dirs = engine.globs.flatMap(expand)
            guard !dirs.isEmpty else { continue }
            let processUp = Shell.isRunning(engine.process)
            for dir in dirs {
                let locked = engine.lockFiles.contains { FileManager.default.fileExists(atPath: dir.appending(path: $0).path) }
                // Postgres has a per-cluster pid file; other engines only tell us the server process is up.
                let running = engine.lockFiles.isEmpty ? processUp : (locked && processUp)
                let (size, denied) = FS.allocatedSize(of: dir)
                if denied { result.denied = true }
                let touched = FS.lastWrite(dir)
                result.items.append(JunkItem(
                    url: dir, category: .localDatabases, size: size,
                    detail: "\(engine.name) · \(running ? "running" : "stopped") · last write \(FS.ago(touched))",
                    date: touched, blocked: running ? "Stop \(engine.name) before removing its data" : nil))
            }
        }
        result.items.sort { $0.size > $1.size }
        if result.items.isEmpty { result.note = "No Homebrew / Postgres.app data folders found" }
        return result
    }

    private static func expand(_ pattern: String) -> [URL] {
        let full = (pattern as NSString).expandingTildeInPath
        guard full.hasSuffix("*") else { return FileManager.default.fileExists(atPath: full) ? [URL(filePath: full)] : [] }
        let parent = URL(filePath: (full as NSString).deletingLastPathComponent)
        let prefix = String((full as NSString).lastPathComponent.dropLast())
        return (FS.children(of: parent) ?? []).filter { $0.lastPathComponent.hasPrefix(prefix) }
    }
}

// MARK: - Docker

enum DockerRef: Sendable, Hashable {
    case container(String), image(String), volume(String), buildCache
}

enum DockerScanner {
    static func scan() -> CategoryResult {
        var result = CategoryResult()
        guard Shell.run("docker", ["version", "--format", "{{.Server.Version}}"], timeout: 8) != nil else {
            result.note = "Docker isn't running — start it to scan containers, images and volumes"
            return result
        }

        // Stopped / never-started containers.
        for line in lines(Shell.run("docker", ["ps", "-a", "--size", "--filter", "status=exited", "--filter", "status=created",
                                               "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Size}}\t{{.Status}}"])) {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 5 else { continue }
            result.items.append(item(.container(f[0]), "container/\(f[1])", size: parseSize(f[3]),
                                     detail: "Stopped container from \(f[2]) · \(f[4])", review: true))
        }

        // Images no container (running or stopped) uses. Layers can be shared, so sizes may overlap.
        let usedImages = Set(lines(Shell.run("docker", ["ps", "-aq"])).flatMap { id in
            lines(Shell.run("docker", ["inspect", "--format", "{{.Image}}", id]))
        })
        for line in lines(Shell.run("docker", ["images", "--no-trunc", "--format", "{{.ID}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}"])) {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 4, !usedImages.contains(f[0]) else { continue }
            let dangling = f[1].hasPrefix("<none>")
            result.items.append(item(.image(f[0]), "image/\(dangling ? String(f[0].suffix(12)) : f[1])", size: parseSize(f[2]),
                                     detail: dangling ? "Dangling image · created \(f[3])" : "Unused image · created \(f[3])",
                                     review: !dangling))
        }

        // Volumes no container references. They usually hold database data, so always review.
        for name in lines(Shell.run("docker", ["volume", "ls", "-q", "--filter", "dangling=true"])) {
            result.items.append(item(.volume(name), "volume/\(name)", size: 0, detail: "Unattached volume (may hold data)", review: true))
        }

        // Build cache (always regenerable).
        for line in lines(Shell.run("docker", ["system", "df", "--format", "{{.Type}}\t{{.Reclaimable}}"])) {
            let f = line.components(separatedBy: "\t")
            if f.count == 2, f[0] == "Build Cache", parseSize(f[1]) > 0 {
                result.items.append(item(.buildCache, "build-cache", size: parseSize(f[1]), detail: "Reclaimable build cache", review: false))
            }
        }
        result.items.sort { $0.size > $1.size }
        if result.items.isEmpty { result.note = "Nothing unused in Docker" }
        return result
    }

    static func remove(_ ref: DockerRef) -> Bool {
        switch ref {
        case .container(let id): Shell.run("docker", ["rm", id]) != nil
        case .image(let id): Shell.run("docker", ["rmi", id]) != nil
        case .volume(let name): Shell.run("docker", ["volume", "rm", name]) != nil
        case .buildCache: Shell.run("docker", ["builder", "prune", "-f"], timeout: 120) != nil
        }
    }

    private static func item(_ ref: DockerRef, _ name: String, size: Int64, detail: String, review: Bool) -> JunkItem {
        JunkItem(url: URL(string: "docker:/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name))!,
                 category: .docker, size: size, detail: detail, review: review, docker: ref)
    }

    private static func lines(_ s: String?) -> [String] {
        (s ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Docker sizes: "12.3kB", "1.2GB (virtual 3GB)", "512MB (40%)" — decimal units, first token wins.
    static func parseSize(_ s: String) -> Int64 {
        let token = s.split(separator: " ").first.map(String.init) ?? ""
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, mult) in units where token.hasSuffix(suffix) {
            return Int64((Double(token.dropLast(suffix.count)) ?? 0) * mult)
        }
        return 0
    }
}
