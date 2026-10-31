import SwiftUI
import Highlightr
import UniformTypeIdentifiers

// 測試 LocalizedError 是否導致 iOS 15 閃退
enum TestLocalizedError: LocalizedError {
    case testFailure
    var errorDescription: String? { "Test error" }
}

// 強制使用，防優化掉
func _testThrow() throws {
    throw TestLocalizedError.testFailure
}
let _testError: Error = TestLocalizedError.testFailure



/// 設定頁：SDK 下載 + 實驗 + 關於 + 檔案管理
struct SettingsView: View {
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("編輯器")) {
                    NavigationLink(destination: EditorSettingsView()) {
                        Text("編輯器主題")
                    }
                    Text("程式碼高亮主題：跟隨系統，或 Highlightr 全部內建主題擇一（附即時預覽）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Section(header: Text("SDK")) {
                    NavigationLink(destination: SDKDownloadView()) {
                        Text("下載 SDK")
                    }
                    Text("編譯用的 SDK（26／27 世代並存）從 GitHub release 下載解壓；用哪一版在建立專案時選擇")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Section(header: Text("實驗")) {
                    NavigationLink(destination: NyxLoadTestView()) {
                        Text("Nyxian CoreCompiler 載入實測")
                    }
                    Text("自編 CoreCompiler（Swift 6.4）的載入與試編實測頁")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Section(header: Text("簽名")) {
                    NavigationLink(destination: CertSignView()) {
                        Text("簽名證書（導入＋真簽名）")
                    }
                    Text("導入開發者證書（.p12）與描述檔，產出改用證書真簽名（照 ZSign 作法）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Section(header: Text("AI")) {
                    NavigationLink(destination: AISettingsView()) {
                        Text("AI 助手設定")
                    }
                    Text("自帶 API key（BYOK）：在專案頁開 AI 對話，帶入專案檔案與編譯日誌解讀錯誤")
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteItem(item.name)
                        } label: {
                            Label("刪除", systemImage: "trash")
                        }
                    }
                } else {
                    Button(action: {
                        if isEditableFile(item.name) {
                            editingFilePath = (currentPath as NSString).appendingPathComponent(item.name)
                            showFileEditor = true
                        }
                    }) {
                        HStack {
                            Image(systemName: isEditableFile(item.name) ? "doc.text.fill" : "doc.fill")
                                .foregroundColor(isEditableFile(item.name) ? .accentColor : .secondary)
                            Text(item.name)
                                .foregroundColor(isEditableFile(item.name) ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
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
        .sheet(isPresented: $showRenameAlert) {
            NavigationView {
                Form {
                    Section(header: Text("新名稱")) {
                        TextField("新名稱", text: $newName)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    Section {
                        Button("確定") {
                            renameItem(from: renameTarget, to: newName)
                            showRenameAlert = false
                        }
                    }
                }
                .navigationTitle("重命名")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("取消") { showRenameAlert = false }
                    }
                }
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

/// 編輯器主題設定：跟隨系統，或 Highlightr 全部內建主題擇一；上方釘住即時預覽。
struct EditorSettingsView: View {
    @AppStorage("paxidx.editor.theme") private var selectedTheme = "auto"
    @State private var themes: [String] = []
    @State private var query = ""
    @State private var previewCode = """
        #import <UIKit/UIKit.h>
        #include <string>
        // 主題預覽：註解
        @interface Greeter : NSObject
        @property (nonatomic, strong) NSString *name;
        @end
        @implementation Greeter
        - (NSString *)message {
            std::string who = "ObjC++";
            return [NSString stringWithFormat:@"Hello, %s", who.c_str()];
        }
        @end
        """

    private var filteredThemes: [String] {
        query.isEmpty ? themes
            : themes.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 預覽釘在上方，捲主題清單時隨時對照
            CodeEditorView(text: $previewCode, language: "objectivec", editable: false)
                .frame(height: 210)
                .id(selectedTheme)
            Divider()
            List {
                Section(header: Text("主題（Highlightr 內建共 \(themes.count) 款）")) {
                    themeRow(id: "auto", label: "跟隨系統（淺色 Xcode／深色 Xcode Dark）")
                    ForEach(filteredThemes, id: \.self) { name in
                        themeRow(id: name, label: name)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "搜尋主題")
        .navigationTitle("編輯器主題")
        .onAppear {
            if themes.isEmpty {
                themes = Highlightr()?.availableThemes().sorted() ?? []
            }
        }
    }

    private func themeRow(id: String, label: String) -> some View {
        Button {
            selectedTheme = id
        } label: {
            HStack {
                Text(label)
                    .foregroundColor(.primary)
                Spacer()
                if selectedTheme == id {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
        }
    }
}
