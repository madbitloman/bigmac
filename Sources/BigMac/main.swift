import AppKit

#if DEBUG
// Developer self-test: debug builds only, so the shipped app has no command-line path that reads saved keys.
if CommandLine.arguments.contains("--selftest") {
    // An AppKit run loop rather than dispatchMain: WebKit (used to compile the Safari rules) won't start without one.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    setvbuf(stdout, nil, _IOLBF, 0)  // progress shows up in a log file as it happens
    Task.detached { await SelfTest.run(arguments: CommandLine.arguments) }
    app.run()
}
#endif

if let i = CommandLine.arguments.firstIndex(of: "--icon"), CommandLine.arguments.indices.contains(i + 1) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        do { try Logo.writeIcon(to: URL(filePath: CommandLine.arguments[i + 1])); exit(0) } catch { print(error); exit(1) }
    }
    app.run()
}

if CommandLine.arguments.contains("--snapshot") {
    // Some scanners need a live AppKit run loop, which dispatchMain doesn't provide. Accessory (no Dock icon)
    // rather than prohibited, so the offscreen windows the snapshots draw into can be ordered in.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in await Snapshot.run(arguments: CommandLine.arguments) }
    app.run()
}

BigMacApp.main()
