import Foundation

/// The questions BigMac asks Jev. Deterministic facts (sizes, signatures, paths, ports) are measured
/// in code and passed as state; Jev only supplies the semantic judgment on top.
enum JevJudgments {
    struct Verdict: Sendable {
        /// 0…1, higher = more of the judged property (suspicious / safe / risky).
        let value: Double
        let confidence: Double?
    }

    // MARK: Network

    static let suspicionLevels = [
        "Expected: a well-known, properly signed application making ordinary network traffic",
        "Unusual but probably benign: an unfamiliar or developer tool, or an uncommon port, with nothing alarming",
        "Suspicious: several red flags together, such as an unsigned binary, an odd install location, or an odd port, that deserve a closer look",
        "Likely malicious: strongly resembles malware, a backdoor, a cryptominer, or data exfiltration",
    ]

    static func connectionState(_ row: ConnectionRow) -> JSON {
        .object([
            "process_name": .string(row.connection.command),
            "executable_path": .string(row.exePath.map { FS.tildePath(URL(filePath: $0)) } ?? "unknown"),
            "code_signature": .string(row.signer.label),
            "protocol": .string(row.connection.proto),
            "remote_address": .string(row.connection.remoteHost),
            "remote_port": row.connection.remotePort.map { .number(Double($0)) } ?? .null,
            "remote_is_private_lan": .bool(Lsof.isPrivate(row.connection.remoteHost)),
            "tcp_state": .string(row.connection.state),
            "signals_measured_by_code": .array(row.signals.map { .string($0.rawValue) }),
        ])
    }

    static func connectionQuestion(_ path: String) -> TSQuestion {
        .score(
            "On a personal Mac, judge how suspicious the outbound network connection described in \(path) is. "
                + "Consider whether the process name, executable location and code-signing status fit normal software, "
                + "and whether the remote port fits what that software usually does. "
                + "The code signature and the listed signals were measured directly and are accurate.",
            levels: suspicionLevels)
    }

    static func judgeConnections(_ rows: [ConnectionRow], client: TypeSafeClient) async throws -> [Verdict?] {
        let answers = try await client.askEach(rows, key: "connections", encode: connectionState, makeQuestion: connectionQuestion)
        return answers.map { a in a?.score.map { Verdict(value: $0 / Double(suspicionLevels.count - 1), confidence: a?.confidence) } }
    }

    // MARK: Cleanup

    static func judgeJunk(_ items: [JunkItem], client: TypeSafeClient) async throws -> [Verdict?] {
        let answers = try await client.askEach(
            items, key: "items",
            encode: { item in
                .object([
                    "path": .string(FS.tildePath(item.url)),
                    "category": .string(item.category.title),
                    "size": .string(item.size.bytes),
                ])
            },
            makeQuestion: { path in
                .noul(
                    "The item described in \(path) is a candidate for cleanup on a Mac. "
                        + "Can it be moved to the Trash without losing the user's own documents, settings, credentials or "
                        + "irreplaceable data, because it is a cache, log, build output, or other data that apps regenerate automatically? "
                        + "Answer no if it looks like user content, an app's database or keychain-like store, or anything hard to recreate.")
            })
        return answers.map { a in a?.noul.map { Verdict(value: $0, confidence: nil) } }
    }

    // MARK: Apps

    static func judgeApps(_ apps: [AppInfo], client: TypeSafeClient) async throws -> [Verdict?] {
        let answers = try await client.askEach(
            apps, key: "apps",
            encode: { app in
                .object([
                    "name": .string(app.name),
                    "bundle_id": .string(app.bundleID ?? "unknown"),
                    "path": .string(FS.tildePath(app.url)),
                ])
            },
            makeQuestion: { path in
                .noul(
                    "Is the Mac application described in \(path) a driver, system extension, security or VPN tool, device companion, "
                        + "or other component that hardware or other software likely depends on, so that uninstalling it could break something "
                        + "beyond the app itself?")
            })
        return answers.map { a in a?.noul.map { Verdict(value: $0, confidence: nil) } }
    }
}
