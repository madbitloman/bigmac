import Darwin
import Foundation
import Security

struct Connection: Identifiable, Sendable, Hashable {
    var id: String { "\(pid)|\(proto)|\(local)|\(remote)" }
    let pid: Int32
    let command: String
    let proto: String
    let local: String
    let remote: String
    let state: String

    /// Host and port of the remote end; handles `[v6]:port` and `v4:port`.
    var remoteHost: String { Self.split(remote).host }
    var remotePort: Int? { Self.split(remote).port }

    static func split(_ endpoint: String) -> (host: String, port: Int?) {
        guard let colon = endpoint.lastIndex(of: ":") else { return (endpoint, nil) }
        var host = String(endpoint[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return (host, Int(endpoint[endpoint.index(after: colon)...]))
    }
}

enum Lsof {
    /// Current user's sockets that have a remote end. Without root, other users' processes aren't visible.
    static func connections() throws -> [Connection] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-i", "-F", "pcnPT"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()  // read before wait to avoid pipe deadlock
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Parses `lsof -F pcnPT` field output: p=pid, c=command, f=fd (new file), P=protocol, n=name, T=TCP info.
    static func parse(_ output: String) -> [Connection] {
        var result: [Connection] = []
        var pid: Int32 = 0
        var command = ""
        var proto = "", name = "", state = ""

        func flush() {
            defer { proto = ""; name = ""; state = "" }
            guard let arrow = name.range(of: "->") else { return }
            let local = String(name[..<arrow.lowerBound])
            let remote = String(name[arrow.upperBound...])
            let host = Connection.split(remote).host
            if isLoopback(host) { return }
            result.append(Connection(pid: pid, command: command, proto: proto, local: local, remote: remote, state: state))
        }

        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": flush(); pid = Int32(value) ?? 0
            case "c": command = value
            case "f": flush()
            case "P": proto = value
            case "n": name = value
            case "T": if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: break
            }
        }
        flush()
        return Array(Set(result)).sorted { $0.command < $1.command }
    }

    static func isLoopback(_ host: String) -> Bool {
        host.hasPrefix("127.") || host == "::1" || host == "localhost"
    }

    static func isPrivate(_ host: String) -> Bool {
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") { return true }
        if host.hasPrefix("172."), let second = Int(host.split(separator: ".").dropFirst().first ?? ""), (16...31).contains(second) { return true }
        let lower = host.lowercased()
        return lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd")
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }
}

enum Signer: Sendable, Hashable {
    case apple
    case developer(team: String)
    case adhoc
    case unsigned
    case invalid
    case unknown

    var label: String {
        switch self {
        case .apple: "Apple"
        case .developer(let team): "Developer (\(team))"
        case .adhoc: "Ad-hoc"
        case .unsigned: "Unsigned"
        case .invalid: "Invalid signature"
        case .unknown: "Unknown"
        }
    }
}

/// Serializes and caches code-signature checks, which are slow-ish and don't change per binary.
actor SignatureCache {
    private var cache: [String: Signer] = [:]

    func signer(for path: String) -> Signer {
        if let hit = cache[path] { return hit }
        let result = Self.check(path)
        cache[path] = result
        return result
    }

    static func check(_ path: String) -> Signer {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(filePath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return .unknown }

        let validity = SecStaticCodeCheckValidity(code, [], nil)
        if validity == errSecCSUnsigned { return .unsigned }
        if validity != errSecSuccess { return .invalid }

        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
           let requirement, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess {
            return .apple
        }

        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let dict = (info as NSDictionary?) ?? [:]
        if let team = dict[kSecCodeInfoTeamIdentifier] as? String { return .developer(team: team) }
        // Validly signed but with no team identity: ad-hoc (common for Homebrew/locally built tools).
        return .adhoc
    }
}

enum RiskSignal: String, Sendable, CaseIterable {
    case unsigned = "unsigned binary"
    case adhoc = "ad-hoc signed (no developer identity)"
    case invalidSignature = "invalid code signature"
    case tempLocation = "runs from a temp folder"
    case downloadsLocation = "runs from Downloads"
    case hiddenLocation = "runs from a hidden folder"
    case unusualPort = "uncommon remote port"
    case noExecutable = "executable path unavailable"

    var weight: Int {
        switch self {
        case .unsigned, .invalidSignature, .tempLocation: 3
        case .adhoc, .downloadsLocation, .hiddenLocation: 2
        case .unusualPort, .noExecutable: 1
        }
    }

    static let commonPorts: Set<Int> = [
        20, 21, 22, 53, 80, 123, 143, 443, 465, 587, 853, 993, 995, 1194, 3478, 3479,
        5222, 5223, 5228, 5349, 8080, 8443, 9418, 19302, 19305, 4070, 51820,
    ]

    static func evaluate(_ c: Connection, exePath: String?, signer: Signer) -> [RiskSignal] {
        var signals = binary(path: exePath, signer: signer)
        // LAN devices (Chromecast, NAS, printers) use all sorts of ports; only flag odd ports on the public internet.
        if let port = c.remotePort, !commonPorts.contains(port), c.proto == "TCP", !Lsof.isPrivate(c.remoteHost) {
            signals.append(.unusualPort)
        }
        return signals
    }

    /// Signature and location signals for an executable, shared by the network monitor and the security audit.
    static func binary(path: String?, signer: Signer) -> [RiskSignal] {
        var signals: [RiskSignal] = []
        switch signer {
        case .unsigned: signals.append(.unsigned)
        // Homebrew builds and links everything ad-hoc; that's expected there.
        case .adhoc where !(path.map { p in ["/opt/homebrew/", "/usr/local/Cellar/", "/usr/local/opt/"].contains(where: p.hasPrefix) } ?? false):
            signals.append(.adhoc)
        case .invalid: signals.append(.invalidSignature)
        default: break
        }
        guard let path else { return signals + [.noExecutable] }
        if ["/tmp/", "/private/tmp/", "/private/var/folders/", "/var/folders/"].contains(where: path.hasPrefix) {
            signals.append(.tempLocation)
        }
        if path.hasPrefix(FS.home.appending(path: "Downloads").path) { signals.append(.downloadsLocation) }
        // Hidden path components, ignoring well-known dev tool homes.
        let hidden = path.split(separator: "/").dropLast().contains {
            $0.hasPrefix(".") && ![".nvm", ".cargo", ".rustup", ".pyenv", ".local", ".vscode", ".cursor", ".docker", ".bun", ".deno", ".claude"].contains(String($0))
        }
        if hidden { signals.append(.hiddenLocation) }
        return signals
    }
}

enum RiskLevel: Int, Sendable, Comparable {
    case none, low, medium, high
    static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }

    init(signals: [RiskSignal]) {
        switch signals.reduce(0, { $0 + $1.weight }) {
        case 0: self = .none
        case 1...2: self = .low
        case 3...4: self = .medium
        default: self = .high
        }
    }

    var label: String { ["OK", "Low", "Medium", "High"][rawValue] }
}
