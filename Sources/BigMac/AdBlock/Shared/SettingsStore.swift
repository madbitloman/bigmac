import Foundation

/// Where BigMac and its two Safari extensions keep what they share: the settings, and the count of
/// pop-ups the web extension stopped. In the app group's defaults, so every process sees the same values.
struct SettingsStore {
    /// BigMac Ad Blocker, the content blocker.
    static let contentBlockerIdentifier = "com.bigmac.app.ContentBlocker"
    /// BigMac Pop-up and YouTube Blocker, the web extension. Its identifier is from when it handled pop-ups alone.
    static let webExtensionIdentifier = "com.bigmac.app.PopupBlocker"

    /// Every bundle names the group (prefixed with the team ID) in its Info.plist, under BigMacAppGroup.
    /// An unbundled debug build has none, and runs without Safari blocking.
    static var appGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "BigMacAppGroup") as? String
    }

    /// The app group's store, or nil when this process can't use the group (a build signed without it).
    static var shared: SettingsStore? {
        guard let group = appGroup,
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil,
              let defaults = UserDefaults(suiteName: group)
        else { return nil }
        return SettingsStore(defaults: defaults)
    }

    let defaults: UserDefaults

    private static let settingsKey = "settings"
    private static let blockedPopupsKey = "blockedPopups"

    /// The saved settings, or the defaults when there are none (or they can't be read).
    func loadSettings() -> SafariSettings {
        defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(SafariSettings.self, from: $0) }
            ?? SafariSettings()
    }

    /// Safari picks the new settings up the next time it reloads the content blocker.
    func save(_ settings: SafariSettings) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: Self.settingsKey)
    }

    /// True once the app (or the toolbar page) has saved settings here.
    var hasSavedSettings: Bool { defaults.data(forKey: Self.settingsKey) != nil }

    /// Pop-ups the web extension has stopped, counted by its native handler.
    var blockedPopups: Int { defaults.integer(forKey: Self.blockedPopupsKey) }

    func countBlockedPopup() {
        defaults.set(blockedPopups + 1, forKey: Self.blockedPopupsKey)
    }

    /// The content blocker's rule list for the saved settings (the defaults when nothing is saved), written to a
    /// temporary file for Safari. Runs in the content blocker's process, whose bundle holds the filter lists.
    static func rulesFileForSafari() throws -> URL {
        let settings = shared?.loadSettings() ?? SafariSettings()
        let lists = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let manifest = (try? Data(contentsOf: lists.appending(path: "manifest.json"))) ?? Data()
        let file = FileManager.default.temporaryDirectory.appending(path: "blockerList.json")
        try BlockerEngine.writeRules(for: settings, manifest: manifest, lists: lists, to: file)
        return file
    }
}
