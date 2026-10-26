import SwiftUI

/// [String] 轉 C 的 argc/argv，給 paxidx_* 函數用
extension Array where Element == String {
    func withCStrings<T>(_ body: (Int32, UnsafeMutablePointer<UnsafePointer<CChar>?>) -> T) -> T {
        var cStrings: [UnsafeMutablePointer<CChar>?] = self.map { strdup($0) }
        defer { cStrings.forEach { if let p = $0 { free(p) } } }
        return cStrings.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            // char** 就是 UnsafeMutablePointer<UnsafePointer<CChar>?>
            let argv = base.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { $0 }
            return body(Int32(self.count), argv)
        }
    }
}

/// 編譯頁：XForge 風格的文件瀏覽器
struct BuildView: View {
    /// 手造 FORCE_LOAD 替身目標文件（Mach-O arm64 物件，22 個符號）的 base64
    private static let forceLoadStubBase64 = "z/rt/gwAAAEAAAAAAQAAAAIAAACwAAAAAAAAAAAAAAAZAAAAmAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAALAAAAAAAAAAAAAAAAAAAACwAAAAAAAAAAAAAAAAAAAAAQAAAAAAAABfX2RhdGEAAAAAAAAAAAAAX19EQVRBAAAAAAAAAAAAAAAAAAAAAAAAsAAAAAAAAADQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAAYAAAAgAEAABYAAADgAgAAMQMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAA8BAAAAAAAAAAAAACcAAAAPAQAACAAAAAAAAABQAAAADwEAABAAAAAAAAAAdgAAAA8BAAAYAAAAAAAAAJoAAAAPAQAAIAAAAAAAAADBAAAADwEAACgAAAAAAAAA6AAAAA8BAAAwAAAAAAAAABgBAAAPAQAAOAAAAAAAAAA6AQAADwEAAEAAAAAAAAAAZAEAAA8BAABIAAAAAAAAAIsBAAAPAQAAUAAAAAAAAACpAQAADwEAAFgAAAAAAAAA0gEAAA8BAABgAAAAAAAAAPkBAAAPAQAAaAAAAAAAAAAlAgAADwEAAHAAAAAAAAAASQIAAA8BAAB4AAAAAAAAAGoCAAAPAQAAgAAAAAAAAACKAgAADwEAAIgAAAAAAAAArAIAAA8BAACQAAAAAAAAAM0CAAAPAQAAmAAAAAAAAADtAgAADwEAAKAAAAAAAAAAEAMAAA8BAACoAAAAAAAAAABfX3N3aWZ0X0ZPUkNFX0xPQURfJF9zd2lmdERpc3RyaWJ1dGVkAF9fc3dpZnRfRk9SQ0VfTE9BRF8kX3N3aWZ0SWRlbnRpdHlMb29rdXAAX19zd2lmdF9GT1JDRV9MT0FEXyRfc3dpZnRPYnNlcnZhdGlvbgBfX3N3aWZ0X0ZPUkNFX0xPQURfJF9zd2lmdFBlbmNpbEtpdABfX3N3aWZ0X0ZPUkNFX0xPQURfJF9zd2lmdFJlZ2V4QnVpbGRlcgBfX3N3aWZ0X0ZPUkNFX0xPQURfJF9zd2lmdFJlbW90ZU1pcnJvcgBfX3N3aWZ0X0ZPUkNFX0xPQURfJF9zd2lmdFNvdW5kQW5hbHlzaXNfUHJpdmF0ZQBfX3N3aWZ0X0ZPUkNFX0xPQURfJF9zd2lmdFNwYXRpYWwAX19zd2lmdF9GT1JDRV9MT0FEXyRfc3dpZnRTeW5jaHJvbml6YXRpb24AX19zd2lmdF9GT1JDRV9MT0FEXyRfc3dpZnRWaWRlb1Rvb2xib3gAX19zd2lmdF9GT1JDRV9MT0FEXyRfc3dpZnRYUEMAX19zd2lmdF9GT1JDRV9MT0FEXyRfc3dpZnRfQnVpbHRpbl9mbG9hdABfX3N3aWZ0X0ZPUkNFX0xPQURfJF9zd2lmdF9SZWdleFBhcnNlcgBfX3N3aWZ0X0ZPUkNFX0xPQURfJF9zd2lmdF9TdHJpbmdQcm9jZXNzaW5nAF9fc3dpZnRfRk9SQ0VfTE9BRF8kX3N3aWZ0X1ZvbGF0aWxlAF9fc3dpZnRfRk9SQ0VfTE9BRF8kX3N3aWZ0X2Vycm5vAF9fc3dpZnRfRk9SQ0VfTE9BRF8kX3N3aWZ0X21hdGgAX19zd2lmdF9GT1JDRV9MT0FEXyRfc3dpZnRfc2lnbmFsAF9fc3dpZnRfRk9SQ0VfTE9BRF8kX3N3aWZ0X3N0ZGlvAF9fc3dpZnRfRk9SQ0VfTE9BRF8kX3N3aWZ0X3RpbWUAX19zd2lmdF9GT1JDRV9MT0FEXyRfc3dpZnRzeXNfdGltZQBfX3N3aWZ0X0ZPUkNFX0xPQURfJF9zd2lmdHVuaXN0ZAA="
    let project: Project
    @Environment(\.presentationMode) private var presentationMode
    @State private var buildLog = ""
    @State private var isBuilding = false
    @State private var showLog = false
    @State private var showNewFileSheet = false
    @State private var newFileName = ""
    @State private var newFileType = "c"

