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
        }
    }

    var detail: String {
        switch self {
        case .ads: "Ad networks and common ad slots (EasyList)"
        case .trackers: "Analytics and cross-site tracking scripts (EasyPrivacy)"
        case .popups: "Pop-up and pop-under networks, ad overlays, and with the pop-up blocker, tabs a site opens without your click"
        case .annoyances: "Consent banners, newsletter and survey pop-ups"
        case .social: "Embedded like and share buttons. Can break signing in with a social account."
        case .strictPopups: "Every new window opened to another site, except common sign-in and payment windows. With the pop-up blocker, also windows a site's own buttons open."
        }
    }
}

/// The Ad Blocking pane: Safari content blocker settings (shared with the extension through the app group),
/// the state of BigMac's three Safari extensions, and the optional system-wide hosts list.
@MainActor @Observable
final class AdBlockModel {
    private let store: RuleStore
    /// False in an unbundled debug run: there's no app group, so Safari never sees these settings.
    let linkedToSafari: Bool
    private(set) var settings: BlockerSettings
    let catalog: FilterCatalog

    /// nil until Safari has answered (or when it can't, outside the app bundle).
    var blockerEnabled: Bool?
    var youTubeEnabled: Bool?
    var popupBlockerEnabled: Bool?
    /// Pop-ups the Safari pop-up blocker has stopped (it counts them in the app group).
    var blockedPopups = 0

    var hosts = HostsBlocker.Status()
    /// Fingerprint the hosts block would have with the current allowed sites.
    var hostsExpected: String?
    /// How many servers the hosts block would hold with the current allowed sites.
    var hostsAvailable = 0
    var hostsBusy = false
    var message: String?

    init() {
        if let shared = RuleStore.shared {
            store = shared
            linkedToSafari = true
        } else {
            store = RuleStore(defaults: .standard)
            linkedToSafari = false
        }
        settings = store.loadSettings()
        catalog = Self.loadCatalog()
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

    // MARK: Settings

    func isOn(_ category: BlockingCategory) -> Bool { settings.enabledCategories.contains(category) }

    func set(_ category: BlockingCategory, on: Bool) {
        if on { settings.enabledCategories.insert(category) } else { settings.enabledCategories.remove(category) }
        save()
    }

    /// Adds a site to the allowed list; false when the text isn't a usable domain.
    @discardableResult
    func allow(_ text: String) -> Bool {
        guard let domain = DomainNormalizer.normalize(text) else { return false }
        if !settings.allowedDomains.contains(domain) {
            settings.allowedDomains.append(domain)
            settings.allowedDomains.sort()
            save()
        }
        return true
    }

    func removeAllowed(_ domain: String) {
        settings.allowedDomains.removeAll { $0 == domain }
        save()
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
        if linkedToSafari {
            blockerEnabled = try? await SFContentBlockerManager.stateOfContentBlocker(withIdentifier: RuleStore.contentBlockerIdentifier).isEnabled
            youTubeEnabled = try? await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: RuleStore.youTubeExtensionIdentifier).isEnabled
            popupBlockerEnabled = try? await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: RuleStore.popupBlockerExtensionIdentifier).isEnabled
            blockedPopups = store.blockedPopups
        }
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

    func openSafariSettings(_ identifier: String) {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: identifier) { _ in }
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
