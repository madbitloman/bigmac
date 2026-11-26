import SwiftUI

/// "Chrome and Firefox": the blocker for other browsers, installed by hand with BigMac's guidance.
/// Only the steps for browsers found on this Mac are shown.
struct BrowserExtensionCard: View {
    @Environment(AdBlockModel.self) private var model

    private var chromium: [BrowserExtension.Browser] { model.browsers.filter { $0.engine == .chromium } }
    private var firefox: [BrowserExtension.Browser] { model.browsers.filter { $0.engine == .firefox } }

    var body: some View {
        Card("Chrome and Firefox", symbol: "puzzlepiece.extension", trailing: model.browserExtension.map { "Version \($0.version)" }) {
            if let bundled = model.browserExtension {
                CardRows {
                    SettingRow(title: bundled.name,
                               detail: "Ad, tracker and pop-up blocking for Chrome, Brave, Edge, Arc and Firefox. It keeps its own settings under its toolbar button.") {
                        Button { model.showBrowserExtension() } label: { ActionLabel("Show Extension in Finder", symbol: "folder") }
                            .buttonStyle(.ghost)
                    }
                }
                if let note = model.browserExtensionNote { Note(note) }
                if model.browsers.isEmpty {
                    Note("No Chrome, Brave, Edge, Arc or Firefox found on this Mac. Install one, then come back here.")
                }
                if !chromium.isEmpty { chromiumSteps }
                if !firefox.isEmpty { firefoxSteps }
            } else {
                Note("This copy of BigMac was built without the Chrome and Firefox extension.")
            }
        }
    }

    private var chromiumSteps: some View {
        BrowserSteps(title: ListFormatter.localizedString(byJoining: chromium.map(\.name)),
                     browsers: chromium, buttonTitle: { "Open \($0.name) Extensions" },
                     steps: [
                        "Click Show Extension in Finder. BigMac puts it in a folder that stays the same after updates.",
                        "Open the extensions page and switch on Developer mode.",
                        "Click Load unpacked and choose the BrowserExtension folder.",
                        "After a BigMac update, click Show Extension in Finder again, then the extension's Reload button.",
                     ],
                     note: "The browser lists it as an unpacked extension and may show a banner about developer-mode extensions when it starts. That's expected for extensions that don't come from its store.")
    }

    private var firefoxSteps: some View {
        BrowserSteps(title: ListFormatter.localizedString(byJoining: firefox.map(\.name)),
                     browsers: firefox, buttonTitle: { "Open \($0.name) Add-ons" },
                     steps: [
                        "Click Show Extension in Finder.",
                        "Open the add-ons page (This Firefox) and click Load Temporary Add-on.",
                        "Choose manifest.json in the BrowserExtension folder.",
                     ],
                     note: "Firefox keeps a temporary add-on until it quits, so load it again after each restart. A version signed by Mozilla, which stays installed, will come later.")
    }
}

/// One browser family's numbered steps, with a button per installed browser that opens its extensions page.
private struct BrowserSteps: View {
    @Environment(AdBlockModel.self) private var model
    let title: String
    let browsers: [BrowserExtension.Browser]
    let buttonTitle: (BrowserExtension.Browser) -> String
    let steps: [String]
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Hairline()
            HStack(alignment: .firstTextBaseline) {
                Text(title).fontWeight(.semibold)
                Spacer(minLength: 12)
                ForEach(browsers) { browser in
                    Button(buttonTitle(browser)) { model.openExtensionsPage(of: browser) }
                        .buttonStyle(.ghost)
                        .help("Opens \(browser.extensionsPage) in \(browser.name) and copies the address, in case it opens a blank tab instead.")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(Theme.secondary).frame(width: 18, alignment: .trailing)
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Theme.small)
                }
            }
            Note(note)
        }
    }
}
