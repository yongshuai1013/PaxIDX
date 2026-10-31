import SwiftUI

/// AI 助手設定頁：選服務預設或自訂端點，填模型與 API key（存 Keychain），可測試連線
struct AISettingsView: View {
    private enum Preset: String, CaseIterable, Identifiable {
        case deepseek = "DeepSeek"
        case openai = "OpenAI"
        case pollinations = "Pollinations（免 key）"
        case llm7 = "LLM7（免 key）"
        case custom = "自訂"
        var id: String { rawValue }
    }

    @State private var preset: Preset = .deepseek
    @State private var endpoint = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var status = ""
    @State private var testing = false

    private var endpointIsKeyless: Bool {
        guard let host = URL(string: endpoint)?.host else { return false }
        return host.contains("pollinations.ai") || host.contains("llm7.io")
    }

    var body: some View {
        Form {
            Section(header: Text("服務")) {
                Picker("預設", selection: $preset) {
                    ForEach(Preset.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .onChange(of: preset) { applyPreset($0) }
                TextField("端點 URL", text: $endpoint)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("模型", text: $model)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            Section(header: Text("API Key")) {
                SecureField("API Key", text: $apiKey)
                Text("key 只存本機 Keychain；呼叫時只送往你填的端點")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if endpointIsKeyless {
                    Text("此服務免 key，API key 欄可以留空")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Section {
                Button("儲存") {
                    save()
                    status = "已儲存"
                }
                Button(testing ? "測試中…" : "測試連線") { test() }
                    .disabled(testing || (apiKey.isEmpty && !endpointIsKeyless))
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Section(header: Text("說明")) {
                Text("在專案頁點「AI 助手」開啟對話。對話會帶入專案源文件與最近一次編譯日誌作為上下文，幫忙解讀編譯錯誤、給修改建議。")
                Text("Pollinations 與 LLM7 是免 key 預設，免註冊可直接用；Pollinations 模型較弱，LLM7 匿名有限額、同時只能一個請求，模型偶爾會暫時不可用。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("AI 助手設定")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        endpoint = AIConfig.endpoint
        model = AIConfig.model
        apiKey = AIConfig.apiKey
        if endpoint == AIConfig.defaultEndpoint {
            preset = .deepseek
        } else if endpoint == "https://api.openai.com/v1/chat/completions" {
            preset = .openai
        } else if endpoint == "https://text.pollinations.ai/openai/chat/completions" {
            preset = .pollinations
        } else if endpoint == "https://api.llm7.io/v1/chat/completions" {
            preset = .llm7
        } else {
            preset = .custom
        }
    }

    private func applyPreset(_ p: Preset) {
        switch p {
        case .deepseek:
            endpoint = AIConfig.defaultEndpoint
            model = AIConfig.defaultModel
        case .openai:
            endpoint = "https://api.openai.com/v1/chat/completions"
            model = "gpt-4o-mini"
        case .pollinations:
            endpoint = "https://text.pollinations.ai/openai/chat/completions"
            model = "openai-fast"
        case .llm7:
            endpoint = "https://api.llm7.io/v1/chat/completions"
            model = "GLM-5.3-Flash"
        case .custom:
            break
        }
    }

    private func save() {
        AIConfig.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        AIConfig.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        AIConfig.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func test() {
        testing = true
        status = ""
        let ep = endpoint, md = model, key = apiKey
        Task {
            do {
                let reply = try await AIChatClient.testConnection(endpoint: ep, apiKey: key, model: md)
                await MainActor.run {
                    status = "連線成功，模型回覆：\(String(reply.prefix(80)))"
                    testing = false
                }
            } catch {
                await MainActor.run {
                    status = "連線失敗：\(error.localizedDescription)"
                    testing = false
                }
            }
        }
    }
}