    // 文件列表：源文件＋構建產物，動態讀取
    @State private var sourceFiles: [String] = []
    @State private var buildFiles: [String] = []

    private func reloadFiles() {
        let fm = FileManager.default
        let srcDir = ProjectFiles.sourcesDirectory(for: project.name)
        sourceFiles = (try? fm.contentsOfDirectory(atPath: srcDir.path)) ?? []
        let projDir = ProjectFiles.directory(for: project.name)
        let all = (try? fm.contentsOfDirectory(atPath: projDir.path)) ?? []
        // 構建產物：排除 Sources 目錄
        buildFiles = all.filter { $0 != "Sources" }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section(header: Text("源文件")) {
                    ForEach(sourceFiles, id: \.self) { file in
                        NavigationLink(destination: FileEditorView(project: project, filename: file, onSave: { reloadFiles() })) {
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundColor(.accentColor)
                                Text(file)
                            }
                        }
                    }
                }
                if !buildFiles.isEmpty {
                    Section(header: Text("構建產物")) {
                        ForEach(buildFiles, id: \.self) { file in
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundColor(.accentColor)
                                Text(file)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .onAppear(perform: reloadFiles)

            // 底部編譯按鈕
            HStack {
                Spacer()
                Button(action: {
                    showLog = true
                    startBuild()
                }) {
                    HStack {
                        Text(isBuilding ? "編譯中…" : "編譯")
                        Image(systemName: "play.fill")
                    }
                    .foregroundColor(isBuilding ? .gray : .accentColor)
                }
                .disabled(isBuilding)
                .padding()
            }
            .background(Color(.systemBackground))

            NavigationLink(destination: BuildLogView(log: $buildLog), isActive: $showLog) {
                EmptyView()
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("完成") {
                    presentationMode.wrappedValue.dismiss()
                }
                .foregroundColor(.accentColor)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    if let first = sourceFiles.first {
                        NavigationLink(destination: FileEditorView(project: project, filename: first, onSave: { reloadFiles() })) {
                            Image(systemName: "pencil")
                                .foregroundColor(.accentColor)
                        }
                    }
                    Button(action: { showNewFileSheet = true }) {
                        Image(systemName: "plus")
                            .foregroundColor(.accentColor)
                    }
                }
            }
        }
        .actionSheet(isPresented: $showNewFileSheet) {
            ActionSheet(
                title: Text("新建文件"),
                buttons: [
                    .default(Text("C 源文件")) { createNewFile(type: "c") },
                    .default(Text("Swift 源文件")) { createNewFile(type: "swift") },
                    .default(Text("頭文件")) { createNewFile(type: "h") },
                    .default(Text("空白文件")) { createNewFile(type: "txt") },
                    .default(Text("文件夾")) { createNewFolder() },
                    .cancel(Text("取消")),
                ]
            )
        }
    }

