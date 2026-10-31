import Foundation
import Security

// MARK: - AI 設定（BYOK：自帶 API key，OpenAI 兼容端點）

/// AI 助手設定：端點與模型存 UserDefaults，API key 只存 Keychain
enum AIConfig {
    private static let endpointKey = "ai.endpoint"
    private static let modelKey = "ai.model"

    /// 預設端點：DeepSeek 的 OpenAI 兼容入口
    static let defaultEndpoint = "https://api.deepseek.com/v1/chat/completions"
    static let defaultModel = "deepseek-chat"

    static var endpoint: String {
        get { UserDefaults.standard.string(forKey: endpointKey) ?? defaultEndpoint }
        set { UserDefaults.standard.set(newValue, forKey: endpointKey) }
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    static var apiKey: String {
        get { KeychainStore.get("ai.apiKey") ?? "" }
        set { KeychainStore.set("ai.apiKey", newValue) }
    }

    /// 免 key 服務（Pollinations／LLM7）：不用 key 也能打
    static var isKeylessEndpoint: Bool {
        guard let host = URL(string: endpoint)?.host else { return false }
        return host.contains("pollinations.ai") || host.contains("llm7.io")
    }

    static var isConfigured: Bool { !apiKey.isEmpty || isKeylessEndpoint }
}

/// 簡易 Keychain 存取（generic password）
enum KeychainStore {
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        _ = SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attrs = query
        attrs[kSecValueData as String] = Data(value.utf8)
        _ = SecItemAdd(attrs as CFDictionary, nil)
    }
}

// MARK: - 最近編譯日誌

/// 最近一次編譯日誌（BuildView 在編譯結束時寫入，AI 對話頁讀取作為上下文）
final class BuildLogStore {
    static let shared = BuildLogStore()
    private var logs: [String: String] = [:]
    private let queue = DispatchQueue(label: "paxidx.buildlogstore")

    func save(project: String, log: String) {
        queue.sync { logs[project] = log }
    }

    func lastLog(for project: String) -> String? {
        queue.sync { logs[project] }
    }
}

// MARK: - 對話訊息與客戶端

/// 一則對話訊息（顯示與持久化共用）
struct AIMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: String   // "user" | "assistant"
    var content: String
}

/// OpenAI 兼容 chat/completions 客戶端（串流回覆）
enum AIChatClient {
    enum AIError: LocalizedError {
        case notConfigured
        case badURL
        case http(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "尚未設定 API key"
            case .badURL: return "端點 URL 不正確"
            case .http(let code, let body): return "HTTP \(code)：\(String(body.prefix(300)))"
            case .badResponse: return "回應格式不正確"
            }
        }
    }

    /// 組出一次請求（串流與否共用）
    private static func makeRequest(endpoint: String, apiKey: String, model: String,
                                    messages: [(role: String, content: String)],
                                    stream: Bool) throws -> URLRequest {
        let keylessHost = URL(string: endpoint)?.host ?? ""
        let keyless = keylessHost.contains("pollinations.ai") || keylessHost.contains("llm7.io")
        guard !apiKey.isEmpty || keyless else { throw AIError.notConfigured }
        guard let url = URL(string: endpoint) else { throw AIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let payload: [String: Any] = [
            "model": model,
            "stream": stream,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return req
    }

    /// 串流對話：逐段回調 onDelta，回傳完整回覆
    static func streamChat(endpoint: String, apiKey: String, model: String,
                           messages: [(role: String, content: String)],
                           onDelta: @escaping (String) -> Void) async throws -> String {
        let req = try makeRequest(endpoint: endpoint, apiKey: apiKey, model: model,
                                  messages: messages, stream: true)
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
        if http.statusCode != 200 {
            var body = Data()
            for try await b in bytes { body.append(b) }
            throw AIError.http(http.statusCode, String(data: body, encoding: .utf8) ?? "")
        }
        var full = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" { break }
            guard let jsonData = data.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let piece = delta["content"] as? String else { continue }
            full += piece
            onDelta(piece)
        }
        return full
    }

    /// 測試連線：送一則 ping，回傳模型回覆
    static func testConnection(endpoint: String, apiKey: String, model: String) async throws -> String {
        let req = try makeRequest(endpoint: endpoint, apiKey: apiKey, model: model,
                                  messages: [(role: "user", content: "ping")], stream: false)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
        if http.statusCode != 200 {
            throw AIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw AIError.badResponse }
        return content
    }
}
