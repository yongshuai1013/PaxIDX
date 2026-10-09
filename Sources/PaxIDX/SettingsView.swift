import SwiftUI
import UniformTypeIdentifiers

/// 設定頁：SDK 管理 + 關於
struct SettingsView: View {
    @State private var sdkInstalled = SDKManager.shared.isInstalled
    @State private var isDownloading = false
    @State private var downloadProgress = 0.0
    @State private var sdkMessage = ""
    @State private var toolchainMessage = ""
    @State private var showImporter = false
    @State private var isImporting = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Darwin SDK")) {
                    HStack {
                        Text("狀態")
                        Spacer()
                        Text(sdkInstalled ? "已安裝" : "未安裝")
                            .foregroundColor(sdkInstalled ? .green : .orange)
                    }
                    if isDownloading {
                        HStack {
                            ProgressView(value: downloadProgress)
                            Text("\(Int(downloadProgress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 45, alignment: .trailing)
                        }
                    }
                    if !sdkMessage.isEmpty {
                        Text(sdkMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if !sdkInstalled && !isDownloading && !isImporting {
                        Button("下載 SDK（約 36MB）") {
                            downloadSDK()
                        }
                        Button("從文件導入 SDK（選擇 zip）") {
                            showImporter = true
                        }
                    }
                    if isImporting {
                        Text("正在導入…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if sdkInstalled {
                        Button("刪除 SDK", role: .destructive) {
                            try? SDKManager.shared.remove()
                            sdkInstalled = false
                        }
                    }
                    Text("SDK 從 GitHub release 下載，解壓到 App 容器")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Section(header: Text("編譯工具鏈")) {
                    HStack {
                        Text("狀態")
                        Spacer()
                        Text(paxidx_toolchain_available() == 1 ? "可用" : "不可用")
                            .foregroundColor(paxidx_toolchain_available() == 1 ? .green : .orange)
                    }
                    if !toolchainMessage.isEmpty {
                        Text(toolchainMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("工具鏈（Clang/LLD）內建於 App，點編譯時才載入，不佔啟動內存")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Section(header: Text("關於")) {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("0.1.0")
                            .foregroundColor(.secondary)
                    }
                    Text("在 iPhone 上編譯 iOS App（iOS 15+）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Section(header: Text("檔案管理")) {
                    NavigationLink(destination: FileBrowserView()) {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.accentColor)
                            Text("瀏覽 App 文件")
                        }
                    }
                    Text("SDK、專案、構建產物都在這裡")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("設定")
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                importSDK(result: result)
            }
        }
    }

    private func downloadSDK() {
        isDownloading = true
        sdkMessage = "下載中…"
        SDKManager.shared.downloadLatest(
            onProgress: { p in
                DispatchQueue.main.async { downloadProgress = p }
            },
            completion: { result in
                DispatchQueue.main.async {
                    isDownloading = false
                    switch result {
                    case .success(let url):
                        sdkInstalled = true
                        sdkMessage = "已安裝到：\(url.lastPathComponent)"
                    case .failure(let error):
                        sdkMessage = "失敗：\(error.localizedDescription)"
                    }
                }
            }
        )
    }

    private func importSDK(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // 檢查是否為 zip 文件
            let ext = url.pathExtension.lowercased()
            guard ext == "zip" else {
                sdkMessage = "請選擇 .zip 文件"
                return
            }
            isImporting = true
            sdkMessage = "正在導入…"
            // 在後台線程處理，避免阻塞 UI
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // 開始訪問安全作用域資源
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    try SDKManager.shared.importFrom(zip: url)
                    DispatchQueue.main.async {
                        isImporting = false
                        sdkInstalled = true
                        sdkMessage = "導入成功"
                    }
                } catch {
                    DispatchQueue.main.async {
                        isImporting = false
                        sdkMessage = "導入失敗：\(error.localizedDescription)"
                    }
                }
            }
        case .failure(let error):
            sdkMessage = "選擇文件失敗：\(error.localizedDescription)"
        }
    }
}

/// 文件操作剪貼板（單例，跨視圖共享）
final class FileClipboard: ObservableObject {
    static let shared = FileClipboard()
    @Published var copiedPath: String?
    @Published var copiedName: String?
    @Published var isCut = false  // true=剪切，false=複製
}

/// 可編輯的文本文件擴展名（常見的可讀寫格式）
private let editableExtensions: Set<String> = [
    "c", "h", "cpp", "hpp", "cc", "m", "mm", "swift",
    "txt", "md", "json", "xml", "plist", "yaml", "yml",
    "sh", "py", "js", "ts", "html", "css", "log", "ini", "cfg", "conf"
]

/// 判斷文件是否可編輯（按擴展名）
private func isEditableFile(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension.lowercased()
    return editableExtensions.contains(ext)
}

/// 通用文本文件編輯器（用於文件瀏覽器）
struct GenericFileEditorView: View {
    let filePath: String
    @Environment(\.presentationMode) var presentationMode
    @State private var content = ""
    @State private var message = ""

