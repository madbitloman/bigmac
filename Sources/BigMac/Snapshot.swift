import AppKit
import SwiftUI

/// `BigMac --snapshot <dir> [light] [demo]`: renders every pane to PNGs, for checking the design headlessly.
/// `demo` uses made-up data instead of this Mac's, for screenshots that can be shared.
@MainActor
enum Snapshot {
    static func run(arguments: [String]) async -> Never {
        let dir = URL(filePath: arguments.firstIndex(of: "--snapshot").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? ".")
        let dark = !arguments.contains("light")
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        // The ad-blocking pane's one-time notice is remembered in a throwaway domain, never in BigMac's own preferences.
        let jev = JevSettings(useKeychain: false),  // a Keychain prompt would block headless runs
             junk = JunkModel(), duplicates = DuplicatesModel(), apps = AppsModel()
        let network = NetworkModel(), audit = AuditModel(), stats = SystemStats(), adBlock = AdBlockModel(preferences: UserDefaults(suiteName: "com.bigmac.snapshot")!)
        audit.triageAfterScan = false
        if arguments.contains("demo") {
            Demo.fill(junk: junk, duplicates: duplicates, apps: apps, network: network, audit: audit)
            Demo.fill(adBlock: adBlock)
        } else {
            async let a: Void = audit.run()
            async let j: Void = junk.scan()
            async let n: Void = network.refresh()
            async let p: Void = apps.scan()
            async let b: Void = adBlock.refresh()
            _ = await (a, j, n, p, b)
        }
        if arguments.contains("demo") {
            stats.fillDemo()
        } else {
            // Readings a moment apart, so CPU load and its graph have something to show.
            for _ in 0..<12 { stats.sample(); try? await Task.sleep(for: .milliseconds(150)) }
        }
        print("data ready")

        func environment<V: View>(_ view: V) -> some View {
            view
                .environment(jev).environment(junk).environment(duplicates).environment(apps)
                .environment(network).environment(audit).environment(stats).environment(adBlock)
                .environment(\.colorScheme, dark ? .dark : .light)
        }
        func write(_ rep: NSBitmapImageRep?, _ name: String) {
            guard let png = rep?.representation(using: .png, properties: [:]) else { print("render failed: \(name)"); return }
            try? png.write(to: dir.appending(path: "\(name).png"))
            print("wrote \(name).png")
        }
        /// Native lists and the sidebar only draw in a real window, so each pane goes into an offscreen one,
        /// styled like the app's (hidden title bar, content under it), and the whole window frame is cached to a bitmap.
        /// `height: nil` sizes the window to fit, borderless, the way the menu bar panel appears.
        func window<V: View>(_ name: String, _ view: V, width: CGFloat = 1180, height: CGFloat? = 760) async {
            let host = NSHostingController(rootView: environment(view))
            host.sceneBridgingOptions = [.title]
            let height = height ?? host.sizeThatFits(in: NSSize(width: width, height: 10_000)).height
            let style: NSWindow.StyleMask = name == "menubar" ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: width, height: height),
                                  styleMask: style, backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentViewController = host
            window.setContentSize(NSSize(width: width, height: height))
            window.setFrameOrigin(NSPoint(x: -20_000, y: 0))
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(900))  // let SwiftUI lay out, load icons and fill the toolbar
            guard let frame = window.contentView?.superview else { return }
            frame.layoutSubtreeIfNeeded()
            let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
            if let rep { frame.cacheDisplay(in: frame.bounds, to: rep) }
            write(rep, name)
            window.orderOut(nil)
        }
        for pane in Pane.allCases { await window(pane.rawValue.replacingOccurrences(of: " ", with: "-"), ContentView(initial: pane)) }
        // The lower half of the Ad & Pop-up Blocking pane: the browsers and the system-wide list.
        await window("Ad-&-Pop-up-Blocking-browsers", AdBlockView(scrollTo: "browsers"), width: 900, height: 1000)
        await window("settings", SettingsView(), width: 620, height: 520)
        await window("menubar", MenuBarPanel().frame(width: 400), width: 400, height: nil)
        exit(0)
    }
}
