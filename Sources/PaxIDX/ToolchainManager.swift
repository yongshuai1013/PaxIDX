import Foundation
import Zip

/// 工具鏈 dylib 管理：下載、解壓、定位
/// dylib 從 PaxIDX 的 toolchain release 下載（zip 格式，約 60MB），解壓到 App 容器
/// 用時再 dlopen，不佔啟動內存
/// 支援分開的 C 和 Swift 工具鏈：C 用 salt=5 的純 C 版（LLD 已修），Swift 待獨立構建
final class ToolchainManager {
    static let shared = ToolchainManager()

    /// 工具鏈 release tag（跟 native-toolchain.yml 的 bundle tag 對應）
    /// 重編工具鏈後這裡要同步更新
    private let releaseTag = "toolchain-461274b81d86-noswift-ios15.0-sdk18.5"
    
    // MARK: - C 工具鏈（Clang/LLD，無 Swift）
    private let cDylibZipName = "libPaxIDXNativeToolchain.dylib.zip"
    private let cDylibName = "libPaxIDXNativeToolchain.dylib"
    
    // MARK: - Swift 工具鏈（含 Swift 6.2.4 前端）
    private let swiftReleaseTag = "toolchain-33957bbc59f4-swift-swift-6.2.4-RELEASE-ios15.0-sdk18.5"
    /// release 上的資產名（構建產物沿用 NativeToolchain 命名）
    private let swiftDylibAssetName = "libPaxIDXNativeToolchain.dylib.zip"
    /// 解壓後在裝置上的檔名（與 C 版區分，不覆蓋已驗收的 C dylib）
    private let swiftDylibName = "libPaxIDXSwiftToolchain.dylib"

