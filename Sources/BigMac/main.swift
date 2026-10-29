import AppKit

if CommandLine.arguments.contains("--selftest") {
    Task.detached { await SelfTest.run(arguments: CommandLine.arguments) }
    dispatchMain()
}

if let i = CommandLine.arguments.firstIndex(of: "--icon"), CommandLine.arguments.indices.contains(i + 1) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        do { try Logo.writeIcon(to: URL(filePath: CommandLine.arguments[i + 1])); exit(0) } catch { print(error); exit(1) }
    }
    app.run()
}

if CommandLine.arguments.contains("--snapshot") {
    // Some scanners need a live AppKit run loop, which dispatchMain doesn't provide.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in await Snapshot.run(arguments: CommandLine.arguments) }
    app.run()
}

BigMacApp.main()
