import CoreServices
import Foundation

struct AppInfo: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    let size: Int64
    /// nil means Spotlight has no record — "unknown", not "never used".
    let lastUsed: Date?
    let removable: Bool
    let leftovers: [URL]
    let leftoverSize: Int64

    var isApple: Bool { bundleID?.hasPrefix("com.apple.") ?? false }

    func isUnused(days: Int) -> Bool {
        guard let lastUsed else { return false }
        return lastUsed < Date().addingTimeInterval(-Double(days) * 86_400)
    }
}

enum AppScanner {
    static func scan() -> [AppInfo] {
        let roots = [URL(filePath: "/Applications"), FS.home.appending(path: "Applications")]
        var bundles: [URL] = []
        for root in roots {
            for kid in FS.children(of: root) ?? [] {
                if kid.pathExtension == "app" {
                    bundles.append(kid)
                } else if (try? kid.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // One level of folders, e.g. /Applications/Utilities or vendor folders.
                    bundles += (FS.children(of: kid) ?? []).filter { $0.pathExtension == "app" }
                }
            }
        }
        return bundles.map(info).sorted { $0.size > $1.size }
    }

    private static func info(_ url: URL) -> AppInfo {
        let bundle = Bundle(url: url)
        let bundleID = bundle?.bundleIdentifier
        let name = (bundle?.infoDictionary?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let leftovers = leftoverCandidates(bundleID: bundleID, name: url.deletingPathExtension().lastPathComponent)
        return AppInfo(
            url: url,
            name: name,
            bundleID: bundleID,
            version: bundle?.infoDictionary?["CFBundleShortVersionString"] as? String,
            size: FS.allocatedSize(of: url).bytes,
            lastUsed: lastUsedDate(url),
            removable: FileManager.default.isDeletableFile(atPath: url.path),
            leftovers: leftovers,
            leftoverSize: leftovers.reduce(0) { $0 + FS.allocatedSize(of: $1).bytes })
    }

    static func lastUsedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Support files apps commonly leave behind in ~/Library, matched by bundle ID or exact app name.
    static func leftoverCandidates(bundleID: String?, name: String) -> [URL] {
        // Don't guess at leftovers for Apple's own apps.
        if bundleID?.hasPrefix("com.apple.") ?? false { return [] }
        let lib = FS.home.appending(path: "Library")
        // Both come from the app's own bundle: a name like ".." or an ID like "../../Documents" must not escape ~/Library.
        let safeName = !name.isEmpty && !name.contains("/") && name != "." && name != ".."
        let safeID = bundleID.map { $0.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil } ?? false
        var paths: [String] = safeName ? ["Application Support/\(name)", "Logs/\(name)"] : []
        if let id = bundleID, safeID {
            paths += [
                "Application Support/\(id)", "Caches/\(id)", "Preferences/\(id).plist",
                "Containers/\(id)", "Saved Application State/\(id).savedState",
                "HTTPStorages/\(id)", "WebKit/\(id)", "Cookies/\(id).binarycookies",
            ]
        }
        return paths.map { lib.appending(path: $0) }.filter {
            $0.standardizedFileURL.path.hasPrefix(lib.path + "/") && FileManager.default.fileExists(atPath: $0.path)
        }
    }
}
