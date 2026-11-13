import SwiftUI

/// The Settings window (BigMac > Settings…, ⌘,): standard tabs of grouped forms, like System Settings.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            TriageSettings().tabItem { Label("AI Triage", systemImage: "sparkle") }
            JevSettingsTab().tabItem { Label("TypeSafe Jev", systemImage: "brain") }
        }
        .frame(width: 620)
        .frame(minHeight: 380)
    }
}

private struct GeneralSettings: View {
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showMenuBar) {
                    Text("Show BigMac in the menu bar")
                    Text("Quick scans and a Mac summary. Closing the window keeps BigMac in the menu bar.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct TriageSettings: View {
    @Environment(AuditModel.self) private var audit
    @State private var providerKey = ""
    @State private var keyRevision = 0

    var body: some View {
        @Bindable var audit = audit
        Form {
            Section {
                Picker("Provider", selection: $audit.provider) {
                    ForEach(InferenceProvider.allCases) { Text($0.title).tag($0) }
                }
                if audit.provider == .openai {
                    TextField("Base URL", text: $audit.openAIBaseURL, prompt: Text("https://api.openai.com/v1"))
                        .font(Theme.mono)
                    TextField("Model", text: $audit.openAIModel, prompt: Text("model id"))
                        .font(Theme.mono)
                } else {
                    Picker("Model", selection: $audit.model) {
                        ForEach(audit.provider.models, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                if audit.provider == .bedrock {
                    LabeledContent("AWS") {
                        Text("\(TypeSafeKey.awsProfile) · \(TypeSafeKey.awsRegion)").font(Theme.mono).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Security Audit")
            } footer: {
                Text(audit.provider == .openai
                     ? "The base URL ends in /v1: https, or http://localhost for Ollama and LM Studio. The model must support tool calling."
                     : "Where flagged items go when you click Run audit or Ask AI. Haiku 5.5 is about 10× cheaper than Haiku 4.5 at list price.")
                    .formFooter()
            }
            if audit.provider != .bedrock {
                Section {
                    LabeledContent("Status") { Text(keyStatus).foregroundStyle(.secondary) }
                    HStack {
                        SecureField("API key", text: $providerKey, prompt: Text(audit.provider == .anthropic ? "sk-ant-…" : "sk-…"))
                            .font(Theme.mono)
                        Button("Save") {
                            InferenceKeys.save(providerKey.trimmed, for: audit.provider, server: keyServer)
                            providerKey = ""
                            keyRevision += 1
                        }
                        .disabled(providerKey.trimmed.isEmpty || (audit.provider == .openai && keyServer.flatMap(InferenceKeys.origin) == nil))
                        Button("Forget") {
                            InferenceKeys.delete(audit.provider, server: keyServer)
                            keyRevision += 1
                        }
                        .disabled(InferenceKeys.read(audit.provider, server: keyServer) == nil)
                    }
                } header: {
                    Text("API Key")
                }
                .id(keyRevision)
            }
            Section {
                Text("Flagged items go out under opaque ids with secrets and your home path redacted: launch-item commands, process paths, remote IPs, extension and certificate names. At most \(AuditTriage.maxCalls) calls of \(AuditTriage.batchSize) items per audit. API keys stay in your Keychain. An OpenAI-compatible key is saved for one server and only ever sent there; change the base URL and it needs its own key.")
                    .font(Theme.small).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The server an OpenAI-compatible key is saved for: the base URL, parsed exactly as AuditModel.client parses it.
    private var keyServer: URL? { audit.provider == .openai ? URL(string: audit.openAIBaseURL) : nil }

    private var keyStatus: String {
        let provider = audit.provider, server = keyServer
        if InferenceKeys.envKeyApplies(provider, server: server), let env = provider.envKey,
           ProcessInfo.processInfo.environment[env]?.isEmpty == false { return "Using \(env) from the environment." }
        let origin = server.flatMap(InferenceKeys.origin)
        if InferenceKeys.read(provider, server: server) != nil { return origin.map { "Saved in your Keychain for \($0)." } ?? "Saved in your Keychain." }
        guard provider == .openai else { return "Not set." }
        return origin.map { "No key for \($0). Local servers usually need none." } ?? "Enter a valid base URL first."
    }
}

private struct JevSettingsTab: View {
    @Environment(JevSettings.self) private var jev
    @State private var manualKey = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") { Pill(text: jev.status, tint: jev.client == nil ? Theme.tertiary : Theme.green) }
                LabeledContent("Model") { Text(jev.client?.model ?? "–").font(Theme.mono).foregroundStyle(.secondary) }
                LabeledContent {
                    HStack {
                        if jev.busy { ProgressView().controlSize(.small) }
                        Button("Fetch from AWS") { Task { await jev.fetchFromAWS() } }.disabled(jev.busy)
                        Button("Forget") { jev.disconnect() }.disabled(jev.client == nil)
                    }
                } label: {
                    Text("API key")
                    Text("SSM \(TypeSafeKey.ssmName), stored in your Keychain.")
                }
                HStack {
                    SecureField("Paste key", text: $manualKey, prompt: Text("sk-…")).font(Theme.mono)
                    Button("Save") {
                        TypeSafeKey.keychainSave(manualKey)
                        jev.connect(manualKey, source: "Keychain")
                        manualKey = ""
                    }
                    .disabled(manualKey.isEmpty)
                }
            } footer: {
                Text("Jev judges which cache items are safe to delete, which apps look like drivers or dependencies, and how suspicious a connection looks. It runs only when you click Ask Jev or turn on Auto-Jev, and sends paths, app names, process paths and remote IPs to api.typesafe.ai.")
                    .formFooter()
            }
        }
        .formStyle(.grouped)
    }
}
