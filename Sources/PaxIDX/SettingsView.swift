import SwiftUI

/// 設定頁：SDK 管理 + 關於
struct SettingsView: View {
    @State private var sdkInstalled = SDKManager.shared.isInstalled
    @State private var isDownloading = false
    @State private var downloadProgress = 0.0
    @State private var sdkMessage = ""
    @State private var toolchainMessage = ""

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
                    if !sdkInstalled && !isDownloading {
                        Button("下載 SDK（約 36MB）") {
                            downloadSDK()
                        }
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
}

/// 文件瀏覽器：瀏覽 App Documents 目錄
struct FileBrowserView: View {
    @State private var currentPath: String
    @State private var items: [(name: String, isDir: Bool)] = []

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
                } else {
                    HStack {
                        Image(systemName: "doc.fill")
                            .foregroundColor(.secondary)
                        Text(item.name)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle((currentPath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
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
    }
}
