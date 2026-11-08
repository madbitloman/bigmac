import Foundation

struct InferenceUsage: Sendable { var input = 0, output = 0 }

/// A model that answers with exactly one forced tool call; the audit triage only needs this.
protocol ToolModel: Sendable {
    var model: String { get }
    /// Fails unless the model actually stopped on the tool call, so a cut-off response is never mistaken for a verdict.
    func callTool(system: String, user: String, toolName: String, description: String,
                  schema: [String: Any], maxTokens: Int) throws -> ([String: Any], InferenceUsage)
}

struct InferenceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum InferenceProvider: String, CaseIterable, Identifiable, Sendable {
    case bedrock, anthropic, openai
    var id: String { rawValue }

    var title: String {
        switch self {
        case .bedrock: "Amazon Bedrock (aws CLI)"
        case .anthropic: "Anthropic API key"
        case .openai: "OpenAI-compatible (OpenAI, OpenRouter, Ollama…)"
        }
    }

    /// Model ids offered in the picker; an OpenAI-compatible endpoint takes any id typed in Settings.
    var models: [(String, String)] {
        switch self {
        case .bedrock: BedrockClient.models
        case .anthropic: [("claude-haiku-5-5", "Claude Haiku 5.5 ($0.10 / $0.50 per M tokens)"),
                          ("claude-haiku-4-5", "Claude Haiku 4.5 ($1 / $5 per M tokens)")]
        case .openai: []
        }
    }

    /// Key looked up in the environment before the Keychain, so a key never has to be typed into the app.
    var envKey: String? {
        switch self {
        case .bedrock: nil
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openai: "OPENAI_API_KEY"
        }
    }

    var needsKey: Bool { self != .bedrock }
}

/// List price per million tokens (input, output) for the models we offer; nil means unknown, so no cost is shown.
func listPrice(model: String) -> (Double, Double)? {
    if model.contains("haiku-5") { return (0.10, 0.50) }
    if model.contains("haiku-4-5") { return (1, 5) }
    return nil
}

/// API keys for inference providers, one Keychain item each. Never written to disk or defaults.
///
/// An OpenAI-compatible key belongs to the server it was saved for: the Keychain account carries that server's
/// origin, so pointing the base URL somewhere else (in Settings, or behind the app's back with `defaults write`)
/// finds no key instead of sending yours there. `OPENAI_API_KEY` from the environment only goes to api.openai.com.
enum InferenceKeys {
    private static let service = "com.bigmac.inference"
    static let openAIOrigin = "https://api.openai.com"

    /// scheme://host[:port], lowercased, default port dropped. Nil for anything that isn't http(s) with a host.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port.flatMap { (scheme == "https" && $0 == 443) || (scheme == "http" && $0 == 80) ? nil : $0 }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }

    /// Keychain account for a provider's key; the OpenAI-compatible one is per server.
    static func account(_ provider: InferenceProvider, server: URL? = nil) -> String? {
        switch provider {
        case .bedrock: return nil
        case .anthropic: return provider.rawValue
        case .openai: return server.flatMap(origin).map { "\(provider.rawValue) \($0)" }
        }
    }

    /// Whether the provider's environment variable applies to this request.
    static func envKeyApplies(_ provider: InferenceProvider, server: URL? = nil) -> Bool {
        provider != .openai || server.flatMap(origin) == openAIOrigin
    }

    static func resolve(_ provider: InferenceProvider, server: URL? = nil) -> String? {
        if envKeyApplies(provider, server: server), let name = provider.envKey,
           let env = ProcessInfo.processInfo.environment[name], !env.isEmpty { return env }
        return read(provider, server: server)
    }

