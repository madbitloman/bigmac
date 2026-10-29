import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM binary so the window comes to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            // Hidden title bar: let the whole background drag the window.
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { window?.isMovableByWindowBackground = true }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            // With the menu bar item on, closing the window drops the Dock icon and keeps the process in the menu bar.
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard Self.menuBarEnabled, let closing, closing.canBecomeMain else { return }
                if !NSApp.windows.contains(where: { $0 !== closing && $0.isVisible && $0.canBecomeMain }) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Self.menuBarEnabled }

    static var menuBarEnabled: Bool { UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true }
}

struct BigMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("showMenuBar") private var showMenuBar = true
    @State private var jev = JevSettings()
    @State private var junk = JunkModel()
    @State private var duplicates = DuplicatesModel()
    @State private var apps = AppsModel()
    @State private var network = NetworkModel()
    @State private var audit = AuditModel()

    var body: some Scene {
        Window("BigMac", id: "main") {
            models(ContentView())
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)

        MenuBarExtra(isInserted: $showMenuBar) {
            models(MenuBarPanel())
        } label: {
            models(MenuBarLabel())
        }
        .menuBarExtraStyle(.window)
    }

    private func models<V: View>(_ view: V) -> some View {
        view
            .environment(jev)
            .environment(junk)
            .environment(duplicates)
            .environment(apps)
            .environment(network)
            .environment(audit)
    }
}
