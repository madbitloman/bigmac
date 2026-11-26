import AppKit
import Foundation
import SafariServices

extension BlockingCategory {
    var title: String {
        switch self {
        case .ads: "Ads"
        case .trackers: "Trackers"
        case .popups: "Pop-ups"
        case .annoyances: "Cookie notices and overlays"
        case .social: "Social widgets"
        case .strictPopups: "Strict pop-up blocking"
        case .youtube: "YouTube ads"
        }
    }

    var detail: String {
        switch self {
        case .ads: "Ad networks and common ad slots (EasyList)"
        case .trackers: "Analytics and cross-site tracking scripts (EasyPrivacy)"
        case .popups: "Pop-up and pop-under networks, ad overlays, and tabs a site opens without your click"
        case .annoyances: "Consent banners, newsletter and survey pop-ups"
        case .social: "Embedded like and share buttons. Can break signing in with a social account."
        case .strictPopups: "Every new window opened to another site, except common sign-in and payment windows. In Safari's pop-up extension, also windows a site's own buttons open."
        case .youtube: "Skips video ads and hides ad slots on youtube.com"
        }
    }
}

/// The Ad & Pop-up Blocking pane: one set of settings for Safari (shared with both Safari extensions through
/// the app group), the state of those two extensions, the Chrome and Firefox extension, and the optional
/// system-wide hosts list.
@MainActor @Observable
final class AdBlockModel {
    private let store: RuleStore
    /// False in an unbundled debug run: there's no app group, so Safari never sees these settings.
    let linkedToSafari: Bool
    private(set) var settings: BlockerSettings
    let catalog: FilterCatalog

    /// nil until Safari has answered (or when it can't, outside the app bundle).
    var blockerEnabled: Bool?
    var webExtensionEnabled: Bool?
    /// Pop-ups the Safari web extension has stopped (it counts them in the app group).
    var blockedPopups = 0
    /// False when BigMac was built without the YouTube ad skipper (it comes with the Chrome and Firefox extension's source).
    let youTubeSkipperBundled: Bool
    /// Shown once to someone who used the earlier three-extension layout.
    var showLayoutNotice = false

    var hosts = HostsBlocker.Status()
    /// Fingerprint the hosts block would have with the current allowed sites.
    var hostsExpected: String?
    /// How many servers the hosts block would hold with the current allowed sites.
    var hostsAvailable = 0
    var hostsBusy = false
    var message: String?

    /// The Chrome and Firefox extension inside the app; nil when BigMac was built without it.
    let browserExtension = BrowserExtension.bundled()
    /// Browsers on this Mac that can take it, by bundle identifier.
    var browsers: [BrowserExtension.Browser] = []
    /// What the last "Show extension in Finder" did.
    var browserExtensionNote: String?

    /// `store` is for tests; the app uses the shared app group, or its own defaults in a debug run.
    init(store injected: RuleStore? = nil, preferences: UserDefaults = .standard) {
        if let injected {
            store = injected
            linkedToSafari = false
        } else if let shared = RuleStore.shared {
            store = shared
            linkedToSafari = true
        } else {
            store = RuleStore(defaults: .standard)
            linkedToSafari = false
        }
        settings = store.loadSettings()
        catalog = Self.loadCatalog()
        youTubeSkipperBundled = Bundle.main.builtInPlugInsURL.map {
            FileManager.default.fileExists(atPath: $0.appending(path: "BigMacPopupBlocker.appex/Contents/Resources/youtube.js").path)
        } ?? false
        self.preferences = preferences
        // Layout 2: one web extension for pop-ups and YouTube instead of two. Earlier users saved settings already.
        if preferences.integer(forKey: Self.layoutKey) < 2 {
            showLayoutNotice = linkedToSafari && store.hasSavedSettings
            if !showLayoutNotice { preferences.set(2, forKey: Self.layoutKey) }
        }
    }

    private let preferences: UserDefaults
    private static let layoutKey = "adBlockLayout"

    func dismissLayoutNotice() {
        showLayoutNotice = false
        preferences.set(2, forKey: Self.layoutKey)
    }

