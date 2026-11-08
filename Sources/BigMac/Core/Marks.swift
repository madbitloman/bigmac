import CryptoKit
import Foundation
import Security

/// The user's "false positive" and "trust this binary" marks. They are stored in defaults and signed with a
/// secret kept in this Mac's Keychain, so a mark that another process writes into defaults doesn't count.
/// Each mark is also bound to what the item looked like when it was marked: a changed command line, signer or
/// risk signal voids it. It is not bound to the file's bytes, so replacing an unsigned binary with another unsigned
/// binary at the same path keeps the mark.
enum Marks {
    private static let service = "com.bigmac.marks"
    private static let account = "hmac-key"
    /// If the Keychain can't hold the secret, marks still work but only until BigMac quits.
    private static let key: SymmetricKey = stored() ?? SymmetricKey(size: .bits256)

    static func seal(_ content: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(content.utf8), using: key)).base64EncodedString()
    }

    static func verify(_ tag: String?, _ content: String) -> Bool {
        guard let tag, let mac = Data(base64Encoded: tag) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(content.utf8), using: key)
    }

    private static func stored() -> SymmetricKey? {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        var item: CFTypeRef?
        if SecItemCopyMatching(base.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        let fresh = SymmetricKey(size: .bits256)
        let data = fresh.withUnsafeBytes { Data($0) }
        let attrs = base.merging([kSecValueData as String: data,
                                  kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { $1 }
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess ? fresh : nil
    }
}

extension AuditItem {
    /// What a false-positive mark is bound to: the item's identity and risk-relevant content, without the parts
    /// that change on their own (age, pids, whether it happens to be running).
    var markContent: String {
        let volatileEvidence = ["created ", "pids:", "running now:", "state:"]
        var volatileSignals: Set<String> = ["installed in the last 7 days", "currently running"]
        if kind == .network { volatileSignals.insert(RiskSignal.unusualPort.rawValue) }  // depends on which connection was seen
        // Connections come and go between scans; a network item's mark is about the binary.
        let evidence = kind == .network ? evidence.filter { $0.hasPrefix("executable:") || $0.hasPrefix("signer:") }
            : evidence.filter { e in !volatileEvidence.contains(where: e.hasPrefix) }
        return (["audit", id, title] + evidence + ["--"] + signals.filter { !volatileSignals.contains($0) }.sorted())
            .joined(separator: "\n")
    }
}

extension ConnectionRow {
    /// A trusted binary stays trusted only while it has the same signer.
    static func trustContent(path: String, signer: Signer) -> String { "network\n\(path)\n\(signer.label)" }
}
