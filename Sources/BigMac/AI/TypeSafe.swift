import Foundation
import Security

/// Minimal JSON value so `state` can be built from typed Swift data.
enum JSON: Sendable, Encodable {
    case string(String), number(Double), bool(Bool), array([JSON]), object([String: JSON]), null

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

enum TSQuestion: Sendable, Encodable {
    case noul(String)
    case score(String, levels: [String])
    case choice(String, options: [String: String])

    private enum Keys: String, CodingKey { case type, instructions, criteria }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .noul(let i):
            try c.encode("noul", forKey: .type); try c.encode(i, forKey: .instructions)
        case .score(let i, let levels):
            try c.encode("score", forKey: .type); try c.encode(i, forKey: .instructions); try c.encode(levels, forKey: .criteria)
        case .choice(let i, let options):
            try c.encode("choice", forKey: .type); try c.encode(i, forKey: .instructions); try c.encode(options, forKey: .criteria)
        }
    }
}

struct TSAnswer: Decodable, Sendable {
    let type: String
    let noul: Double?
    let score: Double?
    let choice: String?
    let confidence: Double?
}

struct TypeSafeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Client for TypeSafe's System One endpoint (Jev).
struct TypeSafeClient: Sendable {
    let apiKey: String
    var model = "jev-latest"

    private struct Request: Encodable {
        let model: String
        let state: JSON
        let questions: [String: TSQuestion]
    }

    private struct Response: Decodable {
        let answers: [String: TSAnswer]
    }

    func ask(state: JSON, questions: [String: TSQuestion]) async throws -> [String: TSAnswer] {
        var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(model: model, state: state, questions: questions))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TypeSafeError(message: "TypeSafe HTTP \(code): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return try JSONDecoder().decode(Response.self, from: data).answers
    }

    /// Asks the same question shape about many items, chunked so each request stays small.
    /// `makeQuestion` receives the backticked state path of the item, e.g. `` `items[3]` ``.
    func askEach<Item>(
        _ items: [Item], key: String, chunk: Int = 20,
        encode: (Item) -> JSON, makeQuestion: (String) -> TSQuestion
    ) async throws -> [TSAnswer?] {
        var answers: [TSAnswer?] = []
        for start in stride(from: 0, to: items.count, by: chunk) {
            let slice = Array(items[start..<min(start + chunk, items.count)])
            var questions: [String: TSQuestion] = [:]
            for i in slice.indices { questions["q\(i)"] = makeQuestion("`\(key)[\(i)]`") }
            let result = try await ask(state: .object([key: .array(slice.map(encode))]), questions: questions)
            answers += slice.indices.map { result["q\($0)"] }
        }
        return answers
    }
}

/// Resolves the TypeSafe API key: env var → Keychain → one-time fetch from AWS SSM.
/// The AWS profile and parameter name are per-machine settings (`defaults write com.bigmac.app awsProfile …`).
enum TypeSafeKey {
    static var ssmName: String { UserDefaults.standard.string(forKey: "typesafeSSMName") ?? "/bigmac/typesafe-api-key" }
    static var awsProfile: String { UserDefaults.standard.string(forKey: "awsProfile") ?? "default" }
    static let awsRegion = "us-east-1"
    private static let service = "com.bigmac.typesafe"
    private static let account = "api-key"

    static func resolveLocal(useKeychain: Bool = true) -> String? {
        if let env = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !env.isEmpty { return env }
        return useKeychain ? keychainRead() : nil
    }

    static func fetchFromAWS() throws -> String {
        let data = try AWSCLI.run(["ssm", "get-parameter", "--name", ssmName, "--with-decryption",
                                   "--profile", awsProfile, "--region", awsRegion,
                                   "--query", "Parameter.Value", "--output", "text"])
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TypeSafeError(message: "aws ssm returned an empty key") }
        return key
    }

    static func keychainRead() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func keychainSave(_ key: String) -> Bool {
        keychainDelete()
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: Data(key.utf8),
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func keychainDelete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
