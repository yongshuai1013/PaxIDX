import SwiftUI

/// 專案 AI 對話頁：帶入專案源文件＋最近編譯日誌作為上下文，串流回覆
struct AIChatView: View {
    let project: Project
    @State private var messages: [AIMessage] = []
    @State private var input = ""
    @State private var streaming = false
    @State private var liveText = ""
    @State private var errorText = ""
    @State private var attachFiles = true
    @State private var attachLog = true
    @State private var copiedStamp = ""
    @State private var sendTask: Task<Void, Never>?

    private var historyURL: URL {
        ProjectFiles.directory(for: project.name).appendingPathComponent(".aichat.json")
    }
    private var hasLog: Bool { BuildLogStore.shared.lastLog(for: project.name) != nil }

    var body: some View {
        VStack(spacing: 0) {
            if !AIConfig.isConfigured {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text("尚未設定 API key")
                        .font(.caption)
                    Spacer()
                    NavigationLink("去設定", destination: AISettingsView())
                        .font(.caption)
                }
                .padding(8)
                .background(Color.yellow.opacity(0.25))
            }
            contextBar
            messageList
            if !errorText.isEmpty {
                Text(errorText)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }
            inputBar
        }
        .navigationTitle("AI 助手")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    messages = []
                    liveText = ""
                    errorText = ""
                    saveHistory()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(streaming || messages.isEmpty)
            }
        }
        .onAppear(perform: loadHistory)
    }

    private var contextBar: some View {
        HStack(spacing: 8) {
            Text("上下文：")
                .font(.caption)
                .foregroundColor(.secondary)
            Toggle("專案檔案", isOn: $attachFiles)
                .toggleStyle(.button)
                .font(.caption)
            if hasLog {
                Toggle("編譯日誌", isOn: $attachLog)
                    .toggleStyle(.button)
                    .font(.caption)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty && !streaming {
                        Text("問任何關於這個專案的問題，例如：這個編譯錯誤是什麼意思？幫我寫一個登入畫面。")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .padding(.vertical)
                    }
                    ForEach(messages) { m in
                        bubble(m)
                    }
                    if streaming {
                        HStack {
                            Text(liveText.isEmpty ? "思考中…" : liveText)
                                .textSelection(.enabled)
                                .padding(10)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                            Spacer(minLength: 40)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: messages.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: liveText) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("輸入問題", text: $input)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .disabled(streaming)
            if streaming {
                Button("停止") { stop() }
            } else {
                Button("發送") { send() }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    private func bubble(_ m: AIMessage) -> some View {
        HStack {
            if m.role == "user" { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                Text(m.content)
                    .textSelection(.enabled)
                if m.role == "assistant" {
                    ForEach(Array(codeBlocks(m.content).enumerated()), id: \.offset) { pair in
                        Button {
                            UIPasteboard.general.string = pair.element
                            copiedStamp = "\(m.id)-\(pair.offset)"
                        } label: {
                            Label(copiedStamp == "\(m.id)-\(pair.offset)" ? "已複製" : "複製代碼",
                                  systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                    }
                }
            }
            .padding(10)
            .background(m.role == "user" ? Color.accentColor.opacity(0.18)
                                         : Color(.secondarySystemBackground))
            .cornerRadius(12)
            if m.role != "user" { Spacer(minLength: 40) }
        }
    }

    /// 抽出 markdown 代碼塊內容（去掉語言標記行）
    private func codeBlocks(_ text: String) -> [String] {
        let parts = text.components(separatedBy: "```")
        guard parts.count > 2 else { return [] }
        var result: [String] = []
        for i in stride(from: 1, to: parts.count, by: 2) {
            var block = parts[i]
            if let nl = block.firstIndex(of: "\n") {
                let firstLine = block[..<nl]
                if firstLine.count <= 12 && !firstLine.contains(" ") {
                    block = String(block[block.index(after: nl)...])
                }
            }
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
        }
        return result
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !streaming else { return }
        guard AIConfig.isConfigured else {
            errorText = "尚未設定 API key，請先到設定頁填寫"
            return
        }
        input = ""
        errorText = ""
        messages.append(AIMessage(role: "user", content: text))
        saveHistory()
        let apiMessages = buildAPIMessages()
        streaming = true
        liveText = ""
        sendTask = Task {
            do {
                let full = try await AIChatClient.streamChat(
                    endpoint: AIConfig.endpoint, apiKey: AIConfig.apiKey, model: AIConfig.model,
                    messages: apiMessages
                ) { piece in
                    DispatchQueue.main.async { liveText += piece }
                }
                await MainActor.run {
                    if !full.isEmpty {
                        messages.append(AIMessage(role: "assistant", content: full))
                    }
                    liveText = ""
                    streaming = false
                    saveHistory()
                }
            } catch {
                let e = error
                await MainActor.run {
                    if e is CancellationError || (e as? URLError)?.code == .cancelled {
                        streaming = false
                    } else {
                        errorText = "AI 請求失敗：\(e.localizedDescription)"
                        streaming = false
                    }
                }
            }
        }
    }

    private func stop() {
        sendTask?.cancel()
        if !liveText.isEmpty {
            messages.append(AIMessage(role: "assistant", content: liveText))
            liveText = ""
            saveHistory()
        }
        streaming = false
    }

    private func buildAPIMessages() -> [(role: String, content: String)] {
        var result: [(role: String, content: String)] = [(role: "system", content: systemPrompt())]
        for m in messages.suffix(20) {
            result.append((role: m.role, content: m.content))
        }
        return result
    }

    private func systemPrompt() -> String {
        var parts: [String] = []
        parts.append("你是 PaxIDX 的 AI 編程助手。PaxIDX 是在 iPhone 上運行（iOS 15）的編譯器 App，能把 C／Objective-C／Swift 專案編譯、連結、打包成 IPA。用正體中文回答；給代碼時用 markdown 代碼塊並註明檔名；回答具體、能直接照做，不要空泛。")
        parts.append("專案名稱：\(project.name)，Bundle ID：\(project.bundleID)")
        if attachFiles {
            let dir = ProjectFiles.sourcesDirectory(for: project.name)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            var total = 0
            for name in names.sorted() {
                guard let content = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { continue }
                let clipped = String(content.prefix(8000))
                total += clipped.count
                if total > 30000 { break }
                parts.append("檔案 Sources/\(name)：\n```\n\(clipped)\n```")
            }
        }
        if attachLog, let log = BuildLogStore.shared.lastLog(for: project.name) {
            parts.append("最近一次編譯日誌（結尾部分）：\n```\n\(String(log.suffix(6000)))\n```")
        }
        return parts.joined(separator: "\n\n")
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(messages) {
            try? data.write(to: historyURL)
        }
    }

    private func loadHistory() {
        if let data = try? Data(contentsOf: historyURL),
           let saved = try? JSONDecoder().decode([AIMessage].self, from: data) {
            messages = saved
        }
    }
}
