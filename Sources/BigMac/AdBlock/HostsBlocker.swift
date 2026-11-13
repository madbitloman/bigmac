import CryptoKit
import Foundation

/// System-wide blocking through /etc/hosts: every app that resolves names through macOS gets "no such server"
/// for ad and tracker hosts. It blocks whole servers only; page elements are the Safari blocker's job.
///
/// BigMac only ever touches its own block between the BEGIN and END markers, and only writes `0.0.0.0 <name>`
/// lines for names that pass `DomainNormalizer.isValidHost`, so nothing it installs can redirect a name elsewhere.
enum HostsBlocker {
    static let hostsPath = "/private/etc/hosts"
    static let beginPrefix = "# BEGIN BigMac ad blocking"
    static let endLine = "# END BigMac ad blocking"

    enum HostsError: LocalizedError {
        case malformed
        var errorDescription: String? {
            "/etc/hosts has a damaged BigMac block (a BEGIN or END line is missing or repeated). Fix it by hand first."
        }
    }

    struct Status: Equatable {
        var installed = false
        var entries = 0
        /// Fingerprint of the installed names, to tell whether the block matches the current settings.
        var fingerprint: String?
        var malformed = false
    }

    // MARK: Names

    /// The bundled StevenBlack list plus the built-in ad, tracker, pop-up and cookie-notice servers, minus the
    /// allowed sites and their subdomains. Every name is re-validated here, whatever the file says.
    static func names(allowed: [String], listURL: URL? = bundledList) -> [String] {
        var names = Set<String>()
        if let listURL, let text = try? String(contentsOf: listURL, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
                names.insert(String(line).trimmingCharacters(in: .whitespaces).lowercased())
            }
        }
        for name in FilterLists.adDomains + FilterLists.trackerDomains + FilterLists.popupDomains + FilterLists.annoyanceDomains {
            names.insert(name.lowercased())
        }
        let allowed = allowed.compactMap(DomainNormalizer.normalize)
        return names.filter { name in
            DomainNormalizer.isValidHost(name) && !allowed.contains { name == $0 || name.hasSuffix("." + $0) }
        }.sorted()
    }

    /// Resources/hosts-blocklist.txt in the app bundle, or in the checkout for unbundled debug runs.
    static var bundledList: URL? {
        let candidates = [Bundle.main.resourceURL?.appending(path: "hosts-blocklist.txt"),
                          URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "Resources/hosts-blocklist.txt")]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func fingerprint(_ names: [String]) -> String {
        SHA256.hash(data: Data(names.joined(separator: "\n").utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The block BigMac appends, markers included; empty for no names.
    static func block(for names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        let safe = names.filter(DomainNormalizer.isValidHost)
        return "\(beginPrefix) (\(fingerprint(safe))): managed by BigMac, turn it off in BigMac > Ad Blocking\n"
            + safe.map { "0.0.0.0 \($0)\n" }.joined() + endLine + "\n"
    }

    // MARK: Reading and splicing (pure, so the self-test can check them)

    static func status(of hosts: String) -> Status {
        let lines = hosts.split(separator: "\n", omittingEmptySubsequences: false)
        let begins = lines.filter { $0.hasPrefix(beginPrefix) }
        let ends = lines.filter { $0 == endLine }
        guard begins.count == ends.count, begins.count <= 1 else { return Status(malformed: true) }
        guard let begin = begins.first else { return Status() }
        let inside = managedLines(hosts)
        let fingerprint = begin.firstRange(of: /\(([0-9a-f]{12})\)/).map { String(begin[$0].dropFirst().dropLast()) }
        return Status(installed: true, entries: inside.count, fingerprint: fingerprint)
    }

    /// `hosts` without BigMac's block, then `block` (which may be empty, to turn blocking off).
    /// Mirrors the awk that root runs, so the self-test can check that applying twice changes nothing.
    static func splice(_ hosts: String, block: String) throws -> String {
        guard !status(of: hosts).malformed else { throw HostsError.malformed }
        var kept: [Substring] = []
        var skipping = false
        var lines = hosts.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        for line in lines {
            if line.hasPrefix(beginPrefix) { skipping = true }
            if !skipping { kept.append(line) }
            if line == endLine { skipping = false }
        }
        return kept.map { $0 + "\n" }.joined() + block
    }

    /// The `0.0.0.0 <name>` lines inside BigMac's block: the only lines the Security audit leaves out, so
    /// anything else slipped between the markers is still reported.
    static func managedLines(_ hosts: String) -> Set<String> {
        var out = Set<String>()
        var inside = false
        for line in hosts.split(separator: "\n") {
            if line.hasPrefix(beginPrefix) { inside = true; continue }
            if line == endLine { inside = false; continue }
            if inside, line.hasPrefix("0.0.0.0 "), DomainNormalizer.isValidHost(String(line.dropFirst(8))) {
                out.insert(String(line))
            }
        }
        return out
    }

    // MARK: Installing

    /// What root runs to drop the old block; the self-test checks it against `splice`.
    static let awkProgram = "index($0, \"\(beginPrefix)\") == 1 {s=1} !s {print} $0 == \"\(endLine)\" {s=0}"

    /// Replaces BigMac's block in /etc/hosts with one for `names` (none removes it), behind one admin prompt.
    /// Root copies the block into a folder only it can write, checks its SHA-256 against what BigMac wrote, and
    /// only then splices it in, so another process running as the user can't swap in its own entries.
    /// Blocks while the prompt is open: call off the main actor. Returns nil on success, else what went wrong.
    static func install(names: [String]) -> String? {
        let current = (try? String(contentsOfFile: hostsPath, encoding: .utf8)) ?? ""
        if status(of: current).malformed { return HostsError.malformed.errorDescription }
        let block = block(for: names)
        let dir = FileManager.default.temporaryDirectory.appending(path: "BigMac hosts \(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { return error.localizedDescription }
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "block")
        do { try Data(block.utf8).write(to: file) } catch { return error.localizedDescription }
        let hash = SHA256.hash(data: Data(block.utf8)).map { String(format: "%02x", $0) }.joined()

        let q = Removal.q
        let commands = [
            "set -e",
            "S=$(/usr/bin/mktemp -d /private/var/tmp/bigmac-hosts.XXXXXX)",
            "trap '/bin/rm -rf \"$S\"' EXIT",
            "/bin/cat < \(q(file.path)) > \"$S/block\"",
            // Each check exits on its own: set -e doesn't stop on a failed test inside an && list.
            "[ \"$(/usr/bin/shasum -a 256 \"$S/block\" | /usr/bin/cut -d ' ' -f 1)\" = \(q(hash)) ] || exit 1",
            "B=$(/usr/bin/grep -c \(q("^" + beginPrefix)) \(hostsPath) || true)",
            "E=$(/usr/bin/grep -cx \(q(endLine)) \(hostsPath) || true)",
            "[ \"$B\" = \"$E\" ] || exit 1",
            "[ \"$B\" -le 1 ] || exit 1",
            "/usr/bin/awk \(q(awkProgram)) \(hostsPath) > \"$S/hosts\"",
            "/bin/cat \"$S/block\" >> \"$S/hosts\"",
            // cat into the existing file keeps its owner (root:wheel) and mode (0644).
            "/bin/cat \"$S/hosts\" > \(hostsPath)",
            "/usr/bin/dscacheutil -flushcache",
            "/usr/bin/killall -HUP mDNSResponder || true",
        ]
        let script = "do shell script \"\(Removal.appleScriptEscape(commands.joined(separator: "\n")))\" with administrator privileges"
        if Shell.run("/usr/bin/osascript", ["-e", script], timeout: 120) == nil {
            let now = (try? String(contentsOfFile: hostsPath, encoding: .utf8)) ?? ""
            return now == current ? "Cancelled, or the admin script failed; /etc/hosts is unchanged." : nil
        }
        return nil
    }
}