    /// The manifest of the lists inside the content blocker, or the checkout's copy in a debug run.
    private static func loadCatalog() -> FilterCatalog {
        if let plugins = Bundle.main.builtInPlugInsURL,
           let appex = Bundle(url: plugins.appending(path: "BigMacContentBlocker.appex")) {
            let catalog = FilterCatalog.load(from: appex)
            if !catalog.lists.isEmpty { return catalog }
        }
        let local = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "Extensions/Filters/manifest.json")
        return (try? Data(contentsOf: local)).map(FilterCatalog.load(from:)) ?? .empty
    }

    var ruleCount: Int { RuleCompiler.rules(for: settings).count + catalog.ruleCount(for: settings) }

    var hostsUpToDate: Bool { hosts.installed && hosts.fingerprint == hostsExpected }

    /// Blocking in Safari: the master switch is on and Safari has the content blocker or the web extension on.
    var safariBlocking: Bool { settings.enabled && (blockerEnabled == true || webExtensionEnabled == true) }

    // MARK: Settings

    var isEnabled: Bool { settings.enabled }

    func setEnabled(_ on: Bool) { update { $0.enabled = on } }

    func isOn(_ category: BlockingCategory) -> Bool { settings.enabledCategories.contains(category) }

    func set(_ category: BlockingCategory, on: Bool) {
        update { if on { $0.enabledCategories.insert(category) } else { $0.enabledCategories.remove(category) } }
    }

    /// Adds a site to the allowed list; false when the text isn't a usable domain.
    @discardableResult
    func allow(_ text: String) -> Bool {
        guard let domain = DomainNormalizer.normalize(text) else { return false }
        update { settings in
            guard !settings.allowedDomains.contains(domain) else { return }
            settings.allowedDomains.append(domain)
            settings.allowedDomains.sort()
        }
        return true
    }

    func removeAllowed(_ domain: String) {
        update { $0.allowedDomains.removeAll { $0 == domain } }
    }

    /// Every change starts from what's saved now, not from this pane's copy: the Safari toolbar page changes the
    /// allowed sites through the app group while BigMac is open, and saving a stale copy would undo that.
    private func update(_ change: (inout BlockerSettings) -> Void) {
        var fresh = store.loadSettings()
        change(&fresh)
        settings = fresh
        save()
    }

    /// Picks up changes made elsewhere (the Safari toolbar page) without saving anything.
    func reloadSettings() {
        let saved = store.loadSettings()
        if saved != settings { settings = saved }
    }

    private func save() {
        do {
            try store.save(settings)
        } catch {
            message = "Couldn't save the settings: \(error.localizedDescription)"
            return
        }
        Task { await reloadSafari() }
        Task { await refreshHosts() }
    }

    /// Asks Safari to rebuild the rule list from the saved settings. Fails harmlessly while the blocker is off.
    private func reloadSafari() async {
        guard linkedToSafari else { return }
        do {
            try await SFContentBlockerManager.reloadContentBlocker(withIdentifier: RuleStore.contentBlockerIdentifier)
            message = nil
        } catch {
            if blockerEnabled == true { message = "Safari didn't reload the rules: \(error.localizedDescription)" }
        }
    }

    // MARK: State

    func refresh() async {
        reloadSettings()
        if linkedToSafari {
            blockerEnabled = try? await SFContentBlockerManager.stateOfContentBlocker(withIdentifier: RuleStore.contentBlockerIdentifier).isEnabled
            webExtensionEnabled = try? await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: RuleStore.webExtensionIdentifier).isEnabled
            blockedPopups = store.blockedPopups
        }
        browsers = BrowserExtension.installedBrowsers()
        await refreshHosts()
    }

    private func refreshHosts() async {
        let allowed = settings.allowedDomains
        let (status, expected, count) = await Task.detached {
            let text = (try? String(contentsOfFile: HostsBlocker.hostsPath, encoding: .utf8)) ?? ""
            let names = HostsBlocker.names(allowed: allowed)
            return (HostsBlocker.status(of: text), HostsBlocker.fingerprint(names), names.count)
        }.value
        hosts = status
        hostsExpected = expected
        hostsAvailable = count
    }

    /// Safari's Extensions settings, showing BigMac's content blocker (Safari shows the others beside it).
    func openSafariExtensions() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: RuleStore.contentBlockerIdentifier) { _ in }
    }

    func openSafariSettings(_ identifier: String) {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: identifier) { _ in }
    }

    // MARK: Chrome and Firefox

    /// Copies the extension to its folder in Application Support (only when it changed) and selects it in Finder.
    func showBrowserExtension() {
        guard let bundled = browserExtension else { return }
        do {
            let copied = try BrowserExtension.install(bundled)
            browserExtensionNote = copied
                ? "Copied version \(bundled.version). If a browser already has it, click Reload on its extensions page."
                : "Version \(bundled.version) is up to date in this folder."
            NSWorkspace.shared.activateFileViewerSelecting([BrowserExtension.stableFolder])
        } catch {
            message = "Couldn't copy the browser extension: \(error.localizedDescription)"
        }
    }

    func openExtensionsPage(of browser: BrowserExtension.Browser) {
        BrowserExtension.openExtensionsPage(of: browser)
    }

    // MARK: System-wide

    /// Installs (or updates) the hosts block, or removes it. One admin prompt either way.
    func setSystemWide(_ on: Bool) async {
        hostsBusy = true
        defer { hostsBusy = false }
        let allowed = settings.allowedDomains
        let problem = await Task.detached {
            HostsBlocker.install(names: on ? HostsBlocker.names(allowed: allowed) : [])
        }.value
        message = problem
        await refreshHosts()
    }
}
