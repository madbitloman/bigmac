import CryptoKit
import Foundation

struct DuplicateGroup: Identifiable, Sendable {
    let id: String  // full-content SHA256
    let size: Int64
    let files: [URL]
    var wasted: Int64 { size * Int64(files.count - 1) }
}

/// Finds byte-identical files: group by size → hash of first 64 KB → full SHA256.
/// Hardlinks (same inode) are collapsed so they don't count as reclaimable space.
enum DuplicateFinder {
    static func find(roots: [URL], minSize: Int64 = 1024 * 1024, progress: @Sendable (String) -> Void = { _ in }) -> [DuplicateGroup] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var bySize: [Int64: [URL]] = [:]
        var scanned = 0

        for root in roots {
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true })
            while let url = enumerator?.nextObject() as? URL {
                guard let v = try? url.resourceValues(forKeys: keys),
                      v.isRegularFile == true, v.isSymbolicLink != true,
                      let size = v.fileSize, Int64(size) >= minSize else { continue }
                bySize[Int64(size), default: []].append(url)
                scanned += 1
                if scanned % 500 == 0 { progress("Indexed \(scanned) files…") }
            }
        }

        var groups: [DuplicateGroup] = []
        let candidates = bySize.filter { $0.value.count > 1 }
        progress("Hashing \(candidates.values.reduce(0) { $0 + $1.count }) candidate files…")

        for (size, urls) in candidates {
            let unique = uniqueInodes(urls)
            guard unique.count > 1 else { continue }
            let byPartial = Dictionary(grouping: unique) { hash($0, limit: 64 * 1024) ?? UUID().uuidString }
            for (_, sameStart) in byPartial where sameStart.count > 1 {
                let byFull = Dictionary(grouping: sameStart) { hash($0, limit: nil) ?? UUID().uuidString }
                for (digest, same) in byFull where same.count > 1 {
                    groups.append(DuplicateGroup(id: digest, size: size, files: same.sorted { $0.path < $1.path }))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    private static func uniqueInodes(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return false }
            return seen.insert("\(st.st_dev):\(st.st_ino)").inserted
        }
    }

    /// SHA256 of the first `limit` bytes (or the whole file), streamed in 1 MB chunks.
    static func hash(_ url: URL, limit: Int?) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let chunk = min(remaining, 1024 * 1024)
            guard let data = try? handle.read(upToCount: chunk), !data.isEmpty else { break }
            hasher.update(data: data)
            remaining -= data.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
