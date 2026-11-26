import Foundation

// BigMac's side of the blocking engine. scripts/fetch-blocker-sources.sh links this file into
// Sources/BigMac/AdBlock/Engine next to the engine's own files (copied unchanged), so it compiles into the app and
// both Safari extensions only when the engine is there. See BlockerEngineAPI.swift.

enum BlockerEngine: BlockerEngineAPI {
    static let included = true

    static func normalize(_ input: String) -> String? { DomainNormalizer.normalize(input) }

    static var hostsDomains: [String] {
        FilterLists.adDomains + FilterLists.trackerDomains + FilterLists.popupDomains + FilterLists.annoyanceDomains
    }

    static var popupAllowedDomains: [String] { FilterLists.popupAllowedDomains }

    static func urlFilter(forDomain domain: String) -> String { RuleCompiler.urlFilter(forDomain: domain) }

    static func filterLists(manifest: Data) -> [FilterListInfo] {
        FilterCatalog.load(from: manifest).lists.map {
            FilterListInfo(id: $0.id, title: $0.title, version: $0.version, homepage: $0.homepage, license: $0.license, ruleCount: $0.ruleCount)
        }
    }

    static func ruleCount(for settings: SafariSettings, manifest: Data) -> Int {
        let engine = engineSettings(settings)
        return RuleCompiler.rules(for: engine).count + FilterCatalog.load(from: manifest).ruleCount(for: engine)
    }

    @discardableResult
    static func writeRules(for settings: SafariSettings, manifest: Data, lists: URL, to file: URL) throws -> Int {
        try RuleAssembler.write(settings: engineSettings(settings), catalog: FilterCatalog.load(from: manifest),
                                fragmentsDirectory: lists, to: file)
    }

    /// The engine's settings for BigMac's: the categories that are active (none while the main switch is off),
    /// without YouTube, which the web extension handles and which has no rules. With no category left, the allowed
    /// sites add no rule either, so the main switch off gives Safari the list that matches nothing.
    static func engineSettings(_ settings: SafariSettings) -> BlockerSettings {
        BlockerSettings(enabledCategories: Set(settings.activeCategories.compactMap { BlockingCategory(rawValue: $0.rawValue) }),
                        allowedDomains: settings.allowedDomains)
    }
}

/// See the end of BlockerEngineAPI.swift.
enum Run_scripts_fetch_blocker_sources_sh_first {}
