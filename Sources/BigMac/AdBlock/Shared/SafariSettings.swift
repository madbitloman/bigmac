import Foundation

/// One switch under "What to Block". The raw values are the names settings are saved under, so they never change.
/// Every case but `youtube` is a category of the blocking engine's rules; YouTube ads are skipped by the Safari
/// web extension instead, so that one switch adds no rules.
enum AdBlockCategory: String, CaseIterable, Identifiable, Sendable {
    case ads
    case trackers
    case popups
    case annoyances
    case social
    case strictPopups
    case youtube

    var id: String { rawValue }

    /// On for a fresh install. Social widgets and strict pop-up blocking stay off: they can break
    /// share and sign-in buttons and windows people open on purpose.
    static let defaults: Set<AdBlockCategory> = [.ads, .trackers, .popups, .annoyances, .youtube]
}

/// BigMac's blocking settings for Safari, shared with both Safari extensions through the app group:
/// the main switch, the categories and the allowed sites.
struct SafariSettings: Equatable, Sendable {
    /// The main switch. Off blocks nothing in Safari but keeps the category choices for when it's back on.
    var enabled = true
    var enabledCategories: Set<AdBlockCategory> = AdBlockCategory.defaults
    /// Bare lowercase domains (see `BlockerEngine.normalize`) where nothing is blocked.
    var allowedDomains: [String] = []

    /// What actually blocks: the chosen categories, or none while the main switch is off.
    /// The rule list, the Safari web extension and the pane all go by this.
    var activeCategories: Set<AdBlockCategory> { enabled ? enabledCategories : [] }
}

/// Saved as {"enabled": true, "enabledCategories": ["ads", ...], "allowedDomains": [...]}.
extension SafariSettings: Codable {
    private enum Key: String, CodingKey {
        case enabled, enabledCategories, allowedDomains
    }

    init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: Key.self)
        let names = try saved.decode([String].self, forKey: .enabledCategories)
        // By name, so a category a later version drops is skipped instead of failing the whole load.
        enabledCategories = Set(names.compactMap(AdBlockCategory.init(rawValue:)))
        let switchSaved = try saved.decodeIfPresent(Bool.self, forKey: .enabled)
        enabled = switchSaved ?? true
        // Saved before the main switch and the YouTube switch existed: YouTube ads were skipped
        // wherever the extension was on, so they stay skipped.
        if switchSaved == nil, !names.contains(AdBlockCategory.youtube.rawValue) {
            enabledCategories.insert(.youtube)
        }
        allowedDomains = try saved.decodeIfPresent([String].self, forKey: .allowedDomains) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var saved = encoder.container(keyedBy: Key.self)
        try saved.encode(enabled, forKey: .enabled)
        try saved.encode(enabledCategories.map(\.rawValue).sorted(), forKey: .enabledCategories)
        try saved.encode(allowedDomains, forKey: .allowedDomains)
    }
}
