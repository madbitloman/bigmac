import Foundation

/// Built-in knowledge of how macOS malware and adware usually behave, mapped to MITRE ATT&CK.
/// Applied to every audit item after collection: a match adds a `known technique:` signal and raises the
/// heuristic severity to the rule's floor. Haiku sees the signal and is told it comes from this list.
/// Rules key on behaviour (where things run from, how they start, what they intercept) rather than on
/// malware hashes, which change with every build; the few names below are long-public, well-documented cases.
enum ThreatIntel {
    struct Rule: Sendable {
        let name: String
        let technique: String
        let floor: RiskLevel
        let kinds: Set<AuditItem.Kind>
        let matches: @Sendable (AuditItem, String) -> Bool
    }

    static func re(_ pattern: String) -> @Sendable (AuditItem, String) -> Bool {
        { _, text in text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    static let rules: [Rule] = [
        Rule(name: "launch item runs from a temp or shared folder (Adload/Shlayer-style loader)", technique: "T1543.001",
             floor: .high, kinds: [.persistence],
             matches: re(#"runs: (/private)?/tmp/|runs: /Users/Shared/|runs: /var/folders/"#)),
        Rule(name: "launch item runs a binary hidden in a dot-folder under Library", technique: "T1564.001",
             floor: .medium, kinds: [.persistence, .process],
             matches: re(#"Library/(Application Support|Caches)/\.[^/\s]+/"#)),
        Rule(name: "persistent download-and-execute (curl/wget piped to a shell)", technique: "T1105",
             floor: .high, kinds: [.persistence],
             matches: re(#"(curl|wget)[^|]*\|\s*(ba|z)?sh\b"#)),
        Rule(name: "persistent obfuscated payload (base64 decode / eval)", technique: "T1027",
             floor: .high, kinds: [.persistence],
             matches: re(#"base64\s+(-d|-D|--decode)|\beval\s*\(?\s*\$\(|python[0-9.]*\s+-c\s"#)),
        Rule(name: "inline AppleScript at login (used by stealers for fake password prompts)", technique: "T1059.002",
             floor: .medium, kinds: [.persistence],
             matches: re(#"osascript\s+-e"#)),
        Rule(name: "fake password dialog via AppleScript (Atomic/AMOS-style credential phishing)", technique: "T1056.002",
             floor: .high, kinds: [.process, .persistence],
             matches: re(#"display dialog.*(password|hidden answer)"#)),
        Rule(name: "keychain dump from the command line", technique: "T1555.001",
             floor: .high, kinds: [.process, .persistence],
             matches: re(#"security\s+(dump-keychain|find-(generic|internet)-password\s+.*-g)"#)),
        Rule(name: "library injection via DYLD_INSERT_LIBRARIES", technique: "T1574.006",
             floor: .high, kinds: [.persistence],
             matches: re(#"DYLD_INSERT_LIBRARIES"#)),
        Rule(name: "sudo or ssh aliased in a shell profile (credential capture)", technique: "T1056.001",
             floor: .high, kinds: [.persistence],
             matches: re(#"alias\s+(sudo|ssh|su)\s*="#)),
        Rule(name: "user launch agent impersonating Apple (com.apple.* label, not Apple-signed)", technique: "T1036.005",
             floor: .high, kinds: [.persistence],
             matches: { item, text in
                 item.path?.path.contains("/Users/") == true
                     && text.range(of: "label: com.apple.", options: .caseInsensitive) != nil
                     && text.range(of: "signer: Apple", options: .caseInsensitive) == nil
             }),
        Rule(name: "trusted root from known HTTPS-intercepting adware (Wajam, Superfish, Komodia, PrivDog, eDellRoot)",
             technique: "T1553.004", floor: .high, kinds: [.interception],
             matches: re(#"Trusted root: .*(wajam|superfish|komodia|privdog|edellroot)"#)),
        Rule(name: "system proxy or PAC pointing at this Mac (adware traffic interception, e.g. Pirrit)", technique: "T1557",
             floor: .medium, kinds: [.interception],
             matches: re(#"(HTTPS?Proxy|ProxyAutoConfigURLString|SOCKSProxy)\s*:\s*\S*(127\.0\.0\.1|localhost)"#)),
        Rule(name: "browser extension that can read and rewrite every page (ad injection, session theft)", technique: "T1176",
             floor: .medium, kinds: [.browser],
             matches: re(#"all websites[\s\S]*powerful permissions:.*(webRequest|declarativeNetRequest|debugger|proxy|cookies)"#)),
        Rule(name: "Silver Sparrow artefacts", technique: "T1543.001", floor: .high, kinds: [.persistence, .process],
             matches: re(#"(init_)?verx\.plist|/\._insu\b|/tmp/agent\.sh"#)),
        Rule(name: "unattended remote control (tech-support and banking fraud vehicle)", technique: "T1219",
             floor: .medium, kinds: [.remoteAccess],
             matches: re(#"running now:|starts automatically via:"#)),
        Rule(name: "screen recording, input monitoring or accessibility granted to an app", technique: "T1113",
             floor: .none, kinds: [.privacy],
             matches: re(#"Screen Recording|Input Monitoring|Synthetic input|Accessibility"#)),
    ]

    /// Signal text used for matches, so the UI and Haiku can tell list hits from heuristics.
    static func label(_ rule: Rule) -> String { "known technique: \(rule.name) (ATT&CK \(rule.technique))" }

    static func enrich(_ items: [AuditItem]) -> [AuditItem] {
        items.map { item in
            var item = item
            let text = ([item.title] + item.evidence + item.signals + [item.path?.path ?? ""]).joined(separator: "\n")
            for rule in rules where rule.kinds.contains(item.kind) && rule.matches(item, text) {
                let signal = label(rule)
                guard !item.signals.contains(signal) else { continue }
                item.signals.append(signal)
                item.severity = max(item.severity, rule.floor)
                item.routine = false
            }
            return item
        }
    }
}
