import Foundation

/// Python 專案打包：把專案的 .py 源碼＋Python 執行環境組裝成 .app（不經編譯器）。
/// 佈局照 BeeWare 官方 install_python 在 CPyTest 驗證過的配方：通用宿主改名為
/// 可執行檔、Python.framework 進 Frameworks/、標準庫進 python/、lib-dynload
/// 的 .so 逐個轉成 Frameworks/<模組>.framework（原位留 .fwork 佔位、framework
/// 內留 .origin 回指）——CPython 的 iOS 載入器靠這套佈局找擴展模組。
enum PythonPackager {

    /// Python 專案判定：Sources 有 .py 且沒有任何原生／Swift 源碼
    static func isPythonProject(_ project: Project) -> Bool {
        let dir = ProjectFiles.sourcesDirectory(for: project.name)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return false }
        let hasPy = files.contains { $0.lowercased().hasSuffix(".py") }
        let hasNative = files.contains {
            ["c", "m", "mm", "cpp", "cc", "swift"].contains(
                ($0 as NSString).pathExtension.lowercased())
        }
        return hasPy && !hasNative
    }

    /// 組裝 .app 到 buildDir/<name>.app；成功回傳 nil，失敗回傳原因字串
    static func assemble(project: Project, buildDir: URL, log: (String) -> Void) -> String? {
        let fm = FileManager.default
        guard PythonRuntimeStore.isInstalled else {
            return "未安裝 Python 執行環境（到設定→「下載 SDK」頁下載 Python 3.13 執行環境）"
        }
        let rt = PythonRuntimeStore.root
        let appDir = buildDir.appendingPathComponent("\(project.name).app", isDirectory: true)
        do {
            try? fm.removeItem(at: appDir)
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true)

            // 通用宿主 → 專案可執行檔
            let hostDst = appDir.appendingPathComponent(project.name)
            try fm.copyItem(at: rt.appendingPathComponent("PythonHost"), to: hostDst)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hostDst.path)
            log("宿主：PythonHost → \(project.name)")

            // Python.framework → Frameworks/
            let frameworksDir = appDir.appendingPathComponent("Frameworks", isDirectory: true)
            try fm.createDirectory(at: frameworksDir, withIntermediateDirectories: true)
            try fm.copyItem(at: rt.appendingPathComponent("Python.framework"),
                            to: frameworksDir.appendingPathComponent("Python.framework", isDirectory: true))

            // 標準庫 → python/，再原地把 lib-dynload 的 .so 轉成 framework
            try fm.copyItem(at: rt.appendingPathComponent("python"),
                            to: appDir.appendingPathComponent("python", isDirectory: true))
            let converted = try convertDynload(
                in: appDir, bundleID: project.bundleID,
                template: rt.appendingPathComponent("dylib-template.plist"))
            log("標準庫就位；擴展模組 framework 化：\(converted) 個")

            // 專案 .py → 包根目錄（宿主從這裡找 main.py，sys.path 也含包根）
            let srcDir = ProjectFiles.sourcesDirectory(for: project.name)
            let pyFiles = (try fm.contentsOfDirectory(atPath: srcDir.path))
                .filter { $0.lowercased().hasSuffix(".py") }.sorted()
            guard pyFiles.contains("main.py") else {
                return "Python 專案缺 main.py（宿主的入口檔）"
            }
            for f in pyFiles {
                try fm.copyItem(at: srcDir.appendingPathComponent(f),
                                to: appDir.appendingPathComponent(f))
            }
            log("已放入 \(pyFiles.count) 個 Python 檔案：\(pyFiles.joined(separator: "、"))")

            // Info.plist（與編譯專案同欄位；Python v1 不套證書簽名，走 TrollStore 安裝）
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
            let infoData = try PropertyListSerialization.data(
                fromPropertyList: info, format: .xml, options: 0)
            try infoData.write(to: appDir.appendingPathComponent("Info.plist"))
            return nil
        } catch {
            return "組裝失敗：\(error.localizedDescription)"
        }
    }

    /// 照官方 install_dylib：lib-dynload 每支 .so 轉成一個 framework。
    /// 例：_sqlite3.cpython-313-iphoneos.so → Frameworks/_sqlite3.framework/_sqlite3，
    /// 原位留 _sqlite3.cpython-313-iphoneos.fwork（內容為 framework 內二進制路徑），
    /// framework 內留 _sqlite3.origin（內容為 .fwork 的相對路徑）。
    private static func convertDynload(in appDir: URL, bundleID: String, template: URL) throws -> Int {
        let fm = FileManager.default
        let dynRel = "python/lib/python3.13/lib-dynload"
        let dynDir = appDir.appendingPathComponent(dynRel, isDirectory: true)
        let frameworksDir = appDir.appendingPathComponent("Frameworks", isDirectory: true)

        // 讀官方模板 plist（只換 Executable 與 Identifier 兩欄，其餘照抄）
        let tmplData = try Data(contentsOf: template)
        guard var tmpl = try PropertyListSerialization.propertyList(
            from: tmplData, options: [], format: nil) as? [String: Any] else {
            throw NSError(domain: "PythonPackager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "dylib 模板 plist 讀不到"])
        }

        var count = 0
        for name in try fm.contentsOfDirectory(atPath: dynDir.path) where name.hasSuffix(".so") {
            let module = (name as NSString).components(separatedBy: ".").first ?? name
            let fwName = "\(module).framework"
            let fwDir = frameworksDir.appendingPathComponent(fwName, isDirectory: true)
            try fm.createDirectory(at: fwDir, withIntermediateDirectories: true)

            tmpl["CFBundleExecutable"] = module
            tmpl["CFBundleIdentifier"] =
                (bundleID + "." + module).replacingOccurrences(of: "_", with: "-")
            let plistData = try PropertyListSerialization.data(
                fromPropertyList: tmpl, format: .xml, options: 0)
            try plistData.write(to: fwDir.appendingPathComponent("Info.plist"))

            let src = dynDir.appendingPathComponent(name)
            let dst = fwDir.appendingPathComponent(module)
            try fm.moveItem(at: src, to: dst)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)

            let base = (name as NSString).deletingPathExtension
            try "Frameworks/\(fwName)/\(module)\n".write(
                to: dynDir.appendingPathComponent(base + ".fwork"),
                atomically: true, encoding: .utf8)
            try "\(dynRel)/\(base).fwork\n".write(
                to: fwDir.appendingPathComponent(module + ".origin"),
                atomically: true, encoding: .utf8)
            count += 1
        }
        return count
    }
}