    static func read(_ provider: InferenceProvider, server: URL? = nil) -> String? {
        guard let account = account(provider, server: server) else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the saved key; the old one is kept if the new one can't be stored.
    @discardableResult
    static func save(_ key: String, for provider: InferenceProvider, server: URL? = nil) -> Bool {
        guard let account = account(provider, server: server) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        let value: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        switch SecItemUpdate(query as CFDictionary, value as CFDictionary) {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            let attrs = query.merging(value) { $1 }.merging([kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { $1 }
            return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
        default:
            return false
        }
    }

    static func delete(_ provider: InferenceProvider, server: URL? = nil) {
        // The pre-0.1.1 OpenAI key wasn't tied to a server; drop it too, it is never used.
        let accounts = [account(provider, server: server), provider == .openai ? provider.rawValue : nil].compactMap { $0 }
        for account in accounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}

/// Blocking JSON POST; triage already runs off the main actor.
enum HTTPJSON {
    /// Requests carry an API key, so a redirect is an error rather than a reason to send it to another host.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    static func post(_ url: URL, headers: [String: String], body: [String: Any], timeout: TimeInterval = 90) throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        nonisolated(unsafe) var result: Result<(Data, HTTPURLResponse), Error> = .failure(InferenceError(message: "no response"))
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            if let error { result = .failure(error) }
            else if let data, let http = response as? HTTPURLResponse { result = .success((data, http)) }
            done.signal()
        }.resume()
        done.wait()

        let (data, http) = try result.get()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode), let json else {
            // Provider error messages, never the request (which holds the key in a header).
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw InferenceError(message: "\(url.host() ?? "provider") returned \(http.statusCode): \(message)")
        }
        return json
    }
}

/// Anthropic Messages API with the user's own key.
struct AnthropicClient: ToolModel {
    var model: String
    let key: String

    func callTool(system: String, user: String, toolName: String, description: String,
                  schema: [String: Any], maxTokens: Int = 4096) throws -> ([String: Any], InferenceUsage) {
        let body: [String: Any] = [
            "model": model, "max_tokens": maxTokens, "system": system,
            "messages": [["role": "user", "content": user]],
            "tools": [["name": toolName, "description": description, "input_schema": schema]],
            "tool_choice": ["type": "tool", "name": toolName],
            // A forced tool call doesn't need thinking, and it would eat the token budget.
            "thinking": ["type": "disabled"],
        ]
        let response = try HTTPJSON.post(URL(string: "https://api.anthropic.com/v1/messages")!,
                                         headers: ["x-api-key": key, "anthropic-version": "2023-06-01"], body: body)
        let usage = response["usage"] as? [String: Any]
        let tokens = InferenceUsage(input: usage?["input_tokens"] as? Int ?? 0, output: usage?["output_tokens"] as? Int ?? 0)
        let stop = response["stop_reason"] as? String ?? "?"
        let content = response["content"] as? [[String: Any]] ?? []
        guard stop == "tool_use", let input = content.first(where: { $0["type"] as? String == "tool_use" })?["input"] as? [String: Any] else {
            throw InferenceError(message: "Anthropic stopped with \(stop) instead of a tool call")
        }
        return (input, tokens)
    }
}

/// Any endpoint speaking the OpenAI chat-completions format with function calling.
struct OpenAICompatibleClient: ToolModel {
    var model: String
    let baseURL: URL
    let key: String?

    func callTool(system: String, user: String, toolName: String, description: String,
                  schema: [String: Any], maxTokens: Int = 4096) throws -> ([String: Any], InferenceUsage) {
        let body: [String: Any] = [
            "model": model, "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "tools": [["type": "function", "function": ["name": toolName, "description": description, "parameters": schema]]],
            "tool_choice": ["type": "function", "function": ["name": toolName]],
        ]
        let headers = key.map { ["authorization": "Bearer \($0)"] } ?? [:]
        let response = try HTTPJSON.post(baseURL.appending(path: "chat/completions"), headers: headers, body: body)
        let usage = response["usage"] as? [String: Any]
        let tokens = InferenceUsage(input: usage?["prompt_tokens"] as? Int ?? 0, output: usage?["completion_tokens"] as? Int ?? 0)
        let choice = (response["choices"] as? [[String: Any]])?.first
        let finish = choice?["finish_reason"] as? String ?? "?"
        let call = ((choice?["message"] as? [String: Any])?["tool_calls"] as? [[String: Any]])?
            .first { ($0["function"] as? [String: Any])?["name"] as? String == toolName }
        // A forced call may report finish_reason "stop"; "length" means the arguments were cut off.
        guard finish != "length", let arguments = (call?["function"] as? [String: Any])?["arguments"] as? String,
              let input = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else {
            throw InferenceError(message: "\(baseURL.host() ?? "provider") stopped with \(finish) instead of a complete tool call")
        }
        return (input, tokens)
    }
}
