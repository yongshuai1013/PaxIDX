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

    init(project: Project) {
        self.project = project
        _selectedSDKFolder = State(initialValue: project.sdkFolder ?? "")
    }
    @Environment(\.presentationMode) private var presentationMode
    @State private var buildLog = ""
    @State private var isBuilding = false
    @State private var showLog = false
    @State private var showNewFileSheet = false
    @State private var newFileName = ""
    @State private var newFileType = "c"

    // 已安裝 SDK 與選版（編譯頁上方切換，持久化到 UserDefaults）
    @State private var installedSDKs: [PaxSDKStore.InstalledSDK] = []
    @State private var selectedSDKFolder: String = ""

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

    private func refreshSDKList() {
        installedSDKs = PaxSDKStore.installedSDKs()
        if !installedSDKs.contains(where: { $0.folderName == selectedSDKFolder }) {
            selectedSDKFolder = installedSDKs.first?.folderName ?? ""
        }
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
                        .onAppear { reloadFiles(); refreshSDKList() }

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
                    .default(Text("Objective-C 源文件")) { createNewFile(type: "m") },
                    .default(Text("C++ 源文件")) { createNewFile(type: "cpp") },
                    .default(Text("Objective-C++ 源文件")) { createNewFile(type: "mm") },
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
        case "m":
            ext = "m"
            template = "#import <Foundation/Foundation.h>\n\nint main(int argc, char *argv[]) {\n    @autoreleasepool {\n        NSLog(@\"Hello\");\n    }\n    return 0;\n}\n"
        case "cpp":
            ext = "cpp"
            template = "#include <iostream>\n\nint main() {\n    std::cout << \"Hello, C++!\" << std::endl;\n    return 0;\n}\n"
        case "mm":
            ext = "mm"
            template = "#import <Foundation/Foundation.h>\n#include <string>\n#include <iostream>\n\nint main(int argc, char *argv[]) {\n    @autoreleasepool {\n        std::string who = \"ObjC++\";\n        std::cout << \"Hello from \" << who << std::endl;\n        NSLog(@\"Hello from %s\", who.c_str());\n    }\n    return 0;\n}\n"
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
        var chosenSDK: PaxSDKStore.InstalledSDK? = nil

        let stages = [
            BuildStage(name: "檢查編譯器") { log in
                if !CoreCompilerService.frameworkEmbedded {
                    return "此版本未內嵌 CoreCompiler 編譯器"
                }
                PaxSDKStore.bootstrapEmbeddedIfNeeded()
                let all = PaxSDKStore.installedSDKs()
                chosenSDK = all.first { $0.folderName == selectedSDKFolder } ?? all.first
                guard let sdk = chosenSDK else {
                    return "未安裝任何 SDK（到設定→「下載 SDK」下載一份）"
                }
                let res = PaxSDKStore.resDir
                if !FileManager.default.fileExists(atPath: res.appendingPathComponent("module.modulemap").path) {
                    return "缺編譯器資源 res（重新下載任一 SDK 即可補上）"
                }
                log("編譯器：自編 CoreCompiler（Swift 6.4）")
                log("SDK：iOS \(sdk.version)（\(sdk.folderName)）")
                return nil
            },
            BuildStage(name: "編譯") { log in
                guard let sdk = chosenSDK else { return "未選定 SDK" }
                let fm = FileManager.default
                let res = PaxSDKStore.resDir
                let sourcesDir = ProjectFiles.sourcesDirectory(for: project.name)
                let buildDir = ProjectFiles.directory(for: project.name)
                    .appendingPathComponent("build", isDirectory: true)
                try? fm.removeItem(at: buildDir)
                try? fm.createDirectory(at: buildDir, withIntermediateDirectories: true)
                guard let files = try? fm.contentsOfDirectory(atPath: sourcesDir.path) else {
                    return "找不到源碼目錄"
                }
                let sources = files.filter {
                    $0.hasSuffix(".c") || $0.hasSuffix(".m") ||
                    $0.hasSuffix(".cpp") || $0.hasSuffix(".mm") ||
                    $0.hasSuffix(".cc") || $0.hasSuffix(".swift")
                }.sorted()
                if sources.isEmpty { return "沒有找到源文件" }
                log("找到 \(sources.count) 個源文件")
                let swiftFiles = sources.filter { $0.hasSuffix(".swift") }
                    .map { sourcesDir.appendingPathComponent($0) }
                let moduleName = project.name.map { ch -> String in
                    (ch == "_" || ch.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) })
                        ? String(ch) : "_"
                }.joined()
                let cacheDir = buildDir.appendingPathComponent("ModuleCache", isDirectory: true)
                try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                if swiftFiles.isEmpty {
                    let hasObjC = sources.contains {
                        let e = ($0 as NSString).pathExtension.lowercased()
                        return e == "m" || e == "mm"
                    }
                    let hasCpp = sources.contains {
                        let e = ($0 as NSString).pathExtension.lowercased()
                        return e == "cpp" || e == "cc" || e == "mm"
                    }
                    log("以 clang driver 組裝編譯＋連結…")
                    let exeURL = buildDir.appendingPathComponent(project.name)
                    let r = CoreCompilerService.buildWithDriver(
                        sources: sources.map { sourcesDir.appendingPathComponent($0) },
                        output: exeURL, buildDir: buildDir, sdk: sdk.url, res: res,
                        hasObjC: hasObjC, hasCpp: hasCpp)
                    if !r.report.isEmpty { log(r.report) }
                    if r.rc != 0 { return "driver 編譯失敗（rc=\(r.rc)）" }
                    log("編譯完成：\(exeURL.path)")
                    return nil
                }
                var objects: [URL] = []
                var hasObjC = false, hasSwift = false, hasCpp = false
                // Swift 入口模式：有 @UIApplicationMain／@main 屬性必須以
                // library 模式編（前端無 -parse-as-library 時把模組當成含
                // 頂層代碼、直接拒絕該屬性——2026-10-30 真機實證）；
                // 多文件且無 main.swift 亦然；其餘（print 範本類腳本）走
                // 頂層代碼入口。
                let swiftTexts = swiftFiles.map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }
                let hasEntryAttr = swiftTexts.contains { $0.contains("@UIApplicationMain") || $0.contains("@main") }
                let hasMainFile = swiftFiles.contains { $0.lastPathComponent == "main.swift" }
                let parseAsLibrary = hasEntryAttr || (swiftFiles.count > 1 && !hasMainFile)
                log("Swift 入口模式：\(parseAsLibrary ? "library" : "script")")
                for src in sources {
                    let srcURL = sourcesDir.appendingPathComponent(src)
                    let objURL = buildDir.appendingPathComponent((src as NSString).deletingPathExtension + ".o")
                    objects.append(objURL)
                    log("編譯 \(src)…")
                    let ext = (src as NSString).pathExtension.lowercased()
                    let r: (rc: Int32, report: String)
                    if ext == "swift" {
                        hasSwift = true
                        r = CoreCompilerService.compileSwift(source: srcURL, allSwift: swiftFiles,
                                                             object: objURL, sdk: sdk.url, res: res,
                                                             moduleName: moduleName, moduleCache: cacheDir,
                                                             parseAsLibrary: parseAsLibrary)
                    } else {
                        if ext == "m" || ext == "mm" { hasObjC = true }
                        if ext == "cpp" || ext == "cc" || ext == "mm" { hasCpp = true }
                        r = CoreCompilerService.compileC(source: srcURL, object: objURL, sdk: sdk.url, res: res)
                    }
                    if r.rc != 0 {
                        if !r.report.isEmpty { log(r.report) }
                        return "編譯 \(src) 失敗（rc=\(r.rc)）"
                    }
                }
                log("連結…")
                let exeURL = buildDir.appendingPathComponent(project.name)
                let lr = CoreCompilerService.link(objects: objects, output: exeURL, sdk: sdk.url,
                                                  hasObjC: hasObjC, hasSwift: hasSwift, hasCpp: hasCpp)
                if lr.rc != 0 {
                    if !lr.report.isEmpty { log(lr.report) }
                    return "連結失敗（rc=\(lr.rc)）"
                }
                log("編譯完成：\(exeURL.path)")
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

                // 證書真簽名（簽名證書頁已導入身份時）：bundle id 改用描述檔的、
                // 內嵌描述檔、主程式以開發者證書真簽；未導入身份時維持原行為。
                var bundleID = project.bundleID
                var signReport: String? = nil
                var bidBuf = [CChar](repeating: 0, count: 256)
                if paxidx_cert_profile_bundle_id(&bidBuf, bidBuf.count) == 0 {
                    bundleID = String(cString: bidBuf)
                    let profileSrc = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("PaxIDXSigning", isDirectory: true)
                        .appendingPathComponent("profile.mobileprovision")
                    try? fm.copyItem(at: profileSrc, to: appDir.appendingPathComponent("embedded.mobileprovision"))
                    var rep = [CChar](repeating: 0, count: 1024)
                    let exeInApp = appDir.appendingPathComponent(project.name)
                    let rc = paxidx_cert_sign_file(exeInApp.path, exeInApp.path, bundleID, &rep, rep.count)
                    if rc != 0 { return "證書簽名失敗：\(String(cString: rep))" }
                    signReport = String(cString: rep)
                }

                // 寫 Info.plist
                let info: [String: Any] = [
                    "CFBundleIdentifier": bundleID,
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
                if let signReport { log("證書簽名完成（bundle id：\(bundleID)）：\n\(signReport)") }

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
                BuildLogStore.shared.save(project: project.name, log: buildLog)
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
