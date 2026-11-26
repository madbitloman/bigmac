import AppKit
import CryptoKit
import Foundation

/// The Chrome and Firefox extension inside BigMac.app (Contents/Resources/BrowserExtension, copied in by
/// scripts/bundle-browser-extension.sh with a SHA-256 list beside it), and the browsers it can go into.
/// Browsers only take an unpacked extension from a folder the user picks by hand, so BigMac copies it to a
/// folder that stays put across app updates and shows it in Finder; the browser's own page does the rest.
enum BrowserExtension {
    enum Engine: Sendable { case chromium, firefox }

    struct Browser: Identifiable, Sendable, Equatable {
        let id: String          // bundle identifier
        let name: String
        let engine: Engine
        /// The browser's extensions page; only the browser itself can open it.
        let extensionsPage: String
    }

    /// Browsers BigMac knows how to guide, by bundle identifier.
    static let knownBrowsers: [Browser] = [
        Browser(id: "com.google.Chrome", name: "Google Chrome", engine: .chromium, extensionsPage: "chrome://extensions"),
        Browser(id: "com.google.Chrome.canary", name: "Chrome Canary", engine: .chromium, extensionsPage: "chrome://extensions"),
        Browser(id: "com.brave.Browser", name: "Brave", engine: .chromium, extensionsPage: "brave://extensions"),
        Browser(id: "com.microsoft.edgemac", name: "Microsoft Edge", engine: .chromium, extensionsPage: "edge://extensions"),
        Browser(id: "company.thebrowser.Browser", name: "Arc", engine: .chromium, extensionsPage: "arc://extensions"),
        Browser(id: "org.mozilla.firefox", name: "Firefox", engine: .firefox, extensionsPage: "about:debugging#/runtime/this-firefox"),
        Browser(id: "org.mozilla.firefoxdeveloperedition", name: "Firefox Developer Edition", engine: .firefox,
                extensionsPage: "about:debugging#/runtime/this-firefox"),
        Browser(id: "org.mozilla.nightly", name: "Firefox Nightly", engine: .firefox, extensionsPage: "about:debugging#/runtime/this-firefox"),
    ]

    static func installedBrowsers() -> [Browser] {
        knownBrowsers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    // MARK: The bundled copy

    struct Bundled: Sendable, Equatable {
        let folder: URL
        let sums: URL
        let name: String
        let version: String
    }

    /// The copy inside the app, or build/BrowserExtension in a development run; nil when the app was built without it.
    static func bundled(resources: URL? = Bundle.main.resourceURL) -> Bundled? {
        var candidates: [URL] = []
        if let resources { candidates.append(resources) }
        candidates.append(URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "build"))
        for base in candidates {
            let folder = base.appending(path: "BrowserExtension"), sums = base.appending(path: "BrowserExtension.sha256")
            guard FileManager.default.fileExists(atPath: sums.path),
                  let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return Bundled(folder: folder, sums: sums,
                           name: manifest["name"] as? String ?? "Browser extension",
                           version: manifest["version"] as? String ?? "")
        }
        return nil
    }

    /// The SHA-256 list as (path, hash) pairs, from `shasum -a 256` output.
    static func parseSums(_ text: String) -> [(path: String, hash: String)] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].count == 64 else { return nil }
            return (String(parts[1]).trimmingCharacters(in: .whitespaces), String(parts[0]))
        }
    }

    /// Problems with `folder` against the SHA-256 list: missing, changed or unlisted files. Empty when it matches.
    static func verify(folder: URL, sums: URL) -> [String] {
        guard let text = try? String(contentsOf: sums, encoding: .utf8) else { return ["no file list"] }
        let listed = parseSums(text)
        guard !listed.isEmpty else { return ["empty file list"] }
        var problems: [String] = []
        for (path, hash) in listed {
            guard !path.contains(".."), let data = try? Data(contentsOf: folder.appending(path: path)) else {
                problems.append("missing \(path)"); continue
            }
            if SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() != hash { problems.append("changed \(path)") }
        }
        let names = Set(listed.map(\.path))
        let present = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1)) }
        // Chrome writes its indexed rules into the folder it loads, under _metadata (names starting with "_" are its own).
        problems += present.filter { !names.contains($0) && !$0.hasPrefix("_") }.sorted().map { "unlisted \($0)" }
        return problems
    }

    /// Every file a WebExtension manifest names: icons, the toolbar page, scripts, stylesheets and rule sets.
    static func referencedFiles(manifest: [String: Any]) -> [String] {
        var files: [String] = []
        func strings(_ value: Any?) -> [String] {
            switch value {
            case let text as String: [text]
            case let list as [Any]: list.flatMap { strings($0) }
            case let map as [String: Any]: map.keys.sorted().flatMap { strings(map[$0]) }
            default: []
            }
        }
        files += strings(manifest["icons"])
        if let action = manifest["action"] as? [String: Any] {
            files += strings(action["default_popup"]) + strings(action["default_icon"])
        }
        if let background = manifest["background"] as? [String: Any] {
            files += strings(background["service_worker"]) + strings(background["scripts"]) + strings(background["page"])
        }
        for script in manifest["content_scripts"] as? [[String: Any]] ?? [] {
            files += strings(script["js"]) + strings(script["css"])
        }
        let rules = (manifest["declarative_net_request"] as? [String: Any])?["rule_resources"] as? [[String: Any]] ?? []
        files += rules.flatMap { strings($0["path"]) }
        var seen = Set<String>()
        return files.filter { seen.insert($0).inserted }
    }

    // MARK: The folder the browsers load

    /// ~/Library/Application Support/BigMac/BrowserExtension: the same path after every BigMac update, since Chrome
    /// keys an unpacked extension (and its settings) to its folder.
    static var stableFolder: URL {
        URL.applicationSupportDirectory.appending(path: "BigMac/BrowserExtension")
    }

    /// Copies the bundled extension to `destination` unless an identical copy is already there, then checks it.
    /// Returns true when it copied (the browser needs a Reload to pick up the new version).
    @discardableResult
    static func install(_ bundled: Bundled, to destination: URL = stableFolder) throws -> Bool {
        let fm = FileManager.default
        let sums = destination.deletingLastPathComponent().appending(path: "BrowserExtension.sha256")
        let wanted = try Data(contentsOf: bundled.sums)
        if (try? Data(contentsOf: sums)) == wanted, verify(folder: destination, sums: sums).isEmpty { return false }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try? fm.removeItem(at: sums)
        try fm.copyItem(at: bundled.folder, to: destination)
        try wanted.write(to: sums)
        let problems = verify(folder: destination, sums: sums)
        guard problems.isEmpty else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The copied extension doesn't match: \(problems.prefix(3).joined(separator: ", "))"])
        }
        return true
    }

    /// Opens the browser's extensions page in that browser, and puts its address on the clipboard in case the
    /// browser ignores addresses handed to it from outside.
    static func openExtensionsPage(of browser: Browser) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(browser.extensionsPage, forType: .string)
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.id),
              let url = URL(string: browser.extensionsPage) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
