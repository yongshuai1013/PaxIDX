import Foundation

/// 自編 CoreCompiler（Swift 6.4）的正式編譯服務：參數配方全部照實測頁
/// 已在真機驗通的 B／D／F／S10 段（CCJob 直打），橋接只負責執行。
enum CoreCompilerService {
    static var frameworkEmbedded: Bool {
        FileManager.default.fileExists(
            atPath: Bundle.main.bundlePath + "/Frameworks/CoreCompiler.framework/CoreCompiler")
    }

    /// 在 64MB 大棧專用線程上同步跑一個 CCJob（LLVM 前端棧很深，
    /// GCD 工作線程的 512KB 不夠）。回傳（rc, 診斷文字）。
    static func runJob(type: Int32, args: [String]) -> (rc: Int32, report: String) {
        var result: (rc: Int32, report: String) = (1, "")
        let sem = DispatchSemaphore(value: 0)
        let thread = Thread {
            var buf = [CChar](repeating: 0, count: 262144)
            let rc: Int32 = buf.withUnsafeMutableBufferPointer { bptr in
                args.withCStrings { argc, argv in
                    paxidx_cc_job(type, argc, argv, bptr.baseAddress, bptr.count)
                }
            }
            result = (rc, String(cString: buf))
            sem.signal()
        }
        thread.stackSize = 64 * 1024 * 1024
        thread.start()
        sem.wait()
        return result
    }

    private static let triple = "arm64-apple-ios15.0"

    /// clang 內建頭的 resource-dir：優先 SDK 自帶 usr/lib/clang，
    /// 缺位（如 27 分支 SDK）退回自編 res 的 clang。
    static func clangResourceDir(sdk: URL, res: URL) -> String {
        let fm = FileManager.default
        let base = sdk.appendingPathComponent("usr/lib/clang")
        if let vers = try? fm.contentsOfDirectory(atPath: base.path) {
            for v in vers.sorted() {
                let cand = base.appendingPathComponent(v)
                if fm.fileExists(atPath: cand.appendingPathComponent("include/stdarg.h").path) {
                    return cand.path
                }
            }
        }
        return res.appendingPathComponent("clang").path
    }

    /// 編譯單個 C／C++／ObjC 源文件（CCJob type 0，-cc1 配方照 B／D 段）
    static func compileC(source: URL, object: URL, sdk: URL, res: URL) -> (rc: Int32, report: String) {
        let ext = source.pathExtension.lowercased()
        let isObjC = ext == "m" || ext == "mm"
        let isCpp = ext == "cpp" || ext == "cc" || ext == "mm"
        var args = ["-cc1", "-triple", triple, "-emit-obj",
                    "-main-file-name", source.lastPathComponent,
                    "-isysroot", sdk.path,
                    "-internal-isystem", sdk.appendingPathComponent("usr/include").path,
                    "-internal-externc-isystem", sdk.appendingPathComponent("usr/include").path]
        if isObjC {
            let rd = clangResourceDir(sdk: sdk, res: res)
            args += ["-F" + sdk.appendingPathComponent("System/Library/Frameworks").path,
                     "-F" + sdk.appendingPathComponent("System/Library/SubFrameworks").path,
                     "-resource-dir", rd,
                     "-internal-isystem", rd + "/include",
                     "-D__GNUC__=4", "-D__GNUC_MINOR__=2", "-D__GNUC_PATCHLEVEL__=1",
                     "-fblocks", "-fobjc-runtime=ios-15.0"]
        }
        if isCpp { args += ["-std=c++17"] }
        args += ["-o", object.path, "-x",
                 isObjC ? (ext == "mm" ? "objective-c++" : "objective-c") : (isCpp ? "c++" : "c"),
                 source.path]
        return runJob(type: 0, args: args)
    }

