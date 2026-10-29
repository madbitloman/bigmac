import Foundation

enum JunkCategory: String, CaseIterable, Sendable, Identifiable {
    case userCaches, logs, developer, packageCaches, docker, trash, screenshots, orphanedAppData, localDatabases, oldDownloads, largeFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userCaches: "App caches"
        case .logs: "Logs & crash reports"
        case .developer: "Xcode & simulator junk"
        case .packageCaches: "Package manager caches"
        case .docker: "Docker (unused)"
        case .trash: "Trash"
        case .screenshots: "Screenshots & recordings"
        case .orphanedAppData: "Leftovers of removed apps"
        case .localDatabases: "Local databases"
        case .oldDownloads: "Old downloads (90+ days)"
        case .largeFiles: "Large files (500 MB+)"
        }
    }

    var symbol: String {
        switch self {
        case .userCaches: "archivebox"
        case .logs: "doc.text"
        case .developer: "hammer"
        case .packageCaches: "shippingbox"
        case .docker: "cube.box"
        case .trash: "trash"
        case .screenshots: "camera.viewfinder"
        case .orphanedAppData: "questionmark.folder"
        case .localDatabases: "cylinder.split.1x2"
        case .oldDownloads: "arrow.down.circle"
        case .largeFiles: "externaldrive"
        }
    }

    /// Regenerable data is safe to clean; these hold user files or state and need a human look.
    var isUserData: Bool { [.screenshots, .orphanedAppData, .localDatabases, .oldDownloads, .largeFiles].contains(self) }
}

struct JunkItem: Identifiable, Sendable, Hashable {
    var id: URL { url }
    let url: URL
    let category: JunkCategory
    let size: Int64
    var detail: String? = nil
    var date: Date? = nil
    /// Set when the item must not be removed right now (e.g. a running database).
    var blocked: String? = nil
    /// Per-item "needs a human look", on top of the category default.
    var review = false
    var docker: DockerRef? = nil

    var needsReview: Bool { review || category.isUserData }
    var displayPath: String { docker != nil ? url.path.removingPercentEncoding ?? url.path : FS.tildePath(url) }
}

struct CategoryResult: Sendable {
    var items: [JunkItem] = []
    var denied = false
    var note: String? = nil
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

enum JunkScanner {
    private static let home = FS.home

    static func scan(_ category: JunkCategory) -> CategoryResult {
        switch category {
        case .userCaches:
            return childrenOf([home.appending(path: "Library/Caches")], category)
        case .logs:
            return childrenOf([
                home.appending(path: "Library/Logs"),
                home.appending(path: "Library/Logs/DiagnosticReports"),
            ], category)
        case .developer:
            return childrenOf([
                home.appending(path: "Library/Developer/Xcode/DerivedData"),
                home.appending(path: "Library/Developer/Xcode/iOS DeviceSupport"),
                home.appending(path: "Library/Developer/Xcode/watchOS DeviceSupport"),
                home.appending(path: "Library/Developer/CoreSimulator/Caches"),
            ], category)
        case .packageCaches:
            return wholeDirs([
                home.appending(path: ".npm/_cacache"),
                home.appending(path: ".yarn/berry/cache"),
                home.appending(path: ".pnpm-store"),
                home.appending(path: ".gradle/caches"),
                home.appending(path: ".cache/pip"),
                home.appending(path: ".cocoapods/repos"),
                home.appending(path: "Library/Caches/CocoaPods"),
            ], category)
        case .docker:
            return DockerScanner.scan()
        case .trash:
            return childrenOf([home.appending(path: ".Trash")], category)
        case .screenshots:
            return ScreenshotScanner.scan()
        case .orphanedAppData:
            return OrphanScanner.scan()
        case .localDatabases:
            return DatabaseScanner.scan()
        case .oldDownloads:
            return oldDownloads()
        case .largeFiles:
            return largeFiles(minBytes: 500 * 1024 * 1024)
        }
    }

    /// Each child of the given folders becomes one cleanable item.
    private static func childrenOf(_ dirs: [URL], _ category: JunkCategory) -> CategoryResult {
        var result = CategoryResult()
        var seen = Set<String>()
        let scannedDirs = Set(dirs.map(FS.key))
        for dir in dirs {
            guard let kids = FS.children(of: dir) else { result.denied = true; continue }
            for kid in kids where seen.insert(FS.key(kid)).inserted {
                // DiagnosticReports is scanned on its own; don't count it twice inside Logs.
                if scannedDirs.contains(FS.key(kid)) { continue }
                let (size, denied) = FS.allocatedSize(of: kid)
                if denied { result.denied = true }
                if size > 0 { result.items.append(JunkItem(url: kid, category: category, size: size)) }
            }
        }
        result.items.sort { $0.size > $1.size }
        return result
    }

    private static func wholeDirs(_ dirs: [URL], _ category: JunkCategory) -> CategoryResult {
        var result = CategoryResult()
        for dir in dirs where FileManager.default.fileExists(atPath: dir.path) {
            let (size, denied) = FS.allocatedSize(of: dir)
            if denied { result.denied = true }
            if size > 0 { result.items.append(JunkItem(url: dir, category: category, size: size)) }
        }
        result.items.sort { $0.size > $1.size }
        return result
    }

    private static func oldDownloads(olderThanDays days: Int = 90) -> CategoryResult {
        var result = CategoryResult()
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        guard let kids = FS.children(of: home.appending(path: "Downloads"), keys: keys) else {
            result.denied = true
            return result
        }
        for kid in kids where !kid.lastPathComponent.hasPrefix(".") {
            let v = try? kid.resourceValues(forKeys: Set(keys))
            let date = v?.addedToDirectoryDate ?? v?.contentModificationDate ?? .distantFuture
            guard date < cutoff else { continue }
            let (size, _) = FS.allocatedSize(of: kid)
            result.items.append(JunkItem(url: kid, category: .oldDownloads, size: size))
        }
        result.items.sort { $0.size > $1.size }
        return result
    }

    /// Big files in the home folder, outside ~/Library and app/photo packages.
    private static func largeFiles(minBytes: Int64) -> CategoryResult {
        var result = CategoryResult()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        let flag = FS.ErrorFlag()
        let skip: Set<String> = ["Library", ".Trash"].map { home.appending(path: $0).path }.reduce(into: []) { $0.insert($1) }
        let enumerator = FileManager.default.enumerator(
            at: home, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in flag.hit = true; return true })
        while let url = enumerator?.nextObject() as? URL {
            if skip.contains(url.path) { enumerator?.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            let size = Int64(v.totalFileAllocatedSize ?? 0)
            if size >= minBytes { result.items.append(JunkItem(url: url, category: .largeFiles, size: size)) }
        }
        result.items.sort { $0.size > $1.size }
        return result
    }
}
