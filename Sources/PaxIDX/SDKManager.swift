import Foundation
import Zip

/// Darwin SDK 管理：下載、驗證、定位
/// SDK 從 PaxIDX 的 darwin-sdk release 下載 PaxPack 簽名包（.pxpk，
/// iOS 18.5 SDK）：驗簽＋逐檔雜湊＋防回滾全數通過才換入（規格 §8），
/// 驗證失敗不動既有 SDK、錯誤原樣回報（含 §8 錯誤碼）
final class SDKManager {
    static let shared = SDKManager()

    /// SDK 在容器中的路徑
    var sdkPath: URL? {
        let url = containerURL.appendingPathComponent("iPhoneOS.sdk", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// SDK 是否已安裝
    var isInstalled: Bool { sdkPath != nil }

    private var containerURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("SDK", isDirectory: true)
    }

    /// 從 PaxIDX release 下載 iPhoneOS SDK 的 PaxPack 簽名包（iOS 18.5）
    /// 順序：下載 → 完整驗證 → 換入；驗證失敗既有 SDK 原封不動。
    /// - Parameters:
    ///   - onProgress: 進度回調 (0.0~1.0)
    ///   - completion: 完成回調 (成功/失敗訊息)
    func downloadLatest(
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let downloadURLString = "https://github.com/yongshuai1013/PaxIDX/releases/download/darwin-sdk-1/paxidx-darwin-sdk.pxpk"
        guard let downloadURL = URL(string: downloadURLString) else {
            completion(.failure(NSError(domain: "SDKManager", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "SDK 下載地址無效"])))
            return
        }

        // 下載（只下底包；Swift 6 模塊改手動疊加，避免自動疊加失敗拖累整個 SDK）
        self.downloadFile(from: downloadURL, onProgress: onProgress) { result in
            switch result {
            case .success(let fileURL):
                do {
                    try self.installVerifiedPackage(at: fileURL)
                    try? FileManager.default.removeItem(at: fileURL)
                    if let sdk = self.sdkPath {
                        completion(.success(sdk))
                    } else {
                        throw NSError(domain: "SDKManager", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "安裝後找不到 SDK"])
                    }
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// PaxPack 驗證安裝：驗證器（§8）全數通過才把暫存區的 SDK 換入
    /// 容器；換入後寫防回滾下限，下限寫入失敗回滾到舊 SDK 並拋錯。
    private func installVerifiedPackage(at packageURL: URL) throws {
        let fm = FileManager.default
        let verifier = PaxPackVerifier()
        let verified = try verifier.verifyAndStage(
            packageAt: packageURL, expectedKind: "sdk")
        defer { try? fm.removeItem(at: verified.stagingURL) }
        var src = verified.stagingURL.appendingPathComponent(
            "iPhoneOS.sdk", isDirectory: true)
        if !fm.fileExists(atPath: src.path) {
            let legacy = verified.stagingURL.appendingPathComponent(
                "iPhoneOS15.6.sdk", isDirectory: true)
            if fm.fileExists(atPath: legacy.path) { src = legacy }
        }
        guard fm.fileExists(atPath: src.path) else {
            throw NSError(domain: "SDKManager", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "包內找不到 iPhoneOS.sdk"])
        }
        try fm.createDirectory(at: containerURL,
                               withIntermediateDirectories: true)
        let target = containerURL.appendingPathComponent(
            "iPhoneOS.sdk", isDirectory: true)
        let backup = containerURL.appendingPathComponent(
            "iPhoneOS.sdk.paxbak", isDirectory: true)
        try? fm.removeItem(at: backup)
        let hadOld = fm.fileExists(atPath: target.path)
        if hadOld { try fm.moveItem(at: target, to: backup) }
        do {
            try fm.moveItem(at: src, to: target)
            try verifier.commitFloor(for: verified.manifest)
        } catch {
            try? fm.removeItem(at: target)
            if hadOld { try? fm.moveItem(at: backup, to: target) }
            throw error
        }
        try? fm.removeItem(at: backup)
    }

    private func downloadFile(
        from url: URL,
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let delegate = DownloadDelegate(
            onProgress: onProgress,
            completion: { result in
                switch result {
                case .success(let tempURL):
                    // 移到臨時位置
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("sdk.pxpk")
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.moveItem(at: tempURL, to: dest)
                        completion(.success(dest))
                    } catch {
                        completion(.failure(error))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        delegate.task = task
        task.resume()
    }

    private func extract(zip: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: containerURL, withIntermediateDirectories: true)
        // 先刪舊 SDK，避免新舊混雜
        let target = containerURL.appendingPathComponent("iPhoneOS.sdk", isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            try? fm.removeItem(at: target)
        }

        // 用 Zip 解壓（支持符號鏈接）
        do {
            try Zip.unzipFile(zip, destination: containerURL, overwrite: true, password: nil)
        } catch {
            throw NSError(domain: "SDKManager", code: -5,
                userInfo: [NSLocalizedDescriptionKey: "解壓失敗：\(error.localizedDescription)"])
        }

        if !fm.fileExists(atPath: target.path) {
            throw NSError(domain: "SDKManager", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "解壓後找不到 iPhoneOS.sdk"])
        }
    }

    /// 下載並疊加 Swift 6 模塊到 SDK 的 usr/lib/swift
    /// （C 專注版：已停用，保留空函數以兼容舊調用）
    private func overlaySwiftModules(onProgress: @escaping (Double) -> Void) throws {
        // Swift 已暫停，不再疊加模塊
        return
    }

    /// 刪除已安裝的 SDK
    func remove() throws {
        try FileManager.default.removeItem(at: containerURL)
    }

    /// 從用戶選擇的 zip 文件導入 SDK（手動導入，繞開網絡下載）
    /// - Parameter sourceURL: 用戶選擇的 zip 文件 URL（來自文件選擇器）
    /// - Throws: 解壓失敗時拋出錯誤
    func importFrom(zip sourceURL: URL) throws {
        let fm = FileManager.default
        // 先清掉舊的
        if fm.fileExists(atPath: containerURL.path) {
            try? fm.removeItem(at: containerURL)
        }
        // 複製到臨時位置（文件選擇器的 URL 是安全作用域的，需要先複製）
        let tempZip = fm.temporaryDirectory.appendingPathComponent("sdk-import.zip")
        try? fm.removeItem(at: tempZip)
        try fm.copyItem(at: sourceURL, to: tempZip)
        // 解壓
        try self.extract(zip: tempZip)
        try? fm.removeItem(at: tempZip)
        // 驗證
        guard self.sdkPath != nil else {
            throw NSError(domain: "SDKManager", code: -7,
                userInfo: [NSLocalizedDescriptionKey: "導入後找不到 SDK"])
        }
    }

    /// 從已解壓的文件夾導入 SDK（繞開 ZIPFoundation，直接移動文件夾）
    /// - Parameter source: 已解壓的 iPhoneOS.sdk 文件夾 URL
    /// - Throws: 移動失敗時拋出錯誤
    func importFromFolder(_ source: URL) throws {
        let fm = FileManager.default
        // 先清掉舊的 SDK 容器
        if fm.fileExists(atPath: containerURL.path) {
            try fm.removeItem(at: containerURL)
        }
        // 創建容器目錄
        try fm.createDirectory(at: containerURL, withIntermediateDirectories: true)
        // 移動文件夾到目標位置
        let target = containerURL.appendingPathComponent("iPhoneOS.sdk", isDirectory: true)
        try fm.moveItem(at: source, to: target)
        // 驗證
        guard self.sdkPath != nil else {
            throw NSError(domain: "SDKManager", code: -8,
                userInfo: [NSLocalizedDescriptionKey: "導入後找不到 SDK"])
        }
    }
}

/// 下載進度代理：真實按字節數更新進度
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var task: URLSessionDownloadTask?
    private let onProgress: (Double) -> Void
    private let completion: (Result<URL, Error>) -> Void

    init(onProgress: @escaping (Double) -> Void,
         completion: @escaping (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async { self.onProgress(progress) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        completion(.success(location))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            completion(.failure(error))
        }
    }
}