    private func createNewFile(type: String) {
        let srcDir = ProjectFiles.sourcesDirectory(for: project.name)
        let ext: String
        let template: String
        switch type {
        case "c":
            ext = "c"
            template = "#include <stdio.h>\n\nint main() {\n    printf(\"Hello\\n\");\n    return 0;\n}\n"
        case "swift":
            ext = "swift"
            template = "print(\"Hello\")\n"
        case "h":
            ext = "h"
            template = "#ifndef HEADER_H\n#define HEADER_H\n\n#endif\n"
        default:
            ext = "txt"
            template = ""
        }
        // 找不重名的文件名
        var i = 1
        var name = "newfile.\(ext)"
        let fm = FileManager.default
        while fm.fileExists(atPath: srcDir.appendingPathComponent(name).path) {
            i += 1
            name = "newfile\(i).\(ext)"
        }
        try? template.write(to: srcDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        reloadFiles()
    }

    private func createNewFolder() {
        let srcDir = ProjectFiles.sourcesDirectory(for: project.name)
        let fm = FileManager.default
        var i = 1
        var name = "newfolder"
        while fm.fileExists(atPath: srcDir.appendingPathComponent(name).path) {
            i += 1
            name = "newfolder\(i)"
        }
        try? fm.createDirectory(at: srcDir.appendingPathComponent(name), withIntermediateDirectories: true)
        reloadFiles()
    }

    /// 調 C 橋接（clang / ld），回傳 (rc, diagnostics)
    private func runNative(
        _ args: [String],
        _ fn: (Int32, UnsafePointer<UnsafePointer<CChar>?>?, UnsafeMutablePointer<CChar>?, Int) -> Int32
    ) -> (Int32, String) {
        // 8192 原本夠用，直到 sysroot 的 36 支函式庫每支噴一條版本警告
        // （約 355 位元組×36＞12KB）把緩衝灌滿、真正的鏈接錯誤被截斷丟失
        // （2026-10-26 真機實證：日誌斷在警告中段、錯誤一條都沒留下）。
        var diagBuf = [CChar](repeating: 0, count: 262144)
        let rc: Int32 = diagBuf.withUnsafeMutableBufferPointer { dptr in
            args.withCStrings { argc, argv in
                fn(argc, argv, dptr.baseAddress, dptr.count)
            }
        }
        let msg = diagBuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return (rc, msg)
    }

    private func startBuild() {
        buildLog = ""
        isBuilding = true

        let stages = [
            BuildStage(name: "檢查工具鏈") { log in
                // dylib 已下載就可用（dlopen 載入）
                if paxidx_toolchain_available() == 1 {
                    log("工具鏈可用")
                    return nil
                }
                // 載入失敗：顯示真實原因（dlopen 錯誤）
                var errBuf = [CChar](repeating: 0, count: 1024)
                paxidx_toolchain_error(&errBuf, errBuf.count)
                let reason = String(cString: errBuf)
                if reason.isEmpty {
                    return "工具鏈未下載（到設定頁下載工具鏈）"
                }
                return "工具鏈載入失敗：\(reason)"
            },
            BuildStage(name: "編譯") { log in
                // 真實編譯：調用內嵌的 Clang + LLD
                let fm = FileManager.default
                let sourcesDir = ProjectFiles.sourcesDirectory(for: project.name)
                let buildDir = ProjectFiles.directory(for: project.name)
                    .appendingPathComponent("build", isDirectory: true)

                // 清理舊的 build 目錄
                try? fm.removeItem(at: buildDir)
                try? fm.createDirectory(at: buildDir, withIntermediateDirectories: true)

                // 找出所有源文件
                guard let files = try? fm.contentsOfDirectory(atPath: sourcesDir.path) else {
                    return "找不到源碼目錄"
                }
                let sources = files.filter {
                    $0.hasSuffix(".c") || $0.hasSuffix(".m") ||
                    $0.hasSuffix(".cpp") || $0.hasSuffix(".mm") ||
                    $0.hasSuffix(".cc") || $0.hasSuffix(".swift")
                }
                if sources.isEmpty {
                    return "沒有找到源文件"
                }
                log("找到 \(sources.count) 個源文件")

                // SDK 路徑：從已下載的 Darwin SDK 獲取
                guard let sdkURL = SDKManager.shared.sdkPath else {
                    return "未找到 iOS SDK，請先在設定裡下載 SDK"
                }
                let sdk = sdkURL.path
                // 檢查 SDK 是否完整（stdio.h 在不在）
                let stdioPath = (sdk as NSString).appendingPathComponent("usr/include/stdio.h")
                if !FileManager.default.fileExists(atPath: stdioPath) {
                    // 看看 usr/include 下有什麼，幫助診斷
                    let incDir = (sdk as NSString).appendingPathComponent("usr/include")
                    let contents = (try? FileManager.default.contentsOfDirectory(atPath: incDir)) ?? []
                    log("SDK 不完整：缺 usr/include/stdio.h")
                    log("usr/include 下有 \(contents.count) 個文件")
                    if contents.isEmpty {
                        return "SDK 的 usr/include 是空的，請到設定頁刪除 SDK 後重新下載"
                    }
                    return "SDK 缺 stdio.h，請到設定頁刪除 SDK 後重新下載"
                }

                var objects: [String] = []
                for src in sources {
                    let srcPath = sourcesDir.appendingPathComponent(src).path
                    let objName = (src as NSString).deletingPathExtension + ".o"
                    let objPath = buildDir.appendingPathComponent(objName).path
                    objects.append(objPath)

                    log("編譯 \(src)…")
                    let isSwift = src.hasSuffix(".swift")
                    let (rc, diag): (Int32, String)
                    if isSwift {
                        // Swift 走 dylib 的前端封裝（paxidx_swift_compile）；
                        // 參數集對齊封裝的解析：-target/-sdk/-module-cache-path/-o/<input.swift>
                        if paxidx_swift_available() != 1 {
                            return "Swift 工具鏈不可用（到設定頁下載 Swift 工具鏈）"
                        }
                        if !ToolchainManager.shared.isSwiftModulesOverlaid {
                            return "Swift 標準庫模塊尚未疊加（到設定頁點「疊加 Swift 標準庫模塊」）"
                        }
                        let cacheDir = buildDir.appendingPathComponent("ModuleCache", isDirectory: true)
                        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                        let args = [
                            "swift",
                            "-target", "arm64-apple-ios15.0",
                            "-sdk", sdk,
                            "-module-cache-path", cacheDir.path,
                            "-o", objPath,
                            srcPath,
                        ]
                        (rc, diag) = runNative(args, paxidx_swift_compile)
                    } else {
                        // 構造 clang 參數
                        let args = [
                            "clang",
                            "-target", "arm64-apple-ios15.0",
                            "-isysroot", sdk,
                            "-c", srcPath,
                            "-o", objPath,
                        ]
                        // 用環境變數告訴 Clang 頭文件位置（dylib 不轉發 -I 參數）
                        let incPath = (sdk as NSString).appendingPathComponent("usr/include")
                        setenv("C_INCLUDE_PATH", incPath, 1)
                        (rc, diag) = runNative(args, paxidx_clang_compile)
                    }
                    if rc != 0 {
                        if !diag.isEmpty { log(diag) }
                        return "編譯 \(src) 失敗（rc=\(rc)）"
                    }
                }

                // 鏈接
                if objects.count > 1 {
                    log("注意：多個源文件會一起鏈接；Swift 與 C 混編的進入點只能留一個")
                }
                if !ToolchainManager.shared.isSysrootInstalled {
                    return "系統函式庫（sysroot）尚未安裝（到設定頁點「安裝系統函式庫」）"
                }
                log("鏈接…")
                let exePath = buildDir.appendingPathComponent(project.name).path
                // FORCE_LOAD 替身目標文件：SDK 以 .tbd 宣告的 libswift* 迷你
                // 庫裡有 22 支在 iOS 15 系統裡沒有真身（_errno／_math／_stdio
                // 等 C 墊片模塊與若干新系統模塊，實現都在父庫裡），偏偏每個
                // 消費者物件都會引用它們的 __swift_FORCE_LOAD_$_swift* 標記
                // 符號——裝置 lld 讀 .tbd 等於讀空，符號無處可連（2026-10-26
                // 真機日誌實證 12 個未定義）。比照橋接層 swiftCompatibility56
                // 替身的做法：隨鏈接附一顆手造目標文件（forceLoadStubBase64，
                // 22 個符號各一個 8 位元組零值全域）在本程序內定義這批符號；
                // 無人解引用、不產生任何載入命令，運行時不會去找不存在的庫。
                var linkObjects = objects
                let stubPath = buildDir.appendingPathComponent("paxidx-forceload-stub.o").path
                if let stubData = Data(base64Encoded: Self.forceLoadStubBase64) {
                    try? stubData.write(to: URL(fileURLWithPath: stubPath))
                    if FileManager.default.fileExists(atPath: stubPath) {
                        linkObjects.append(stubPath)
                    }
                }
                // TBD 診斷（實驗，2026-10-26 永帥選定「先做廉價診斷」）：
                // 把 SDK 的 .tbd 當連結輸入餵給裝置 lld，驗證它在裝置真
                // 連結裡到底讀不讀 .tbd——TextAPI 的符號在工具鏈 dylib
                // 裡實在，但從未在裝置上實證；當年只有一行舊日誌的
                // "unhandled file type"（正是 libSystem.tbd 這支）。兩支
                // .tbd 宣告的安裝名與 sysroot 真身相同，縱使被用來綁
                // 符號，產物記的仍是系統原名，不影響運行。判定：連結如
                // 常成功＝讀得了；報 unhandled file type＝裝置驅動沒開
                // 讀取；報 tapi 解析錯＝讀了但版本不合。
                for tbdRel in ["usr/lib/libSystem.tbd",
                               "System/Library/Frameworks/Foundation.framework/Foundation.tbd"] {
                    let tbdPath = (sdk as NSString).appendingPathComponent(tbdRel)
                    if FileManager.default.fileExists(atPath: tbdPath) {
                        linkObjects.append(tbdPath)
                        log("TBD 診斷：加入連結輸入 \(tbdRel)")
                    }
                }
                let ldArgs = ["ld", "-o", exePath] + linkObjects + [
                    "-target", "arm64-apple-ios15.0",
                    "-isysroot", sdk,
                ]
                let (ldRc, ldDiag) = runNative(ldArgs, paxidx_ld_link)
                if ldRc != 0 {
                    if !ldDiag.isEmpty { log(ldDiag) }
                    return "鏈接失敗（rc=\(ldRc)）"
                }

                log("編譯完成：\(exePath)")
                return nil
            },
            BuildStage(name: "打包 IPA") { log in
                let fm = FileManager.default
                let buildDir = ProjectFiles.directory(for: project.name)
                    .appendingPathComponent("build", isDirectory: true)
                let exePath = buildDir.appendingPathComponent(project.name)

                guard fm.fileExists(atPath: exePath.path) else {
                    return "找不到編譯產物"
                }

                // 組裝 .app
                let appDir = buildDir
                    .appendingPathComponent("\(project.name).app", isDirectory: true)
                try? fm.removeItem(at: appDir)
                try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
                try? fm.copyItem(at: exePath, to: appDir.appendingPathComponent(project.name))

                // 寫 Info.plist
                let info: [String: Any] = [
                    "CFBundleIdentifier": project.bundleID,
                    "CFBundleName": project.name,
                    "CFBundleDisplayName": project.name,
                    "CFBundleShortVersionString": project.version,
                    "CFBundleVersion": "1",
                    "CFBundleExecutable": project.name,
                    "CFBundlePackageType": "APPL",
                    "LSRequiresIPhoneOS": true,
                    "MinimumOSVersion": "15.0",
                ]
                let infoData = try? PropertyListSerialization.data(
                    fromPropertyList: info, format: .xml, options: 0)
                try? infoData?.write(to: appDir.appendingPathComponent("Info.plist"))

                // 打包 IPA
                let ipaURL = ProjectFiles.directory(for: project.name)
                    .appendingPathComponent("\(project.name).ipa")
                do {
                    try IPABuilder.build(appURL: appDir, outputURL: ipaURL, log: log)
                } catch {
                    return "打包失敗：\(error.localizedDescription)"
                }
                return nil
            },
        ]

        BuildExecutor(stages: stages).execute(
            onStage: { _, _ in },
            onLog: { line in buildLog += line + "\n" },
            onDone: { _, msg in
                isBuilding = false
                buildLog += msg + "\n"
                reloadFiles()
            }
        )
    }
}

/// 編譯日誌頁：整頁顯示，方便截圖
struct BuildLogView: View {
    // 必須是 Binding 而非值拷貝：值拷貝會凍結在點進頁面那一刻的快照，
    // 編譯在背景跑完後的失敗行與前端診斷永遠進不了這一頁（匯出的
    // paxidx-build 日誌同理只有階段清單）——2026-10-26 晚真機實證：
    // 使用者在編譯中途點進日誌頁，之後兩輪編譯其實已 rc=1 失敗、
    // 診斷也已回傳，日誌頁卻一直停在「編譯 newfile.swift...」。
    @Binding var log: String
    @State private var showShare = false
    @State private var logURL: URL?

    var body: some View {
        ScrollView {
            Text(log.isEmpty ? "（無日誌）" : log)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("編譯日誌")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("下載日誌") {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("paxidx-build-\(Int(Date().timeIntervalSince1970)).txt")
                    try? log.write(to: url, atomically: true, encoding: .utf8)
                    logURL = url
                    showShare = true
                }
            }
        }
        .sheet(isPresented: $showShare) {
            if let url = logURL {
                ShareSheet(activityItems: [url])
            }
        }
    }
}
// 用 #27 新 dylib
// 用 #28 新 dylib

/// 系統分享面板
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
