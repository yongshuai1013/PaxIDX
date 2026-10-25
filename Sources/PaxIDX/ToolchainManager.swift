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

    /// Swift 標準庫模塊是否已疊加到 SDK（6.2.4 接口就位）
    var isSwiftModulesOverlaid: Bool {
        guard let sdk = SDKManager.shared.sdkPath else { return false }
        let iface = sdk.appendingPathComponent("usr/lib/swift/Swift.swiftmodule/arm64-apple-ios.swiftinterface")
        guard let text = try? String(contentsOf: iface, encoding: .utf8) else { return false }
        return text.contains("swiftlang-6.2.4") || text.contains("Swift version 6.2.4")
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
