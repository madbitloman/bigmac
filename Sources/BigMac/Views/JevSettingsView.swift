import SwiftUI

struct JevSettingsView: View {
    @Environment(JevSettings.self) private var jev
    @Environment(AuditModel.self) private var audit
    @AppStorage("showMenuBar") private var showMenuBar = true
    @State private var manualKey = ""
    @State private var providerKey = ""
    @State private var keyRevision = 0

    var body: some View {
        @Bindable var audit = audit
        PaneView(title: "Settings", status: "") {
            EmptyView()
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    section("General") {
                        setting("Menu bar item", "Keeps BigMac in the menu bar with quick scans; closing the window doesn't quit it.") {
                            Toggle("", isOn: $showMenuBar).toggleStyle(.switch).controlSize(.small).labelsHidden()
                        }
                    }
                    section("Security Audit · AI triage") {
                        setting("Provider", "Where flagged items are sent when you click Run audit or Ask AI.") {
                            Picker("", selection: $audit.provider) {
                                ForEach(InferenceProvider.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().pickerStyle(.menu).fixedSize()
                        }
                        if audit.provider == .openai {
                            setting("Base URL", "Ends in /v1. https, or http://localhost for Ollama and LM Studio.") {
                                field("https://api.openai.com/v1", text: $audit.openAIBaseURL, width: 260)
                            }
                            setting("Model", "Any model id the endpoint serves that supports tool calling.") {
                                field("model id", text: $audit.openAIModel, width: 260)
                            }
                        } else {
                            setting("Model", audit.provider == .bedrock || audit.provider == .anthropic ? "Haiku 5.5 is about 10× cheaper than Haiku 4.5 at list price." : nil) {
                                Picker("", selection: $audit.model) {
                                    ForEach(audit.provider.models, id: \.0) { Text($0.1).tag($0.0) }
                                }
                                .labelsHidden().pickerStyle(.menu).fixedSize()
                            }
                        }
                        if audit.provider == .bedrock {
                            setting("AWS", "Called with aws bedrock-runtime converse.") {
                                Text("\(TypeSafeKey.awsProfile) · \(TypeSafeKey.awsRegion)").font(Theme.mono).foregroundStyle(Theme.secondary)
                            }
                        } else {
                            setting("API key", keyStatus(audit.provider)) {
                                HStack(spacing: 6) {
                                    SecureField(audit.provider == .anthropic ? "sk-ant-…" : "sk-…", text: $providerKey)
                                        .textFieldStyle(.plain).font(Theme.mono)
                                        .padding(.horizontal, 8).frame(width: 200, height: 26)
                                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                                    Button {
                                        InferenceKeys.save(providerKey.trimmed, for: audit.provider)
                                        providerKey = ""
                                        keyRevision += 1
                                    } label: { ActionLabel("Save") }
                                    .buttonStyle(.primary).disabled(providerKey.trimmed.isEmpty)
                                    Button {
                                        InferenceKeys.delete(audit.provider)
                                        keyRevision += 1
                                    } label: { ActionLabel("Forget") }
                                    .buttonStyle(.ghost).disabled(InferenceKeys.read(audit.provider) == nil)
                                }
                                .id(keyRevision)
                            }
                        }
                        note("Flagged items go out under opaque ids with secrets and your home path redacted: launch-item commands, process paths, remote IPs, extension and certificate names. At most \(AuditTriage.maxCalls) calls of \(AuditTriage.batchSize) items per audit. API keys stay in your Keychain and are sent only to the provider you pick.")
                    }
                    section("TypeSafe Jev") {
                        setting("Status", nil) {
                            Pill(text: jev.status, tint: jev.client == nil ? Theme.tertiary : Theme.green)
                        }
                        setting("Model", nil) { Text(jev.client?.model ?? "–").font(Theme.mono).foregroundStyle(Theme.secondary) }
                        setting("API key", "SSM \(TypeSafeKey.ssmName), stored in your Keychain.") {
                            HStack(spacing: 6) {
                                if jev.busy { ProgressView().controlSize(.mini) }
                                Button { Task { await jev.fetchFromAWS() } } label: { ActionLabel("Fetch from AWS") }
                                    .buttonStyle(.ghost).disabled(jev.busy)
                                Button { jev.disconnect() } label: { ActionLabel("Forget") }
                                    .buttonStyle(.ghost).disabled(jev.client == nil)
                            }
                        }
                        setting("Paste key", nil) {
                            HStack(spacing: 6) {
                                SecureField("sk-…", text: $manualKey)
                                    .textFieldStyle(.plain).font(Theme.mono)
                                    .padding(.horizontal, 8).frame(width: 220, height: 26)
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                                Button {
                                    TypeSafeKey.keychainSave(manualKey)
                                    jev.connect(manualKey, source: "Keychain")
                                    manualKey = ""
                                } label: { ActionLabel("Save") }
                                .buttonStyle(.primary).disabled(manualKey.isEmpty)
                            }
                        }
                        note("Jev judges which cache items are safe to delete, which apps look like drivers or dependencies, and how suspicious a connection looks. Only on Ask Jev or Auto-Jev. Sends paths, app names, process paths and remote IPs to api.typesafe.ai.")
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 24)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
    }

    private func keyStatus(_ provider: InferenceProvider) -> String {
        if let env = provider.envKey, ProcessInfo.processInfo.environment[env]?.isEmpty == false { return "Using \(env) from the environment." }
        if InferenceKeys.read(provider) != nil { return "Saved in your Keychain." }
        return provider == .openai ? "Not needed for local servers." : "Not set."
    }

    private func field(_ placeholder: String, text: Binding<String>, width: CGFloat) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(Theme.mono)
            .padding(.horizontal, 8).frame(width: width, height: 26)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.label).foregroundStyle(Theme.secondary)
            VStack(spacing: 0) { content() }
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        }
    }

    private func setting<Control: View>(_ title: String, _ subtitle: String?, @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.body).foregroundStyle(Theme.text)
                    if let subtitle { Text(subtitle).font(Theme.small).foregroundStyle(Theme.secondary) }
                }
                Spacer()
                control()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Hairline()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.small).foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
    }
}