    var body: some View {
        VStack {
            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .padding(4)
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle((filePath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(
            trailing: Button("保存") { save() }
        )
        .onAppear(perform: load)
    }

    private func load() {
        content = (try? String(contentsOfFile: filePath, encoding: .utf8)) ?? ""
        if content.isEmpty {
            // 嘗試其他編碼
            content = (try? String(contentsOf: URL(fileURLWithPath: filePath))) ?? ""
        }
    }

    private func save() {
        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            message = "已保存"
            // 延遲關閉，讓用戶看到保存成功
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                presentationMode.wrappedValue.dismiss()
            }
        } catch {
            message = "保存失敗：\(error.localizedDescription)"
        }
    }
}

/// 文件瀏覽器：瀏覽 App Documents 目錄，支持刪除/重命名/複製/貼上，可編輯文本文件
struct FileBrowserView: View {
    @State private var currentPath: String
    @State private var items: [(name: String, isDir: Bool)] = []
    @StateObject private var clipboard = FileClipboard.shared
    @State private var showRenameAlert = false
    @State private var renameTarget = ""
    @State private var newName = ""
    @State private var message = ""
    @State private var editingFilePath: String = ""
    @State private var showFileEditor = false

    init(path: String? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        _currentPath = State(initialValue: path ?? docs.path)
    }

    var body: some View {
        List {
            ForEach(items, id: \.name) { item in
                if item.isDir {
                    NavigationLink(destination: FileBrowserView(path: (currentPath as NSString).appendingPathComponent(item.name))) {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.accentColor)
                            Text(item.name)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteItem(item.name)
                        } label: {
                            Label("刪除", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button("重命名") {
                            renameTarget = item.name
                            newName = item.name
                            showRenameAlert = true
                        }
                        Button("複製") {
                            copyItem(item.name, isCut: false)
                        }
                        Button("剪切") {
                            copyItem(item.name, isCut: true)
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: isEditableFile(item.name) ? "doc.text.fill" : "doc.fill")
                            .foregroundColor(isEditableFile(item.name) ? .accentColor : .secondary)
                        Text(item.name)
                            .foregroundColor(isEditableFile(item.name) ? .primary : .secondary)
                        if isEditableFile(item.name) {
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isEditableFile(item.name) {
                            editingFilePath = (currentPath as NSString).appendingPathComponent(item.name)
                            showFileEditor = true
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteItem(item.name)
                        } label: {
                            Label("刪除", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button("重命名") {
                            renameTarget = item.name
                            newName = item.name
                            showRenameAlert = true
                        }
                        Button("複製") {
                            copyItem(item.name, isCut: false)
                        }
                        Button("剪切") {
                            copyItem(item.name, isCut: true)
                        }
                    }
                }
            }
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle((currentPath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if clipboard.copiedPath != nil {
                    Button("貼上") {
                        pasteItem()
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .alert("重命名", isPresented: $showRenameAlert) {
            TextField("新名稱", text: $newName)
            Button("取消", role: .cancel) { }
            Button("確定") {
                renameItem(from: renameTarget, to: newName)
            }
        }
        .sheet(isPresented: $showFileEditor) {
            NavigationView {
                GenericFileEditorView(filePath: editingFilePath)
            }
        }
    }

    private func reload() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: currentPath)) ?? []
        items = contents.map { name in
            var isDir: ObjCBool = false
            let full = (currentPath as NSString).appendingPathComponent(name)
            fm.fileExists(atPath: full, isDirectory: &isDir)
            return (name, isDir.boolValue)
        }.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }
            return a.name < b.name
        }
        message = ""
    }

    private func deleteItem(_ name: String) {
        let fm = FileManager.default
        let full = (currentPath as NSString).appendingPathComponent(name)
        // 確認刪除（直接刪，iOS 原生左滑刪除通常不二次確認）
        do {
            try fm.removeItem(atPath: full)
            reload()
        } catch {
            message = "刪除失敗：\(error.localizedDescription)"
        }
    }

    private func renameItem(from oldName: String, to newName: String) {
        guard !newName.isEmpty, newName != oldName else { return }
        let fm = FileManager.default
        let oldPath = (currentPath as NSString).appendingPathComponent(oldName)
        let newPath = (currentPath as NSString).appendingPathComponent(newName)
        do {
            // 檢查目標是否已存在
            if fm.fileExists(atPath: newPath) {
                message = "重命名失敗：目標已存在"
                return
            }
            try fm.moveItem(atPath: oldPath, toPath: newPath)
            reload()
        } catch {
            message = "重命名失敗：\(error.localizedDescription)"
        }
    }

    private func copyItem(_ name: String, isCut: Bool) {
        let full = (currentPath as NSString).appendingPathComponent(name)
        clipboard.copiedPath = full
        clipboard.copiedName = name
        clipboard.isCut = isCut
        message = isCut ? "已剪切：\(name)" : "已複製：\(name)"
    }

    private func pasteItem() {
        guard let srcPath = clipboard.copiedPath,
              let name = clipboard.copiedName else { return }
        let fm = FileManager.default
        var destName = name
        var destPath = (currentPath as NSString).appendingPathComponent(destName)
        // 如果目標已存在，自動加後綴
        var counter = 1
        while fm.fileExists(atPath: destPath) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            destName = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            destPath = (currentPath as NSString).appendingPathComponent(destName)
            counter += 1
        }
        do {
            if clipboard.isCut {
                try fm.moveItem(atPath: srcPath, toPath: destPath)
                // 剪切後清空剪貼板
                clipboard.copiedPath = nil
                clipboard.copiedName = nil
            } else {
                try fm.copyItem(atPath: srcPath, toPath: destPath)
            }
            reload()
            message = "已貼上：\(destName)"
        } catch {
            message = "貼上失敗：\(error.localizedDescription)"
        }
    }
}
