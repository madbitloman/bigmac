import Foundation

/// Filesystem helpers shared by the scanners. Everything here is read-only except `trash`.
enum FS {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Paths we never touch, no matter what a scanner or the user selects.
    private static let protectedPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/private/var/db", "/Library/Apple",
        "/Library/Extensions", "/Library/Frameworks",
    ]

    static func isProtected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path == "/" || path == home.path { return true }
        if protectedPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        // Never delete something *inside* an app bundle or a photo/mail library.
        for marker in [".app/", ".photoslibrary/", "/Library/Mail/"] where path.contains(marker) {
            return true
        }
        return false
    }

    /// True when no folder above `url` is a symlink, so the path is what it looks like.
    /// macOS's own top-level links (/tmp, /var, /etc → /private/…) count as real.
    static func parentIsReal(_ url: URL) -> Bool {
        let lexical = url.standardizedFileURL.deletingLastPathComponent().path
        let real = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        return real == lexical || real == "/private" + lexical || "/private" + real == lexical
    }

    /// A folder that is really there: not itself a symlink, and not reached through one.
    /// Scanners only list what's inside such folders, so a planted link can't make them list somewhere else.
    static func isRealDirectory(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              v.isSymbolicLink != true, v.isDirectory == true else { return false }
        return parentIsReal(url)
    }

    final class ErrorFlag: @unchecked Sendable { var hit = false }

    /// Allocated size on disk, plus whether any part of the tree was unreadable.
    static func allocatedSize(of url: URL) -> (bytes: Int64, denied: Bool) {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (0, true) }
        if values.isSymbolicLink == true { return (0, false) }
        if values.isDirectory != true { return (Int64(values.totalFileAllocatedSize ?? 0), false) }

        let flag = ErrorFlag()
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, _ in flag.hit = true; return true })
        while let child = enumerator?.nextObject() as? URL {
            if let v = try? child.resourceValues(forKeys: keys), v.isSymbolicLink != true {
                total += Int64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return (total, flag.hit)
    }

    /// Direct children, or nil if the directory exists but can't be read (usually missing Full Disk Access).
    static func children(of url: URL, keys: [URLResourceKey] = []) -> [URL]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
    }

    struct TrashResult: Sendable {
        var freed: Int64 = 0
        var trashed: [URL] = []
        var failures: [(URL, String)] = []
    }

    static let trashDir = home.appending(path: ".Trash")

    static func isInTrash(_ url: URL) -> Bool { url.standardizedFileURL.path.hasPrefix(trashDir.path + "/") }

    /// Moves items to the Trash (recoverable). Items already in the Trash are deleted permanently,
    /// since "trashing" them again would free nothing. Protected paths are refused.
    static func trash(_ items: [(url: URL, size: Int64)]) -> TrashResult {
        var result = TrashResult()
        for item in items {
            if isProtected(item.url) {
                result.failures.append((item.url, "protected path"))
                continue
            }
            // Never act through a symlinked folder: the item would really be somewhere other than where it was shown.
            if !parentIsReal(item.url) {
                result.failures.append((item.url, "skipped: a folder above it is a symlink"))
                continue
            }
            do {
                if isInTrash(item.url) {
                    try FileManager.default.removeItem(at: item.url)
                } else {
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                }
                result.freed += item.size
                result.trashed.append(item.url)
            } catch {
                result.failures.append((item.url, error.localizedDescription))
            }
        }
        return result
    }

    static func tildePath(_ url: URL) -> String {
        let path = url.path
        return path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
