import Foundation
import SafariServices

/// The pop-up blocker's native side. Its JavaScript (Resources/background.js) asks here for BigMac's
/// settings, which live in the shared app group, so the blocker follows the same "Pop-ups" and
/// "Strict pop-up blocking" switches and the same allowed sites as the content blocker.
///
/// Messages ({"type": ...}):
///   "settings"            -> {"popups", "strict", "allowed", "linked"}
///   "allow", "site"       adds the site to the allowed list (the content blocker reloads too), then as "settings"
///   "blocked"             counts one blocked pop-up for BigMac's Ad Blocking pane, then as "settings"
@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: PopupBlockerSettings.handle(message)]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}

enum PopupBlockerSettings {
    static func handle(_ message: [String: Any]) -> [String: Any] {
        // Without the app group (an unsigned build), the defaults apply: pop-ups blocked, nothing allowed.
        let store = RuleStore.shared
        var settings = store?.loadSettings() ?? BlockerSettings()
        switch message["type"] as? String {
        case "allow":
            if let store, let site = message["site"] as? String, let domain = DomainNormalizer.normalize(site),
               !settings.allowedDomains.contains(domain) {
                settings.allowedDomains.append(domain)
                settings.allowedDomains.sort()
                try? store.save(settings)
                SFContentBlockerManager.reloadContentBlocker(withIdentifier: RuleStore.contentBlockerIdentifier) { _ in }
            }
        case "blocked":
            store?.countBlockedPopup()
        default:
            break
        }
        return [
            "popups": settings.enabledCategories.contains(.popups),
            "strict": settings.enabledCategories.contains(.strictPopups),
            "allowed": settings.allowedDomains,
            "linked": store != nil,
        ]
    }
}
