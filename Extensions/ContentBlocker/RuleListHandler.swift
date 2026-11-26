import Foundation

/// BigMac Ad Blocker's entry point. Safari calls it when the content blocker is switched on and whenever BigMac
/// asks for a reload; it answers with the rule list for BigMac's saved settings, or gives up with the error.
@objc(BigMacRuleListHandler)
final class RuleListHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let ruleList: NSItemProvider
        do {
            guard let provider = NSItemProvider(contentsOf: try SettingsStore.rulesFileForSafari()) else {
                throw CocoaError(.fileReadUnknown)
            }
            ruleList = provider
        } catch {
            context.cancelRequest(withError: error)
            return
        }
        let reply = NSExtensionItem()
        reply.attachments = [ruleList]
        context.completeRequest(returningItems: [reply])
    }
}
