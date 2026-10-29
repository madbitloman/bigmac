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

        let jev = JevSettings(useKeychain: false),  // a Keychain prompt would block headless runs
             junk = JunkModel(), duplicates = DuplicatesModel(), apps = AppsModel()
        let network = NetworkModel(), audit = AuditModel()
        audit.triageAfterScan = false
        if arguments.contains("demo") {
            Demo.fill(junk: junk, duplicates: duplicates, apps: apps, network: network, audit: audit)
        } else {
            async let a: Void = audit.run()
            async let j: Void = junk.scan()
            async let n: Void = network.refresh()
            async let p: Void = apps.scan()
            _ = await (a, j, n, p)
        }
        print("data ready")

        func render<V: View>(_ name: String, _ view: V, width: CGFloat = 1180, height: CGFloat = 760) {
            let root = view
                .environment(jev).environment(junk).environment(duplicates).environment(apps)
                .environment(network).environment(audit)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.snapshotMode, true)
                .frame(width: width, height: height)
            let renderer = ImageRenderer(content: root)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { print("render failed: \(name)"); return }
            try? png.write(to: dir.appending(path: "\(name).png"))
            print("wrote \(name).png")
        }
        for pane in Pane.allCases { render(pane.rawValue.replacingOccurrences(of: " ", with: "-"), ContentView(initial: pane)) }
        render("menubar", MenuBarPanel(), width: 320, height: 300)
        exit(0)
    }
}
