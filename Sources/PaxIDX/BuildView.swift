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

            NavigationLink(destination: BuildLogView(log: buildLog), isActive: $showLog) {
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
        var diagBuf = [CChar](repeating: 0, count: 8192)
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
                        return "本版本專注 C 編譯器，不支援 Swift（.swift 文件）"
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
                log("鏈接…")
                let exePath = buildDir.appendingPathComponent(project.name).path
                let ldArgs = ["ld", "-o", exePath] + objects + [
                    "-target", "arm64-apple-ios15.0",
                    "-undefined", "dynamic_lookup",
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
    let log: String

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
    }
}
// 用 #27 新 dylib
// 用 #28 新 dylib
