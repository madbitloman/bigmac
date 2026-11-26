import Foundation

/// What BigMac needs from its blocking engine. The engine's shared code
/// isn't in this repository: `scripts/fetch-blocker-sources.sh` copies it into
/// Sources/BigMac/AdBlock/Engine (gitignored) together with `Support/BlockerEngine/Included.swift`, which
/// implements this on top of it. Without the engine's source the script puts in
/// `Support/BlockerEngine/NotIncluded.swift` instead: the app builds and runs, and the Ad & Pop-up Blocking
/// pane says ad blocking isn't included in this build.
///
/// Both files declare `enum BlockerEngine: BlockerEngineAPI`, so the compiler holds each to this contract.
protocol BlockerEngineAPI {
    /// False in a build without the engine. Nothing else here then does anything useful.
    static var included: Bool { get }

    /// Whatever someone typed or pasted ("https://www.Example.com/page") as a bare lowercase domain, or nil.
    static func normalize(_ input: String) -> String?

    /// Ad, tracker, pop-up and cookie-notice servers for the system-wide hosts block.
    static var hostsDomains: [String] { get }

    /// Sign-in and payment sites whose windows strict pop-up blocking still lets open.
    static var popupAllowedDomains: [String] { get }

    /// The rule `url-filter` that matches a domain and its subdomains.
    static func urlFilter(forDomain domain: String) -> String

    /// The filter lists a filter manifest (manifest.json) describes.
    static func filterLists(manifest: Data) -> [FilterListInfo]

    /// How many rules Safari gets for these settings: the built-in ones plus the lists in the manifest.
    static func ruleCount(for settings: SafariSettings, manifest: Data) -> Int

    /// Writes Safari's rule list for these settings, with the lists from `lists` (the folder holding the
    /// manifest's files), and returns its rule count. With nothing to block the file holds one rule that matches
    /// nothing (Safari refuses an empty list) and the count is 0.
    @discardableResult
    static func writeRules(for settings: SafariSettings, manifest: Data, lists: URL, to file: URL) throws -> Int
}

/// One filter list in the content blocker, as the pane credits it.
struct FilterListInfo: Identifiable, Sendable {
    var id: String
    var title: String
    var version: String
    var homepage: String
    var license: String
    var ruleCount: Int
}

extension BlockerEngineAPI {
    /// A site name another process sent (the toolbar button of the web extension, through its background script):
    /// a bare domain only, never a URL, path, port or user, at most 253 characters. Normalised, or nil.
    static func siteName(from value: Any?) -> String? {
        guard let text = value as? String, (1...253).contains(text.utf8.count),
              text.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") })
        else { return nil }
        return normalize(text)
    }
}

// If the next line doesn't compile, the engine folder is missing: run scripts/fetch-blocker-sources.sh first
// (make-app.sh does). It sets up Sources/BigMac/AdBlock/Engine with or without the engine.
private typealias EngineFolderReady = Run_scripts_fetch_blocker_sources_sh_first