    /// 編譯單個 Swift 源文件（CCJob type 2，配方照 S10）
    static func compileSwift(source: URL, allSwift: [URL], object: URL, sdk: URL, res: URL,
                             moduleName: String, moduleCache: URL,
                             parseAsLibrary: Bool) -> (rc: Int32, report: String) {
        var args = ["-frontend", "-c", "-primary-file", source.path]
        args += allSwift.filter { $0 != source }.map { $0.path }
        args += ["-target", triple, "-sdk", sdk.path, "-resource-dir", res.path,
                 "-module-cache-path", moduleCache.path,
                 "-o", object.path, "-module-name", moduleName, "-enable-objc-interop"]
        if parseAsLibrary { args.append("-parse-as-library") }
        return runJob(type: 2, args: args)
    }

    /// 連結成可執行檔（CCJob type 4，配方照 F 段）
    static func link(objects: [URL], output: URL, sdk: URL,
                     hasObjC: Bool, hasSwift: Bool, hasCpp: Bool) -> (rc: Int32, report: String) {
        var args = ["-arch", "arm64", "-platform_version", "ios", "15.0", "18.5",
                    "-syslibroot", sdk.path, "-o", output.path]
        args += objects.map { $0.path }
        if hasObjC || hasSwift {
            args += ["-F" + sdk.appendingPathComponent("System/Library/Frameworks").path,
                     "-F" + sdk.appendingPathComponent("System/Library/SubFrameworks").path,
                     "-framework", "Foundation", "-framework", "UIKit",
                     "-framework", "CoreGraphics", "-lobjc"]
        }
        if hasCpp { args.append("-lc++") }
        if hasSwift {
            args += ["-L" + sdk.appendingPathComponent("usr/lib/swift").path, "-lswiftCore"]
            // Swift 6.4 前端會對舊系統 stdlib 發 autolink 到相容包
            // （swiftCompatibility56/Packs 等）：它們是工具鏈側的靜態庫、
            // 不在 SDK 內，隨 App 內附於 swift-compat/（見 Resources/），
            // 補上搜尋路徑讓 lld 的 autolink 找得到（2026-10-30 真機實證
            // 缺此路徑會 undefined __swift_FORCE_LOAD_$_swiftCompatibility56）。
            let compatDir = Bundle.main.bundlePath + "/swift-compat"
            if FileManager.default.fileExists(atPath: compatDir + "/libswiftCompatibility56.a") {
                args += ["-L" + compatDir]
            } else if FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/libswiftCompatibility56.a") {
                args += ["-L" + Bundle.main.bundlePath]
            }
        }
        args.append("-lSystem")
        return runJob(type: 4, args: args)
    }

    /// 以 clang driver 組裝＋執行（源文件一次編＋連）：旗標只給 driver
    /// 語法，-cc1 參數由框架內的 clang driver 按 SDK 布局展開（Nyxian
    /// 同款 CCDriver 路），不再手寫搜尋路徑清單。
    static func buildWithDriver(sources: [URL], output: URL, buildDir: URL,
                                sdk: URL, res: URL,
                                hasObjC: Bool, hasCpp: Bool) -> (rc: Int32, report: String) {
        var args = ["-target", triple, "-isysroot", sdk.path,
                    "-resource-dir", clangResourceDir(sdk: sdk, res: res)]
        if hasObjC { args.append("-fblocks") }
        args += sources.map { $0.path }
        args += ["-o", output.path]
        if hasObjC {
            args += ["-framework", "Foundation", "-framework", "UIKit",
                     "-framework", "CoreGraphics", "-lobjc"]
        }
        if hasCpp { args.append("-lc++") }
        var result: (rc: Int32, report: String) = (1, "")
        let sem = DispatchSemaphore(value: 0)
        let thread = Thread {
            var buf = [CChar](repeating: 0, count: 262144)
            let rc: Int32 = buildDir.path.withCString { bd in
                buf.withUnsafeMutableBufferPointer { bptr in
                    args.withCStrings { argc, argv in
                        paxidx_cc_driver(bd, argc, argv, bptr.baseAddress, bptr.count)
                    }
                }
            }
            result = (rc, String(cString: buf))
            sem.signal()
        }
        thread.stackSize = 64 * 1024 * 1024
        thread.start()
        sem.wait()
        return result
    }
}