    /// C 工具鏈 dylib 在容器中的路徑
    var dylibPath: URL? {
        let url = containerURL.appendingPathComponent(cDylibName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    
    /// Swift 工具鏈 dylib 在容器中的路徑（nil 表示未安裝）
    var swiftDylibPath: URL? {
        let url = containerURL.appendingPathComponent(swiftDylibName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// C 工具鏈是否已下載
    var isInstalled: Bool { dylibPath != nil }
    
    /// Swift 工具鏈是否已下載
    var isSwiftInstalled: Bool { swiftDylibPath != nil }

    private var containerURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Toolchain", isDirectory: true)
    }

    /// 下載 C 工具鏈 dylib
    /// - Parameters:
    ///   - onProgress: 進度回調 (0.0~1.0)
    ///   - completion: 完成回調 (成功/失敗訊息)
    func download(
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let downloadURLString = "https://github.com/yongshuai1013/PaxIDX/releases/download/\(releaseTag)/\(cDylibZipName)"
        guard let downloadURL = URL(string: downloadURLString) else {
            completion(.failure(NSError(domain: "ToolchainManager", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "工具鏈下載地址無效"])))
            return
        }

        downloadFile(from: downloadURL, onProgress: onProgress) { result in
            switch result {
            case .success(let fileURL):
                do {
                    try self.extract(zip: fileURL)
                    try? FileManager.default.removeItem(at: fileURL)
                    if let dylib = self.dylibPath {
                        completion(.success(dylib))
                    } else {
                        throw NSError(domain: "ToolchainManager", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "解壓後找不到 dylib"])
                    }
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// 下載 Swift 工具鏈 dylib（約 57MB），存為 libPaxIDXSwiftToolchain.dylib
    /// 與 C 版並存，不覆蓋
    func downloadSwift(
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let downloadURLString = "https://github.com/yongshuai1013/PaxIDX/releases/download/\(swiftReleaseTag)/\(swiftDylibAssetName)"
        guard let downloadURL = URL(string: downloadURLString) else {
            completion(.failure(NSError(domain: "ToolchainManager", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Swift 工具鏈下載地址無效"])))
            return
        }

        downloadFile(from: downloadURL, tempName: "toolchain-swift.zip", onProgress: onProgress) { result in
            switch result {
            case .success(let fileURL):
                do {
                    // zip 內檔名與 C 版相同，先解到暫存目錄再改名搬出，避免覆蓋 C 版
                    let stage = self.containerURL.appendingPathComponent("__swift_stage__", isDirectory: true)
                    try? FileManager.default.removeItem(at: stage)
                    try self.extract(zip: fileURL, to: stage)
                    try? FileManager.default.removeItem(at: fileURL)
                    let src = stage.appendingPathComponent("libPaxIDXNativeToolchain.dylib")
                    guard FileManager.default.fileExists(atPath: src.path) else {
                        throw NSError(domain: "ToolchainManager", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "解壓後找不到 Swift dylib"])
                    }
                    let dest = self.containerURL.appendingPathComponent(self.swiftDylibName)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: src, to: dest)
                    try? FileManager.default.removeItem(at: stage)
                    completion(.success(dest))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Swift 標準庫模塊是否已完整疊加到 SDK（6.2.4 二進制就位）
    /// Swift 與 _Concurrency 都要查：2026-10-26 的殘包只有 Swift／SwiftOnoneSupport，
    /// 缺 _Concurrency 時前端退回 SDK 的 6.1.2 接口被拒讀——只查 Swift 會把殘包
    /// 誤報成「已疊加」，還會連累設定頁把疊加按鈕藏起來沒法補疊。
    /// 查二進制不查接口：SDK 底包只有 6.1.2 接口、沒有任何 .swiftmodule 二進制，
    /// 二進制在位即代表疊加完成；且疊加時接口已被清掉（見 downloadSwiftModules），
    /// 接口文件本來就不會存在。
    var isSwiftModulesOverlaid: Bool {
        guard let sdk = SDKManager.shared.sdkPath else { return false }
        for module in ["Swift", "_Concurrency"] {
            let binary = sdk.appendingPathComponent("usr/lib/swift/\(module).swiftmodule/arm64-apple-ios.swiftmodule")
            guard FileManager.default.fileExists(atPath: binary.path) else { return false }
        }
        return true
    }

    /// 下載工具鏈的 Swift 標準庫模塊包，疊加（覆蓋）到 SDK 的 usr/lib/swift
    /// SDK 底包的 stdlib 接口是 Apple Swift 6.1.2 編的，我們的 6.2.4 前端拒讀
    /// （"this SDK is not supported by the compiler"）；換成前端自己生成的
    /// 6.2.4 接口後版本才對得上——Nyxian 的獨立資源目錄是同一回事。
    func downloadSwiftModules(
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let urlString = "https://github.com/yongshuai1013/PaxIDX/releases/download/\(swiftReleaseTag)/swift-toolchain-modules.zip"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "ToolchainManager", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Swift 模塊下載地址無效"])))
            return
        }
        guard let sdk = SDKManager.shared.sdkPath else {
            completion(.failure(NSError(domain: "ToolchainManager", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "請先下載 SDK，再疊加 Swift 模塊"])))
            return
        }
        downloadFile(from: url, tempName: "swift-modules.zip", onProgress: onProgress) { result in
            switch result {
            case .success(let fileURL):
                do {
                    let stage = self.containerURL.appendingPathComponent("__modules_stage__", isDirectory: true)
                    try? FileManager.default.removeItem(at: stage)
                    try self.extract(zip: fileURL, to: stage)
                    try? FileManager.default.removeItem(at: fileURL)
                    // zip 內結構：swift-stdlib-ios/<模塊文件>，內容覆蓋到 usr/lib/swift
                    let srcDir = stage.appendingPathComponent("swift-stdlib-ios", isDirectory: true)
                    guard FileManager.default.fileExists(atPath: srcDir.path) else {
                        throw NSError(domain: "ToolchainManager", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "模塊包結構不對：缺 swift-stdlib-ios 目錄"])
                    }
                    let destDir = sdk.appendingPathComponent("usr/lib/swift", isDirectory: true)
                    // 整目錄替換＋清接口（2026-10-26 CI 復現定案，diagnose-device-compile
                    // run #3 的 E2 對照）：模塊目錄裡只要躺著 .swiftinterface，前端就
                    // 繞過現成的 .swiftmodule 二進制、跑去從接口現場重建該模塊；
                    // 裝置端前端在重建的 SILGen 里必崩（回溯定案）。所以帶二進制的
                    // 模塊：先刪掉目的地整個舊目錄（清掉 SDK 底包 6.1.2 接口與舊疊加
                    // 殘留），再把暫存目錄裡的接口文件删掉，只裝二進制進去。
                    let fm = FileManager.default
                    for name in (try? fm.contentsOfDirectory(atPath: srcDir.path)) ?? [] {
                        guard name.hasSuffix(".swiftmodule") else { continue }
                        let stagedModule = srcDir.appendingPathComponent(name, isDirectory: true)
                        let stagedBinary = stagedModule.appendingPathComponent("arm64-apple-ios.swiftmodule")
                        guard fm.fileExists(atPath: stagedBinary.path) else { continue }
                        for file in (try? fm.contentsOfDirectory(atPath: stagedModule.path)) ?? [] {
                            if file.hasSuffix(".swiftinterface") {
                                try? fm.removeItem(at: stagedModule.appendingPathComponent(file))
                            }
                        }
                        try? fm.removeItem(at: destDir.appendingPathComponent(name, isDirectory: true))
                    }
                    try self.overlayCopy(from: srcDir, to: destDir)
                    try? FileManager.default.removeItem(at: stage)
                    completion(.success(()))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Clang 內建頭文件是否已疊加到 SDK（usr/lib/clang/<版本>/include/stdarg.h 在位）
    /// 缺了它橋接層不會給前端傳 Clang resource dir：ClangImporter 現場建
    /// Darwin／C 模塊時缺內建頭會降級，反序列化 .swiftinterface 函數體時
    /// 引用的型別載入不全，SILGen 會走到空 type 崩潰（2026-10-26 符號化定案）。
    var isClangHeadersOverlaid: Bool {
        guard let sdk = SDKManager.shared.sdkPath else { return false }
        let clangDir = sdk.appendingPathComponent("usr/lib/clang", isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: clangDir.path) else { return false }
        return versions.contains {
            FileManager.default.fileExists(atPath: clangDir.appendingPathComponent("\($0)/include/stdarg.h").path)
        }
    }

    /// 下載 Clang 內建頭文件包，疊加到 SDK 的 usr/lib/clang
    /// CI 自 #37 起就發佈 clang-resource-headers.zip（註釋寫明「App 疊加到
    /// SDK 的 usr/lib/clang/<版本>/」），但 App 一直沒寫下載它的代碼，
    /// 每份真機 log 的 usr/lib/clang 都是空的。
    /// zip 內結構：clang-headers/<版本目錄>/<文件>；安裝時統一改名到
    /// usr/lib/clang/19.1.5，對齊出貨 dylib 橋接層的寫死探測點（函數內註釋）。
    func downloadClangHeaders(
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let urlString = "https://github.com/yongshuai1013/PaxIDX/releases/download/\(swiftReleaseTag)/clang-resource-headers.zip"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "ToolchainManager", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Clang 頭文件下載地址無效"])))
            return
        }
        guard let sdk = SDKManager.shared.sdkPath else {
            completion(.failure(NSError(domain: "ToolchainManager", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "請先下載 SDK，再疊加 Clang 頭文件"])))
            return
        }
        downloadFile(from: url, tempName: "clang-headers.zip", onProgress: onProgress) { result in
            switch result {
            case .success(let fileURL):
                do {
                    let stage = self.containerURL.appendingPathComponent("__clang_stage__", isDirectory: true)
                    try? FileManager.default.removeItem(at: stage)
                    try self.extract(zip: fileURL, to: stage)
                    try? FileManager.default.removeItem(at: fileURL)
                    // zip 內結構：clang-headers/<版本目錄>/<文件>
                    let srcDir = stage.appendingPathComponent("clang-headers", isDirectory: true)
                    guard FileManager.default.fileExists(atPath: srcDir.path) else {
                        throw NSError(domain: "ToolchainManager", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "Clang 頭文件包結構不對：缺 clang-headers 目錄"])
                    }
                    // M2 前端參數是在工具鏈 dylib 內部組裝的（ToolchainDylibImpl
                    // 的 paxidx_dylib_swift_compile），出貨 dylib 的橋接寫死探測
                    // usr/lib/clang/19.1.5/include/stdarg.h 才肯傳 -Xcc -resource-dir；
                    // 資產的版本目錄名隨 LLVM 構建而變（實測只有 19），#54 真機 log
                    // 實證：頭文件裝在 19 底下、探測沒中、參數仍沒傳、照樣崩。
                    // 橋接源碼已改成掃目錄認版本，但要等下一輪工具鏈重編才生效；
                    // 在此之前 App 統一把版本目錄改名到 19.1.5 對齊探測點。
                    // usr/lib/clang 整個目錄由本疊加管理（SDK 底包沒有），
                    // 每次先清掉再裝，避免舊版號目錄殘留。
                    let fm = FileManager.default
                    let clangBase = sdk.appendingPathComponent("usr/lib/clang", isDirectory: true)
                    try? fm.removeItem(at: clangBase)
                    let destDir = clangBase.appendingPathComponent("19.1.5", isDirectory: true)
                    let versionDirs = try fm.contentsOfDirectory(atPath: srcDir.path).filter {
                        var isDir: ObjCBool = false
                        fm.fileExists(atPath: srcDir.appendingPathComponent($0).path, isDirectory: &isDir)
                        return isDir.boolValue
                    }
                    guard !versionDirs.isEmpty else {
                        throw NSError(domain: "ToolchainManager", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "Clang 頭文件包結構不對：clang-headers 下沒有版本目錄"])
                    }
                    for v in versionDirs {
                        try self.overlayCopy(from: srcDir.appendingPathComponent(v, isDirectory: true), to: destDir)
                    }
                    try? FileManager.default.removeItem(at: stage)
                    completion(.success(()))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - iOS 15 系統函式庫 sysroot（真 dylib 副本）

    private let sysrootReleaseTag = "sysroot-ios15"
    private let sysrootAssetName = "paxidx-sysroot-ios15.zip"

    /// sysroot 在 SDK 目錄內的安裝點（橋接層連結時按此相對位置找，見
    /// ToolchainDylibImpl 的 paxidx_dylib_ld_link）
    static func sysrootDir(in sdk: URL) -> URL {
        sdk.appendingPathComponent("paxidx-sysroot", isDirectory: true)
    }

    /// 系統函式庫是否已安裝：連結的主力兩支在位即算（libSystem 傘＋
    /// libswiftCore；其餘 38 支是它們的依賴閉包，隨包一起裝）
    var isSysrootInstalled: Bool {
        guard let sdk = SDKManager.shared.sdkPath else { return false }
        let root = Self.sysrootDir(in: sdk)
        let fm = FileManager.default
        return fm.fileExists(atPath: root.appendingPathComponent("usr/lib/libSystem.B.dylib").path)
            && fm.fileExists(atPath: root.appendingPathComponent("usr/lib/swift/libswiftCore.dylib").path)
    }

    /// 下載 iOS 15.8.5 系統函式庫包（真 dylib，從固件 dyld 快取抽出），
    /// 裝進 SDK 目錄內的 paxidx-sysroot/。
    /// 為什麼需要它：裝置上的 lld 讀不了 SDK 的 .tbd（真機實證讀成空／
    /// unhandled file type），而 /usr/lib 的真身只存在於 dyld 快取、磁碟
    /// 上沒有文件可開——連結只能連容器裡的這份副本；副本的 install name
    /// 仍是 /usr/lib/...，產物運行時用的還是系統正版。
    func downloadSysroot(
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let urlString = "https://github.com/yongshuai1013/PaxIDX/releases/download/\(sysrootReleaseTag)/\(sysrootAssetName)"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "ToolchainManager", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "系統函式庫下載地址無效"])))
            return
        }
        guard let sdk = SDKManager.shared.sdkPath else {
            completion(.failure(NSError(domain: "ToolchainManager", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "請先下載 SDK，再安裝系統函式庫"])))
            return
        }
        downloadFile(from: url, tempName: "sysroot.zip", onProgress: onProgress) { result in
            switch result {
            case .success(let fileURL):
                do {
                    let stage = self.containerURL.appendingPathComponent("__sysroot_stage__", isDirectory: true)
                    try? FileManager.default.removeItem(at: stage)
                    try self.extract(zip: fileURL, to: stage)
                    try? FileManager.default.removeItem(at: fileURL)
                    // zip 內結構：usr/lib/...（根目錄就是 sysroot 本身）
                    let stagedUsr = stage.appendingPathComponent("usr", isDirectory: true)
                    guard FileManager.default.fileExists(atPath: stagedUsr.path) else {
                        throw NSError(domain: "ToolchainManager", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "系統函式庫包結構不對：缺 usr 目錄"])
                    }
                    let dest = Self.sysrootDir(in: sdk)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: stagedUsr, to: dest.appendingPathComponent("usr", isDirectory: true))
                    try? FileManager.default.removeItem(at: stage)
                    guard self.isSysrootInstalled else {
                        throw NSError(domain: "ToolchainManager", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "系統函式庫安裝後驗證未過"])
                    }
                    completion(.success(()))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// 遞歸覆蓋複製（目錄合併、文件覆蓋）
    private func overlayCopy(from src: URL, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(atPath: src.path) {
            let s = src.appendingPathComponent(item)
            let d = dest.appendingPathComponent(item)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: s.path, isDirectory: &isDir)
            if isDir.boolValue {
                try overlayCopy(from: s, to: d)
            } else {
                try? fm.removeItem(at: d)
                try fm.copyItem(at: s, to: d)
            }
        }
    }

    /// 刪除已下載的工具鏈
    func remove() throws {
        try FileManager.default.removeItem(at: containerURL)
    }

    private func downloadFile(
        from url: URL,
        tempName: String = "toolchain.zip",
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let task = URLSession.shared.downloadTask(with: url) { tempURL, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let tempURL = tempURL else {
                completion(.failure(NSError(domain: "ToolchainManager", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "下載失敗"])))
                return
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(tempName)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tempURL, to: dest)
                completion(.success(dest))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
        onProgress(0.5)
    }

    private func extract(zip: URL, to destDir: URL? = nil) throws {
        let target = destDir ?? containerURL
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        do {
            try Zip.unzipFile(zip, destination: target, overwrite: true, password: nil)
        } catch {
            throw NSError(domain: "ToolchainManager", code: -5,
                userInfo: [NSLocalizedDescriptionKey: "解壓失敗：\(error.localizedDescription)"])
        }
    }
}
