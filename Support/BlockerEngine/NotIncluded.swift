import Foundation

// Stands in for the blocking engine in a build without it (a copy of this repository on its own).
// scripts/fetch-blocker-sources.sh links this file into Sources/BigMac/AdBlock/Engine when the engine's
// source isn't there. BigMac then has no ad blocking: the Ad & Pop-up Blocking pane says so, make-app.sh embeds
// no Safari extension, and the self-test skips the blocking checks. See BlockerEngineAPI.swift.

enum BlockerEngine: BlockerEngineAPI {
    static let included = false
    static func normalize(_ input: String) -> String? { nil }
    static var hostsDomains: [String] { [] }
    static var popupAllowedDomains: [String] { [] }
    static func urlFilter(forDomain domain: String) -> String { "" }
    static func filterLists(manifest: Data) -> [FilterListInfo] { [] }
    static func ruleCount(for settings: SafariSettings, manifest: Data) -> Int { 0 }

    @discardableResult
    static func writeRules(for settings: SafariSettings, manifest: Data, lists: URL, to file: URL) throws -> Int {
        throw CocoaError(.featureUnsupported)
    }
}

/// See the end of BlockerEngineAPI.swift.
enum Run_scripts_fetch_blocker_sources_sh_first {}
